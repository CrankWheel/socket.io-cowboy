-module(ws_handler).

-export([init/2, terminate/3]).
-export([websocket_handle/3, websocket_info/3]).

init(Req, Opts) ->
%	erlang:start_timer(1000, self(), <<"Hello!">>),
	broadcaster:start(),
	broadcaster:add_session(self()),
	{cowboy_websocket, Req, Opts}.

websocket_handle({text, Msg}, Req, State) ->
	broadcaster:publish_to_all(Msg),
	{ok, Req, State};
websocket_handle(_Data, Req, State) ->
	{ok, Req, State}.

%websocket_info({timeout, _Ref, Msg}, Req, State) ->
%	erlang:start_timer(1000, self(), <<"How' you doin'?">>),
%	{reply, {text, Msg}, Req, State};
websocket_info({send_message, MessageBin}, Req, State) ->
	{reply, {text, MessageBin}, Req, State};
websocket_info(_Info, Req, State) ->
	{ok, Req, State}.

terminate(_Reason, _Req, _State) ->
	broadcaster:remove_session(self()),
	ok.
