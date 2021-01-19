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
-module(engineio_session).
-author('Kirill Trofimov <sinnus@gmail.com>').
-author('wuyingfengsui@gmail.com').
-author('Jói Sigurdsson <joi@crankwheel.com>').
-behaviour(gen_server).

-include("engineio_internal.hrl").

%% API
-export([start_link/6, init_mnesia/0, configure/1, create/6, find/1, pull/2, pull_no_wait/2, poll/1, safe_poll/1, recv/2,
         send_message/2, refresh/1, disconnect/1, unsub_caller/2, get_transport/1, upgrade_transport/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(SESSION_PID_TABLE, engineio_session_to_pid).

-record(?SESSION_PID_TABLE, {sid, pid}).

-record(state, {id,
    callback,
    messages,
    session_timeout,
    session_timeout_tref,
    caller,
    registered,
    opts,
    session_state,
    original_request,
    transport,
    message_count,
    base64}).

%%%===================================================================
%%% API
%%%===================================================================
configure(Opts) ->
    #config{heartbeat = proplists:get_value(heartbeat, Opts, 5000),
            heartbeat_timeout = proplists:get_value(heartbeat_timeout, Opts, 30000),
            session_timeout = proplists:get_value(session_timeout, Opts, 30000),
            callback = proplists:get_value(callback, Opts),
            opts = proplists:get_value(opts, Opts, undefined),
            enable_websockets = proplists:get_value(enable_websockets, Opts, true)
           }.

init_mnesia() ->
    init_table(?SESSION_PID_TABLE,
        [{index, [pid]}, {attributes, record_info(fields, ?SESSION_PID_TABLE)}],
        ram_copies).

create(SessionId, SessionTimeout, Callback, Opts, OriginalRequest, Base64) ->
    {ok, Pid} = engineio_session_sup:start_child(SessionId, SessionTimeout, Callback, Opts, OriginalRequest, Base64),
    Pid.

find(SessionId) ->
    case mnesia:dirty_read(?SESSION_PID_TABLE, SessionId) of
        [{?SESSION_PID_TABLE, _, Pid}] ->
            case is_pid_alive(Pid) of
                true -> {ok, Pid};
                _ ->
                    mnesia:dirty_delete(?SESSION_PID_TABLE, SessionId),
                    {error, not_found}
            end;
        [] ->
            {error, not_found}
    end.

pull(Pid, Caller) ->
    safe_call(Pid, {pull, Caller, true}, 5000).

pull_no_wait(Pid, Caller) ->
    safe_call(Pid, {pull, Caller, false}, 5000).

poll(Pid) ->
    gen_server:call(Pid, {poll}).

% Returns {Transport, Messages, Base64}
safe_poll(Pid) ->
    safe_call(Pid, {poll}, 5000).

send(Pid, Message) ->
    gen_server:cast(Pid, {send, Message}).

send_message(Pid, Message) when is_binary(Message) ->
    gen_server:cast(Pid, {send, {message, Message}}).

recv(Pid, Messages) when is_list(Messages) ->
    gen_server:cast(Pid, {recv, Messages}).

refresh(Pid) ->
    gen_server:cast(Pid, {refresh}).

disconnect(Pid) ->
    gen_server:cast(Pid, {disconnect}).

unsub_caller(Pid, Caller) ->
    gen_server:cast(Pid, {unsub_caller, Caller}).

get_transport(Pid) ->
    gen_server:call(Pid, {get_transport}).

upgrade_transport(Pid, Transport) ->
    gen_server:call(Pid, {transport, Transport}).

%%--------------------------------------------------------------------
start_link(SessionId, SessionTimeout, Callback, Opts, OriginalRequest, Base64) ->
    gen_server:start_link(?MODULE, [SessionId, SessionTimeout, Callback, Opts, OriginalRequest, Base64], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
init([SessionId, SessionTimeout, Callback, Opts, OriginalRequest, Base64]) ->
    % TODO(joi): Shouldn't this be finished before returning?
    self() ! register_in_ets,
    TRef = erlang:send_after(SessionTimeout, self(), session_timeout),
    State = #state{
        id = SessionId,
        messages = [],
        registered = false,
        callback = Callback,
        opts = Opts,
        session_timeout_tref = TRef,
        session_timeout = SessionTimeout,
        original_request = OriginalRequest,
        transport = polling,
        message_count = 0,
        base64 = Base64
    },
    {ok, State}.

%%--------------------------------------------------------------------
handle_call({pull, Pid, Wait}, _From,  State = #state{messages = Messages, caller = undefined}) ->
    State1 = refresh_session_timeout(State),
    case Messages of
        [] ->
            {reply, [], State1#state{caller = Pid}};
        _ ->
            NewCaller = case Wait of
                            true ->
                                Pid;
                            false ->
                                undefined
                        end,
            {reply, lists:reverse(Messages), State1#state{messages = [], caller = NewCaller}}
    end;

handle_call({pull, _Pid, _}, _From,  State) ->
    {reply, session_in_use, State};

handle_call({get_transport}, _From, State = #state{transport = Transport}) ->
    {reply, Transport, State};

handle_call({transport, websocket}, _From, State = #state{transport = polling, caller = Caller}) ->
    case Caller of
        undefined ->
            ignore;
        _ ->
            send(self(), nop)
    end,
    {reply, ok, State#state{transport = websocket}};
handle_call({transport, Transport}, _From, State) ->
    {reply, ok, State#state{transport = Transport}};

handle_call({poll}, _From, State = #state{transport = Transport, base64 = Base64, messages = Messages}) ->
    State1 = refresh_session_timeout(State),
    {reply, {Transport, lists:reverse(Messages), Base64}, State1#state{messages = [], caller = undefined}};


handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.
%%--------------------------------------------------------------------
handle_cast({send, Message}, State = #state{messages = Messages, caller = Caller}) ->
    case Caller of
        undefined ->
            ok;
        _ ->
            Caller ! {message_arrived, self()}
    end,
    % We can unregister the caller right away since it will simply poll and then
    % die immediately after that. No need to send thousands of message_arrived messages
    % in a row, just one is enough once there is data available.
    {noreply, State#state{messages = [Message|Messages], caller = undefined}};

handle_cast({recv, Messages}, State = #state{message_count = MessageCount}) ->
    State1 = State#state{message_count = MessageCount + length(Messages)},
    State2 = refresh_session_timeout(State1),
    process_messages(Messages, State2);

handle_cast({refresh}, State) ->
    {noreply, refresh_session_timeout(State)};

handle_cast({unsub_caller, _Caller}, State = #state{caller = undefined}) ->
    {noreply, State};
handle_cast({unsub_caller, Caller}, State = #state{caller = PrevCaller}) ->
    case Caller of
        PrevCaller ->
            {noreply, State#state{caller = undefined}};
        _ ->
            {noreply, State}
    end;

handle_cast({disconnect}, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(session_timeout, State) ->
    {stop, normal, State};

handle_info(register_in_ets,
    State = #state{id = SessionId, registered = false, callback = Callback, opts = Opts, original_request = OriginalRequest}) ->
    case mnesia:dirty_write(#?SESSION_PID_TABLE{sid = SessionId, pid = self()}) of
        ok ->
            case Callback:open(SessionId, Opts, OriginalRequest) of
                {ok, SessionState} ->
                    {noreply, State#state{registered = true, session_state = SessionState}};
                disconnect ->
                    {stop, normal, State}
            end;
        _ ->
            {stop, session_id_exists, State}
    end;

handle_info(Info, State = #state{registered = true, callback = Callback, session_state = SessionState}) ->
    case Callback:handle_info(Info, SessionState) of
        {ok, NewSessionState} ->
            {noreply, State#state{session_state = NewSessionState}};
        {disconnect, NewSessionState} ->
            {stop, normal, State#state{session_state = NewSessionState}}
    end;

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State = #state{id = SessionId, registered = Registered, callback = Callback, session_state = SessionState, message_count = MessageCount}) ->
    lager:debug("Session ~s terminating, message count ~s", [self(), MessageCount]),
    mnesia:dirty_delete(?SESSION_PID_TABLE, SessionId),
    case Registered of
        true ->
            Callback:close(SessionState),
            ok;
        _ ->
            ok
    end.

%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
refresh_session_timeout(State = #state{session_timeout = Timeout, session_timeout_tref = TRef}) ->
    erlang:cancel_timer(TRef),
    NewTRef = erlang:send_after(Timeout, self(), session_timeout),
    State#state{session_timeout_tref = NewTRef}.

process_messages([], _State) ->
    {noreply, _State};

process_messages([Message|Rest], State = #state{callback = Callback, session_state = SessionState}) ->
    case Message of
        disconnect ->
            {stop, normal, State};
        {ping, Data} ->
            send(self(), {pong, Data}),
            process_messages(Rest, State);
        {message, MessageBin} ->
            case Callback:recv({message, MessageBin}, SessionState) of
                {ok, NewSessionState} ->
                    process_messages(Rest, State#state{session_state = NewSessionState});
                {disconnect, NewSessionState} ->
                    {stop, normal, State#state{session_state = NewSessionState}}
            end;
        _ ->
            %% Skip message
            lager:warning("Skipping message ~s, ~s, ~s", [Message, Rest, State]),
            process_messages(Rest, State)
    end.

is_pid_alive(Pid) when node(Pid) =:= node() ->
    is_process_alive(Pid);
is_pid_alive(Pid) ->
    lists:member(node(Pid), nodes()) andalso
        (rpc:call(node(Pid), erlang, is_process_alive, [Pid]) =:= true).

init_table(Table, Opts, Type) ->
    case create_table(Table, Opts) of
        exist ->
            clone_table(Table, Type);
        Else ->
            Else
    end.

create_table(Table, Opts) ->
    Tables = mnesia:system_info(tables),
    case lists:member(Table, Tables) of
        false ->
            case mnesia:create_table(Table, Opts) of
                {atomic, ok} ->
                    error_logger:info_msg("mnesia: create table ~p\n", [Table]),
                    ok;
                {aborted, Reason} ->
                    error_logger:error("mnesia: create table ~p fail: ~p\n", [Table, Reason]),
                    error
            end;
        true ->
            exist
    end.

clone_table(Table, Type) ->
    Tables = mnesia:system_info(local_tables),
    case lists:member(Table, Tables) of
        false ->
            case mnesia:add_table_copy(Table, node(), Type) of
                {atomic, ok} ->
                    ok;
                Error ->
                    Error
            end;
        true ->
            ok
    end.

safe_call(Pid, Msg, Timeout) ->
    try
        gen_server:call(Pid, Msg, Timeout)
    catch
        exit:{noproc, _} -> {error, noproc};
        exit:{normal, _} -> {error, noproc}
    end.
