-module(dns_cache).

-behaviour(gen_server).

%% API
-export([start_link/0, lookup/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-record(state, {}).

-define(TTL, 60).
-record(dnsquery, {name,
		   %% querying | done
		   state,
		   %% for querying state
		   worker, requesters,
		   %% for done state
		   result, updated}).

%%====================================================================
%% API
%%====================================================================
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% TODO: recognize numeric addresses
-define(LOOKUP_TIMEOUT, 30).
lookup(Name) ->
    case gen_server:call(?SERVER, {lookup, Name}, ?LOOKUP_TIMEOUT * 1000) of
	{ok, Addresses} ->
	    Addresses;
	{error, Reason} ->
	    exit(Reason)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([]) ->
    mnesia:create_table(dnsquery,
			[{attributes, record_info(fields, dnsquery)}]),
    process_flag(trap_exit, true),
    {ok, #state{}}.

handle_call({lookup, Name}, From, State) ->
    Now = util:current_timestamp(),
    F = fun() ->
		case mnesia:read({dnsquery, Name}) of
		    %% New
		    [] ->
			case (catch dns_worker:start_link(Name)) of
			    {ok, Pid} ->
				mnesia:write(#dnsquery{name = Name,
						       state = querying,
						       worker = Pid,
						       requesters = [From]}),
				{noreply, State};
			    {'EXIT', Reason} ->
				{error, Reason}
			end;
		    %% TTL reached
		    [#dnsquery{state = done,
			       updated = Updated}]
		    when Updated + ?TTL < Now ->
			case (catch dns_worker:start_link(Name)) of
			    {ok, Pid} ->
				mnesia:write(#dnsquery{name = Name,
						       state = querying,
						       worker = Pid,
						       requesters = [From]}),
				{noreply, State};
			    {'EXIT', Reason} ->
				{error, Reason}
			end;
		    %% Already querying
		    [#dnsquery{state = querying,
			       requesters = R} = Q] ->
			mnesia:write(Q#dnsquery{requesters = [From | R]}),
			{noreply, State};
		    %% Done
		    [#dnsquery{state = done,
			       result = Result}] ->
			{reply, Result, State}
		end
	end,
    case mnesia:transaction(F) of
	{atomic, R} ->
	    R;
	{aborted, Reason} ->
	    {reply, {error, Reason}, State}
    end.

handle_cast({result, Name, Result}, State) ->
    F = fun() ->
		[Q] = mnesia:read({dnsquery, Name}),
		mnesia:write(Q#dnsquery{state = done,
					result = Result,
					updated = util:current_timestamp(),
					worker = none,
					requesters = []}),
		Q#dnsquery.requesters
	end,
    {atomic, Requesters} = mnesia:transaction(F),
    lists:foreach(fun(Requester) ->
			  gen_server:reply(Requester, Result)
		  end, Requesters),
    {noreply, State}.

handle_info({'EXIT', From, Reason}, State) ->
    Result = {error, Reason},
    F = fun() ->
		case mnesia:select(dnsquery,
				   [{#dnsquery{worker = From,
					       _ = '_'},
				     [], ['$$']}]) of
		    [Q] ->
			mnesia:write(Q#dnsquery{state = done,
						result = Result,
						updated = util:current_timestamp(),
						worker = none,
						requesters = []}),
			Q#dnsquery.requesters;
		    _ ->
			[]
		end
	end,
    {atomic, Requesters} = mnesia:transaction(F),
    lists:foreach(fun(Requester) ->
			  gen_server:reply(Requester, Result)
		  end, Requesters),
    {noreply, State};

handle_info(_, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

