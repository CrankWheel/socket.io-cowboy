-module(demo).

-export([start/0, open/3, recv/2, handle_info/2, close/1]).

-record(session_state, {sid}).

start() ->
    ok = mnesia:start(),
    ok = engineio_session:init_mnesia(),
    ok = engineio:start(),

    Dispatch = cowboy_router:compile([
        {'_', [
            {"/engine.io/[...]", engineio_handler, [engineio_session:configure([{heartbeat, 8000},
                {heartbeat_timeout, 15000},
                {session_timeout, 60000},
                {callback, ?MODULE},
                {enable_websockets, true}])]
            },
            {"/[...]", cowboy_static, {dir, <<"./priv">>, [{mimetypes, cow_mimetypes, web}]}}
        ]}
    ]),

    demo_mgr:start_link(),

    cowboy:start_http(engineio_http_listener, 100, [{host, "127.0.0.1"},
        {port, 8080}], [{env, [{dispatch, Dispatch}]}]).

%% ---- Handlers
open(Sid, _Opts, _OriginalRequest) ->
    error_logger:info_msg("open ~p ~p~n", [self(), Sid]),
    demo_mgr:add_session(self()),
    {ok, #session_state{}}.

recv({message, Message}, SessionState) ->
    demo_mgr:publish_to_all(Message),
    {ok, SessionState}.

handle_info(_Info, SessionState) ->
    {ok, SessionState}.

close(_SessionState = #session_state{sid = Sid}) ->
    error_logger:info_msg("close ~p ~p~n", [self(), Sid]),
    demo_mgr:remove_session(self()),
    ok.
