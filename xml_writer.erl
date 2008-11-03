-module(xml_writer).

-export([to_string/1]).


to_string(XML) ->
    lists:flatten(to_string1(XML)).

to_string1({Name, Attrs, Children}) ->
    [$<, Name,
     [[$ , K, $=, $",
       if
	   is_list(V) ->
	       entities:escape(V);
	   true ->
	       V2 = io_lib:format("~p", [V]),
	       entities:escape(V2)
       end,
       $"]
      || {K, V} <- Attrs],
     case Children of
	 [] -> "/>";
	 _ ->
	     [$>,
	      [to_string1(Child)
	       || Child <- Children],
	      $<, $/, Name, $>]
     end];

to_string1(S) when is_list(S) ->
    entities:escape(S).