-module(feed_reader).

-behaviour(gen_server).

%% API
-export([start_link/1, push/2, get_results/1, parse_date/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("feed.hrl").

-record(state, {result_waiters = [],
		parser,
		url,
		stack = [],
		record = false, %% false | text | tree
		current = "",
		feed = #feed{},
		entries = [],
		feed_done = false,
		entry_done = false
	       }).

%% TODO: dates, xml:base

%%====================================================================
%% API
%%====================================================================
start_link(BaseURL) ->
    gen_server:start_link(?MODULE, [BaseURL], []).

push(Pid, Data) ->
    gen_server:cast(Pid, {push, Data}).

get_results(Pid) ->
    gen_server:call(Pid, get_results).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init([BaseURL]) ->
    I = self(),
    {ok, Parser} = tagsoup_parser:start_link(
		     fun(Msg) ->
			     gen_server:cast(I, Msg)
		     end),
    {ok, #state{parser = Parser,
		url = BaseURL}}.

handle_call(get_results, _From, #state{parser = none,
				       feed_done = false} = State) ->
    {reply, incomplete, State};

handle_call(get_results, _From, #state{parser = none,
				       url = BaseURL1,
				       feed = Feed,
				       entries = Entries} = State) ->
    BaseURL = url:parse(BaseURL1),
    %% Linkify
    Feed2 = Feed#feed{link = url:to_string(
			       url:join(BaseURL, Feed#feed.link))},
    %% Last entry done?
    Entries2 = case Entries of
		   [_ | Entries1]
		   when State#state.entry_done =/= true ->
		       Entries1;
		   _ ->
		       Entries
	       end,
    Entries3 = lists:reverse(Entries2),
    %% Only entries with link
    Entries4 = [Entry || #entry{link = Link} = Entry <- Entries3,
			 Link =/= undefined],
    %% IDify
    Entries5 = lists:map(
		 fun(#entry{id = undefined, link = Link} = Entry) ->
			 Entry#entry{id = Link};
		    (Entry) ->
			 Entry
		 end, Entries4),
    %% Linkify
    Entries6 = [Entry#entry{link = url:to_string(
				     url:join(BaseURL, Link))}
		|| #entry{link = Link} = Entry <- Entries5],
    %% Tidy up
    Entries7 = lists:map(
		 fun(#entry{description = Description} = Entry)
		    when is_list(Description) ->
			 {ok, Description2} = tidy:tidy(Description),
			 Entry#entry{description = Description2};
		    (Entry) ->
			 Entry#entry{description = ""}
		 end, Entries6),
    %% TODO: parse tidied up, rewrite links and imgs, remove script tags
    %% and seperate from feed_reader
    Reply = {Feed2, Entries7},
    {reply, Reply, State};

handle_call(get_results, From, #state{result_waiters = [_ | _] = ResultWaiters} = State) ->
    {noreply, State#state{result_waiters = [From | ResultWaiters]}};

handle_call(get_results, From, #state{parser = Parser,
				      result_waiters = []} = State) ->
    I = self(),
    spawn_link(fun() ->
		       tagsoup_parser:stop(Parser),
		       gen_server:cast(I, done)
	       end),
    {noreply, State#state{result_waiters = [From]}}.

handle_cast(done, #state{result_waiters = ResultWaiters} = State) ->
    State2 = State#state{parser = none,
			 result_waiters = []},
    State3 = lists:foldl(
	       fun(Waiter, State1) ->
		       %% FIXME: this is sick :-)
		       {reply, Reply, State1New} = handle_call(get_results,
							       Waiter,
							       State1),
		       gen_server:reply(Waiter, Reply),
		       State1New
	       end, State2, ResultWaiters),
    {noreply, State3};

%% push

handle_cast({push, Data}, #state{parser = Parser} = State) ->
    tagsoup_parser:push(Parser, Data),
    {noreply, State};


%% tagsoup callbacks

handle_cast({start_element, Name, Attributes}, #state{stack = Stack} = State) ->
    Name1 = mangle_element_name(Name),
    State2 = start_element(State#state{stack = [Name1 | Stack]}, Attributes),
    if
	State#state.record =/= State2#state.record ->
	    {noreply, State2#state{current = ""}};
	true ->
	    {noreply, State2}
    end;

handle_cast({end_element, Name}, #state{stack = Stack, current = Current} = State) ->
    Name1 = mangle_element_name(Name),
    State2 = State#state{current = util:string_chomp(Current)},
    case end_element_in_stack(Name1, Stack) of
	undefined ->
	    {noreply, State2};
	{NewStack, OldStacks} ->
	    State3 =
		lists:foldl(
		  fun(OldStack, State1) ->
			  end_element(State1#state{stack = OldStack})
		  end, State2, OldStacks),
	    {noreply, State3#state{stack = NewStack}}
    end;

handle_cast({text, Text}, #state{record = text, current = Current} = State) ->
    {noreply, State#state{current = Current ++ Text}};

handle_cast({text, Text}, #state{record = markup, current = Current} = State) ->
    {noreply, State#state{current = Current ++ entities:escape(Text)}};

handle_cast({text, _}, #state{record = false} = State) ->
    {noreply, State};

handle_cast(_, State) ->
    {noreply, State}.
		      

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

mangle_element_name(Name) ->
    Name2 = string:to_lower(Name),
    case string:chr(Name2, $:) of
	0 ->
	    Name2;
	N ->
	    string:substr(Name2, N + 1)
    end.

get_attr_s(Name, Attributes) ->
    case lists:keysearch(Name, 1, Attributes) of
	{value, {_, Value}} ->
	    Value;
	false ->
	    ""
    end.

%% returns a list of stacks for each ended element
end_element_in_stack(Name, Stack) ->
    end_element_in_stack(Name, Stack, []).

end_element_in_stack(Name, [Name | Stack1] = Stack, EndedStacks) ->
    {Stack1, lists:reverse([Stack | EndedStacks])};
end_element_in_stack(Name, [_ | Stack1] = Stack, Ended) ->
    end_element_in_stack(Name, Stack1, [Stack | Ended]);
end_element_in_stack(_, [], _) ->
    undefined.


start_element(#state{stack = [Format]} = State, _) ->
    case Format of
	"feed" -> ok;
	"rss" -> ok;
	"rdf" -> ok;
	_ -> exit(unsupported_feed_format)
    end,
    State#state{stack = [Format]};

%% RSS & RDF

start_element(#state{stack = Stack} = State, _)
  when tl(Stack) =:=  ["item", "channel", "rss"];
       tl(Stack) =:= ["item", "rdf"] ->
    State#state{record = text};

start_element(#state{stack = Stack,
		     entries = Entries} = State, _)
  when Stack =:=  ["item", "channel", "rss"];
       Stack =:= ["item", "rdf"] ->
    State#state{record = false,
		feed_done = true,
		entry_done = false, entries = [#entry{} | Entries]};

start_element(#state{stack = [_, "channel", _]} = State, _) ->
    State#state{record = text};

%% ATOM

start_element(#state{stack = ["link", "feed"],
		     feed = Feed} = State, Attr) ->
    Href = get_attr_s("href", Attr),
    Rel = get_attr_s("rel", Attr),
    NewLink = case {Feed#feed.link, Rel} of
		  %% Get at least one <link/>
		  {undefined, _} -> Href;
		  %% but prefer <link rel="alternate"/>
		  {_, "alternate"} -> Href;
		  %% or keep the previous one
		  {OldLink, _} -> OldLink
	      end,
    State#state{record = false,
		feed = Feed#feed{link = NewLink}};

start_element(#state{stack = ["link", "entry", "feed"],
		     entries = [Entry | Entries]} = State, Attr) ->
    Href = get_attr_s("href", Attr),
    Rel = get_attr_s("rel", Attr),
    NewLink = case {Entry#entry.link, Rel} of
		  %% Get at least one <link/>
		  {undefined, _} -> Href;
		  %% but prefer <link rel="alternate"/>
		  {_, "alternate"} -> Href;
		  %% or keep the previous one
		  {OldLink, _} -> OldLink
	      end,
    State#state{record = false,
		entries = [Entry#entry{link = NewLink} | Entries]};

start_element(#state{stack = [_, "entry", "feed"]} = State, Attrs) ->
    State#state{record = record_by_atom_type(get_attr_s("type", Attrs))};

start_element(#state{stack = ["entry", "feed"],
		     entries = Entries} = State, _) ->
    State#state{record = false,
		feed_done = true,
		entry_done = false,
		entries = [#entry{} | Entries]};

start_element(#state{stack = [_, "feed"]} = State, Attrs) ->
    State#state{record = record_by_atom_type(get_attr_s("type", Attrs))};

%% Fall-through

start_element(#state{record = markup,
		     stack = [Name | _],
		     current = Current} = State, Attrs) ->
    Current2 = lists:flatten(
		 [Current,
		  $<, Name,
		  lists:map(fun({K, V}) ->
				    io_lib:format(" ~s=\"~s\"",
						  [K, entities:escape(V)])
			    end, Attrs),
		  $>]),
    State#state{current = Current2};

start_element(State, _) ->
    State.


%% RSS

end_element(#state{stack = [Tag, "channel", _],
		   current = Current,
		   feed = Feed} = State) ->
    State#state{record = false,
		feed = rss_channel(Feed, Tag, Current)};

end_element(#state{stack = [Tag | Stack],
		   current = Current,
		   entries = [Entry | Entries]} = State)
  when Stack =:= ["item", "channel", "rss"];
       Stack =:= ["item", "rdf"] ->
    State#state{record = false,
		entries = [rss_channel_item(Entry, Tag, Current) | Entries]};

end_element(#state{stack = Stack} = State)
  when Stack =:=  ["item", "channel", "rss"];
       Stack =:= ["item", "rdf"] ->
    %% TODO: emit current entry
    State#state{record = false,
		feed_done = true,
		entry_done = true};

end_element(#state{stack = [_, "channel", _]} = State) ->
    State#state{record = false};

end_element(#state{stack = ["channel", _]} = State) ->
    State#state{record = false,
		feed_done = true};

%% ATOM

end_element(#state{stack = ["entry", "feed"]} = State) ->
    State#state{record = false,
		entry_done = true};

end_element(#state{stack = [Tag, "feed"],
		   current = Current,
		   feed = Feed} = State) ->
    State#state{record = false,
		feed = atom_feed(Feed, Tag, Current)};

end_element(#state{stack = [Tag, "entry", "feed"],
		   current = Current,
		   entries = [Entry | Entries]} = State) ->
    State#state{record = false,
		entries = [atom_entry(Entry, Tag, Current) | Entries]};


%% Fall-through

end_element(#state{record = markup,
		     stack = [Name | _],
		     current = Current} = State) ->
    Current2 = lists:flatten(
		 [Current,
		  "</", Name, $>]),
    State#state{current = Current2};

end_element(State) ->
    State.


%% RSS

rss_channel(Feed, "title", Text) ->
    Feed#feed{title = Text};
rss_channel(Feed, "link", Text) ->
    Feed#feed{link = Text};
rss_channel(Feed, "description", Text) ->
    Feed#feed{description = Text};
rss_channel(Feed, _, _) ->
    Feed.

rss_channel_item(Entry, "guid", Text) ->
    Entry#entry{id = Text};
rss_channel_item(Entry, "title", Text) ->
    Entry#entry{title = Text};
rss_channel_item(Entry, "link", Text) ->
    Entry#entry{link = Text};
rss_channel_item(Entry, "content:encoded", Text) ->
    Entry#entry{description = Text};
rss_channel_item(#entry{description = undefined} = Entry, "encoded", Text) ->
    Entry#entry{description = Text};
rss_channel_item(#entry{description = undefined} = Entry, "description", Text) ->
    Entry#entry{description = Text};
rss_channel_item(Entry, "pubDate", Text) ->
    Entry#entry{date = parse_date(Text)};
rss_channel_item(Entry, "pubdate", Text) ->
    Entry#entry{date = parse_date(Text)};
rss_channel_item(Entry, "date", Text) ->
    Entry#entry{date = parse_date(Text)};
rss_channel_item(Entry, _N, _) ->
    Entry.


%% ATOM

atom_feed(Feed, "title", Text) ->
    Feed#feed{title = Text};
atom_feed(Feed, "subtitle", Text) ->
    Feed#feed{description = Text};
atom_feed(Feed, _, _) ->
    Feed.


atom_entry(Entry, "id", Text) ->
    Entry#entry{id = Text};
atom_entry(Entry, "title", Text) ->
    Entry#entry{title = Text};
atom_entry(Entry, "content", Text) ->
    Entry#entry{description = Text};
atom_entry(Entry, "updated", Text) ->
    Entry#entry{date = parse_date(Text)};
atom_entry(Entry, "published", Text) ->
    Entry#entry{date = parse_date(Text)};
atom_entry(Entry, "modified", Text) ->
    Entry#entry{date = parse_date(Text)};
atom_entry(Entry, "issued", Text) ->
    Entry#entry{date = parse_date(Text)};
atom_entry(Entry, _, _) ->
    Entry.


record_by_atom_type("html") -> text;
record_by_atom_type(_) -> markup.



-define(DT0, {{0, 0, 0}, {0, 0, 0}}).

%% TODO: tz drift
parse_date(S) ->
    R = lists:foldl(
	  fun({RE, Bindings}, undefined) ->
		  parse_date(S, RE, Bindings);
	     (_, R) -> R
	  end, undefined, [{"(\\d+)-(\\d+)-(\\d+)T(\\d+):(\\d+):(\\d+)", [y,mo,d,h,m,s]},
			   %% Wed, 20 Apr 2005 19:38:15 +0200
			   %% Fri, 22 Apr 2005 10:31:12 GMT
			   {".+?, +(\\d+) (.+?) (\\d+) (\\d+):(\\d+):(\\d+)", [d,month,y,h,m,s]},
			   %% 06 May 2007 02:20:00
			   {"(\\d+) (.+?) (\\d{4}) (\\d+):(\\d+):(\\d+)", [d,month,y,h,m,s]}]),
    case R of
	undefined ->
	    error_logger:warn_msg("Unrecognized date format: ~p~n", [S]),
	    R;
	_ ->
	    %%error_logger:info_msg("Date ~p -> ~p~n", [S, R]),
	    R
    end.

parse_date(S, Regex, Bindings) ->
    case re:run(S, Regex, [{capture,all,list}]) of
	{match, [_ | Matches]} ->
	    {DT2, _} =
		lists:foldl(
		  fun(_, {DT1, []}) ->
			  {DT1, []};
		     (Match, {DT1, [Binding | Bindings1]}) ->
			  {parse_date_apply_binding(Binding, DT1, Match), Bindings1}
		  end, {?DT0, Bindings}, Matches),
	    DT2;
	_->
	    undefined
    end.

parse_date_apply_binding(month, {{Y, _, D}, T}, "Jan") ->
    {{Y, 1, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Feb") ->
    {{Y, 2, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Mar") ->
    {{Y, 3, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Apr") ->
    {{Y, 4, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "May") ->
    {{Y, 5, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Jun") ->
    {{Y, 6, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Jul") ->
    {{Y, 7, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Aug") ->
    {{Y, 8, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Sep") ->
    {{Y, 9, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Oct") ->
    {{Y, 10, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Nov") ->
    {{Y, 11, D}, T};
parse_date_apply_binding(month, {{Y, _, D}, T}, "Dec") ->
    {{Y, 12, D}, T};

parse_date_apply_binding(d, {{Y, M, _}, T}, D) ->
    {D1, ""} = string:to_integer(D),
    {{Y, M, D1}, T};
parse_date_apply_binding(mo, {{Y, _, D}, T}, M) ->
    {M1, ""} = string:to_integer(M),
    {{Y, M1, D}, T};
parse_date_apply_binding(y, {{_, M, D}, T}, Y) ->
    {Y1, ""} = string:to_integer(Y),
    {{Y1, M, D}, T};
parse_date_apply_binding(h, {D, {_, M, S}}, H) ->
    {H1, ""} = string:to_integer(H),
    {D, {H1, M, S}};
parse_date_apply_binding(m, {D, {H, _, S}}, M) ->
    {M1, ""} = string:to_integer(M),
    {D, {H, M1, S}};
parse_date_apply_binding(s, {D, {H, M, _}}, S) ->
    {S1, ""} = string:to_integer(S),
    {D, {H, M, S1}}.
