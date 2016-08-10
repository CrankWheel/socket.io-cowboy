%% @author Kirill Trofimov <sinnus@gmail.com>
%% @copyright 2012 Kirill Trofimov
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%    http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
-module(engineio_handler).
-author('Kirill Trofimov <sinnus@gmail.com>').
-author('wuyingfengsui@gmail.com').
-author('Jói Sigurdsson <joi@crankwheel.com>').

-include("engineio_internal.hrl").

-export([init/2, terminate/3,
         info/3,
         websocket_handle/3, websocket_info/3]).

% Our decoder currently doesn't support streaming, so we need to read in the
% entire POST body when a polling transport is used. Read up to 24 MB, above
% that the server will simply freak out.
%
% TODO(joi): Support streaming decodes, and use below.
-define(MAXIMUM_BODY_BYTES, 24*1024*1024).

-record(http_state, {config, sid, heartbeat_tref, pid, jsonp, base64}).
-record(websocket_state, {config, pid, messages}).

init(Req, [Config]) ->
    Req2 = enable_cors(Req),
    KeyValues = cowboy_req:parse_qs(Req2),
    Sid = proplists:get_value(<<"sid">>, KeyValues),
    Transport = proplists:get_value(<<"transport">>, KeyValues),
    JsonP = proplists:get_value(<<"j">>, KeyValues),
    Base64Val = proplists:get_value(<<"b64">>, KeyValues),
    Base64 = case Base64Val of
        <<"true">> -> true;
        <<"1">> -> true;
        _ -> false
    end,
    case {Transport, Sid} of
        {<<"polling">>, undefined} ->
            create_session(Req2, #http_state{config = Config, jsonp = JsonP, base64 = Base64});
        {<<"polling">>, _} when is_binary(Sid) ->
            handle_polling(Req2, Sid, Config, JsonP, Base64);
        {<<"websocket">>, _} ->
            websocket_init(Req, Config);
        _ ->
            lager:error("400, unknown transport ~s for SID ~s", [Transport, Sid]),
            {ok, cowboy_req:reply(400, [], <<>>, Req2), #http_state{}}
    end.

%% Http handlers
create_session(Req, HttpState = #http_state{jsonp = JsonP, base64 = Base64, config = #config{
    heartbeat = HeartbeatInterval,
    heartbeat_timeout = HeartbeatTimeout,
    session_timeout = SessionTimeout,
    opts = Opts,
    callback = Callback,
    enable_websockets = EnableWebsockets
}}) ->
    Sid = uuids:new(),
    _Pid = engineio_session:create(Sid, SessionTimeout, Callback, Opts, Req, Base64),
    UpgradeList = case EnableWebsockets of
        true -> [<<"websocket">>];
        false -> []
    end,
    Result = jiffy:encode({[
        {<<"sid">>, Sid},
        {<<"pingInterval">>, HeartbeatInterval}, {<<"pingTimeout">>, HeartbeatTimeout},
        {<<"upgrades">>, UpgradeList}
    ]}),

    case JsonP of
        undefined ->
            Result2 = encode_polling_xhr_packets_v1([<<$0, Result/binary>>], Base64),
            case Base64 of
                true ->
                    HttpHeaders = text_headers();
                false ->
                    HttpHeaders = stream_headers()
            end;
        Num ->
            ResultLenBin = integer_to_binary(byte_size(Result) + 1),
            Rs = binary:replace(Result, <<"\"">>, <<"\\\"">>, [global]),
            Result2 = <<"___eio[", Num/binary, "](\"", ResultLenBin/binary, ":0", Rs/binary, "\");">>,
            HttpHeaders = javascript_headers()
    end,

    Req1 = cowboy_req:reply(200, HttpHeaders, <<Result2/binary>>, Req),
    {ok, Req1, HttpState}.

% Invariant in all of these: We are an HTTP loop handler.
info({timeout, TRef, {?MODULE, Pid}}, Req, HttpState = #http_state{heartbeat_tref = TRef}) ->
    safe_poll(Req, HttpState#http_state{heartbeat_tref = undefined}, Pid, false);
info({message_arrived, Pid}, Req, HttpState = #http_state{pid = StatePid, heartbeat_tref = HeartbeatTRef}) ->
    case Pid of
        StatePid ->
            % This message_arrived was meant for us, so poll and return data.

            % We don't want the timeout any more (since we will be exiting after polling).
            case HeartbeatTRef of
                undefined ->
                    ok;
                _ ->
                    erlang:cancel_timer(HeartbeatTRef),
                    ok
            end,
            % No other handler should be trying to poll this session, so it
            % should be fine to not wait if the message list is empty.
            safe_poll(Req, HttpState, Pid, false);
        _ ->
            % We can receive message_arrived messages that were meant for a loop
            % handler that previously ran in the same process as we are. The way
            % this happens is that the engineio_session sends the asynchronous
            % message_arrived message just before the previous loop handler
            % calls unsub_caller, so it gets added to this process's message
            % queue even though the handler that was planning to handle it is
            % gone.
            {ok, Req, HttpState}
    end;
info(Info, Req, HttpState) ->
    lager:error("engineio_handler: Unexpected info message ~s", [Info]),
    {stop, Req, HttpState}.

terminate(Reason, _Req, _HttpState = #http_state{heartbeat_tref = HeartbeatTRef, pid = Pid}) ->
    % Invariant: We are an HTTP handler (loop or regular).
    safe_unsub_caller(Pid, self()),
    case HeartbeatTRef of
        undefined ->
            ok;
        _ ->
            erlang:cancel_timer(HeartbeatTRef),
            ok
    end,
    case Reason of
        {error, closed} ->
            % This indicates that the long-polling connection has been closed
            % unexpectedly, which generally means that the client is gone.
            engineio_session:disconnect(Pid);
        _ ->
            ok
    end;
terminate(_Reason, _Req, #websocket_state{pid = Pid}) ->
    % Invariant: We are a WebSocket handler.
    engineio_session:disconnect(Pid),
    ok;
terminate(Reason, _Req, _State) ->
    lager:error("enginio_handler terminating, ~s", [Reason]),
    ok.

text_headers() -> [ {<<"Content-Type">>, <<"text/plain; charset=utf-8">>} ].

stream_headers() -> [ {<<"Content-Type">>, <<"application/octet-stream">>} ].

javascript_headers() ->
    [
        {<<"Content-Type">>, <<"text/javascript; charset=UTF-8">>},
        {<<"X-XSS-Protection">>, <<"0">>}
    ].

% If SendNop is true, we must send at least one message to flush our queue,
% so if the message queue is empty, we still send [nop].
reply_messages(Req, Messages, SendNop, undefined, Base64) ->
    PacketList = case {SendNop, Messages} of
        {true, []} ->
            engineio_data_protocol:encode_v1([nop]);
        _ ->
            engineio_data_protocol:encode_v1(Messages)
    end,
    PacketListBin = encode_polling_xhr_packets_v1(PacketList, Base64),
    case Base64 of
        true ->
            HttpHeaders = text_headers();
        false ->
            HttpHeaders = stream_headers()
    end,
    cowboy_req:reply(200, HttpHeaders, PacketListBin, Req);
reply_messages(Req, Messages, SendNop, JsonP, _Base64) ->
    PacketList = case {SendNop, Messages} of
        {true, []} ->
            engineio_data_protocol:encode_v1([nop]);
        _ ->
            engineio_data_protocol:encode_v1(Messages)
    end,
    PacketListBin = encode_polling_json_packets_v1(PacketList, JsonP),
    cowboy_req:reply(200, javascript_headers(), PacketListBin, Req).

safe_unsub_caller(undefined, _Caller) ->
    ok;
safe_unsub_caller(_Pid, undefined) ->
    ok;
safe_unsub_caller(Pid, Caller) ->
    try
        engineio_session:unsub_caller(Pid, Caller),
        ok
    catch
        exit:{noproc, _} ->
            error
    end.

safe_poll(Req, HttpState = #http_state{jsonp = JsonP}, Pid, WaitIfEmpty) ->
    % INVARIANT: We are an HTTP loop handler.
    try
        Messages = engineio_session:poll(Pid),
        Transport = engineio_session:transport(Pid),
        Base64 = engineio_session:b64(Pid),
        case {Transport, WaitIfEmpty, Messages} of
            {websocket, _, _} ->
                % Our transport has been switched to websocket, so we flush
                % the transport, sending a nop if there are no messages in the
                % queue.
                {stop, reply_messages(Req, Messages, true, JsonP, Base64), HttpState};
            {_, true, []} ->
                % Not responding with 'stop' will make the loop handler continue
                % to wait.
                {ok, Req, HttpState};
            _ ->
                {stop, reply_messages(Req, Messages, true, JsonP, Base64), HttpState}
        end
    catch
        exit:{noproc, _} ->
            lager:error("engineio_handler: Couldn't talk to PID ~s, ~s, ~s", [Pid, JsonP, WaitIfEmpty]),
            {stop, cowboy_req:reply(400, [], <<>>, Req), HttpState}
    end.

handle_polling(Req, Sid, Config, JsonP, Base64) ->
    Method = cowboy_req:method(Req),
    case {engineio_session:find(Sid), Method} of
        {{ok, Pid}, <<"GET">>} ->
            case engineio_session:pull_no_wait(Pid, self()) of
                {error, noproc} ->
                    {ok, cowboy_req:reply(400, <<"No such session">>, Req), #http_state{config = Config, sid = Sid, jsonp = JsonP, base64 = Base64}};
                session_in_use ->
                    {ok, cowboy_req:reply(400, <<"Session in use">>, Req), #http_state{config = Config, sid = Sid, jsonp = JsonP, base64 = Base64}};
                [] ->
                    case engineio_session:transport(Pid) of
                        websocket ->
                            % Just send a NOP to flush this transport.
                            {ok, reply_messages(Req, [], true, JsonP, Base64), #http_state{config = Config, sid = Sid, pid = Pid, jsonp = JsonP, base64 = Base64}};
                        _ ->
                            TRef = erlang:start_timer(Config#config.heartbeat, self(), {?MODULE, Pid}),
                            {cowboy_loop, Req, #http_state{config = Config, sid = Sid, heartbeat_tref = TRef, pid = Pid, jsonp = JsonP, base64 = Base64}}
                    end;
                Messages ->
                    Req1 = reply_messages(Req, Messages, false, JsonP, Base64),
                    {ok, Req1, #http_state{config = Config, sid = Sid, pid = Pid, jsonp = JsonP, base64 = Base64}}
            end;
        {{ok, Pid}, <<"POST">>} ->
            case get_request_data(Req, JsonP) of
                {ok, Data2, Req2} ->
                    % TODO(je): Check if we need to obey b64 here?
                    Messages = case catch(engineio_data_protocol:decode_v1(Data2)) of
                                   {'EXIT', _Reason} ->
                                       [];
                                   {error, _Reason} ->
                                       [];
                                   Msgs ->
                                       Msgs
                               end,
                    engineio_session:recv(Pid, Messages),
                    Req3 = cowboy_req:reply(200, text_headers(), <<"ok">>, Req2),
                    {ok, Req3, #http_state{config = Config, sid = Sid, jsonp = JsonP, base64 = Base64}};
                error ->
                    lager:error("engineio_handler: Error reading request data ~s", [Req, JsonP]),
                    {ok, cowboy_req:reply(400, <<"Error reading request data">>, Req), #http_state{config = Config, sid = Sid, base64 = Base64}}
            end;
        {{error, not_found}, _} ->
            lager:error("engineio_handler: sid not found ~s", [Sid]),
            Req1 = cowboy_req:reply(400, [], <<"Not found">>, Req),
            {ok, Req1, #http_state{sid = Sid, config = Config, jsonp = JsonP, base64 = Base64}};
        _ ->
            lager:error("engineio_handler: Unknown error ~s, ~s, ~s, ~s", [Sid, Method, Config, JsonP]),
            {ok, cowboy_req:reply(400, <<"Unknown error">>, Req), #http_state{sid = Sid, config = Config, jsonp = JsonP, base64 = Base64}}
    end.

%% Websocket handlers
websocket_init(Req, Config) ->
    KeyValues = cowboy_req:parse_qs(Req),
    case proplists:get_value(<<"sid">>, KeyValues, undefined) of
        Sid when is_binary(Sid) ->
            case engineio_session:find(Sid) of
                {ok, Pid} ->
                    erlang:monitor(process, Pid),
                    engineio_session:upgrade_transport(Pid, websocket),
                    {cowboy_websocket, Req, #websocket_state{config = Config, pid = Pid, messages = []}};
                {error, not_found} ->
                    {ok, cowboy_req:reply(400, [], <<"No such session">>, Req), #websocket_state{}}
            end;
        _ ->
            {ok, cowboy_req:reply(400, [], <<"No such session">>, Req), #websocket_state{}}
    end.

websocket_handle({text, Data}, Req, State = #websocket_state{ pid = Pid }) ->
    case catch (engineio_data_protocol:decode_v1_for_websocket(Data)) of
        {'EXIT', _Reason} ->
            {ok, Req, State};
        [{ping, Rest}] ->
            Packet = engineio_data_protocol:encode_v1({pong, Rest}),
            engineio_session:refresh(Pid),
            {reply, {text, Packet}, Req, State};
        [upgrade] ->
            self() ! go,
            {ok, Req, State};
        Msgs ->
            case engineio_session:recv(Pid, Msgs) of
                noproc ->
                    lager:error("engineio_handler: websocket recv failed"),
                    {stop, Req, State};
                _ ->
                    {ok, Req, State}
            end
    end;
websocket_handle(Data, Req, State) ->
    lager:warning("engineio_handler: unknown websocket message ~s", [Data]),
    {ok, Req, State}.

websocket_info(go, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    case engineio_session:pull(Pid, self()) of
        {error, noproc} ->
            lager:error("engineio_handler: no such session for websocket"),
            {stop, Req, State};
        session_in_use ->
            {ok, Req, State};  % TODO(joi): Really?
        Messages ->
            RestMessages2 = lists:append([RestMessages, Messages]),
            self() ! go_rest,
            {ok, Req, State#websocket_state{messages = RestMessages2}}
    end;
websocket_info(go_rest, Req, State = #websocket_state{messages = RestMessages}) ->
    case RestMessages of
        [] ->
            {ok, Req, State};
        _ ->
            Reply = [{text, engineio_data_protocol:encode_v1(M)} || M <- RestMessages],
            {reply, Reply, Req, State#websocket_state{messages = []}}
    end;
websocket_info({message_arrived, Pid}, Req, State = #websocket_state{pid = Pid, messages = RestMessages}) ->
    Messages =  case engineio_session:safe_poll(Pid) of
                    {error, noproc} ->
                        [];
                    Result ->
                        Result
                end,
    RestMessages2 = lists:append([RestMessages, Messages]),
    self() ! go,
    {ok, Req, State#websocket_state{messages = RestMessages2}};
websocket_info({'DOWN', _Ref, process, Pid, Reason}, Req, State = #websocket_state{pid = Pid}) ->
    lager:error("engineio_handler: websocket down"),
    {stop, Req, State};
websocket_info(Info, Req, State) ->
    % TODO(joi): Log
    lager:warning("engineio_handler: unknown websocket info ~s", [Info]),
    {ok, Req, State}.

enable_cors(Req) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
            Req;
        Origin ->
            Req1 = cowboy_req:set_resp_header(<<"access-control-allow-origin">>, Origin, Req),
            cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req1)
    end.

get_request_data(Req, JsonP) ->
    case JsonP of
        undefined ->
            case cowboy_req:body(Req, [{length, ?MAXIMUM_BODY_BYTES}]) of
                {ok, Body, Req1} ->
                    {ok, Body, Req1};
                {error, _} ->
                    error
            end;
        _Num ->
            case cowboy_req:body_qs(Req, [{length, ?MAXIMUM_BODY_BYTES}]) of
                {ok, PostVals, Req1} ->
                    Data = proplists:get_value(<<"d">>, PostVals),
                    Data2 = binary:replace(Data, <<"\\\n">>, <<"\n">>, [global]),
                    Data3 = binary:replace(Data2, <<"\\\\n">>, <<"\\n">>, [global]),
                    {ok, Data3, Req1};
                {error, _} ->
                    error
            end
    end.

encode_polling_xhr_packets_v1(PacketList, Base64) ->
    case Base64 of
        false ->
    lists:foldl(fun(Packet, AccIn) ->
        PacketLen = [list_to_integer([D]) || D <- integer_to_list(byte_size(Packet))],
        PacketLenBin = list_to_binary(PacketLen),
        <<AccIn/binary, 0, PacketLenBin/binary, 255, Packet/binary>>
            end, <<>>, PacketList);
        true ->
            lists:foldl(fun(Packet, AccIn) ->
                PacketLenStr = list_to_binary(io_lib:format("~p", [byte_size(Packet)])),
                <<AccIn/binary, PacketLenStr/binary, $:, Packet/binary>>
            end, <<>>, PacketList)
    end.

encode_polling_json_packets_v1(PacketList, JsonP) ->
    % TODO(joi): I'm pretty sure we could optimize by using an iolist rather
    % than building an increasingly-larger binary...
    Payload = lists:foldl(fun(Packet, AccIn) ->
        ResultLenBin = integer_to_binary(byte_size(Packet)),
        Packet2 = escape_character(Packet, <<"\\">>),
        Packet3 = escape_character(Packet2, <<"\"">>),
        Packet4 = escape_character(Packet3, <<"\\n">>),
        <<AccIn/binary, ResultLenBin/binary, ":", Packet4/binary>>
    end, <<>>, PacketList),
    <<"___eio[", JsonP/binary, "](\"", Payload/binary, "\");">>.

escape_character(Data, CharBin) ->
    binary:replace(Data, CharBin, <<"\\", CharBin/binary>>, [global]).
