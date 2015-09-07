-module(broadcaster).

-behavior(gen_server).

%% API
-export([start/0, publish_to_all/1, add_session/1, remove_session/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {sessions}).

start() ->
    gen_server:start({local, ?MODULE}, ?MODULE, [], []).

publish_to_all(MessageBin) ->
    gen_server:cast(?MODULE, {publish_to_all, MessageBin}).

add_session(Pid) ->
    gen_server:call(?MODULE, {add_session, Pid}).

remove_session(Pid) ->
    gen_server:call(?MODULE, {remove_session, Pid}).

init([]) ->
    {ok, #state{sessions = sets:new()}}.

handle_call({add_session, Pid}, _From, State) ->
    {reply, ok, State#state{sessions = sets:add_element(Pid, State#state.sessions)}};
handle_call({remove_session, Pid}, _From, State) ->
    {reply, ok, State#state{sessions = sets:del_element(Pid, State#state.sessions)}};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({publish_to_all, MessageBin}, State) ->
    sets:fold(fun(Pid, AccIn) ->
                      Pid ! {send_message, MessageBin},
                      AccIn
              end, notused, State#state.sessions),
    {noreply, State};
handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
