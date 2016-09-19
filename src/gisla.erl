%% gisla
%%
%% Copyright (C) 2016 by Mark Allen.
%%
%% You may only use this software in accordance with the terms of the MIT
%% license in the LICENSE file.

-module(gisla).
-include("gisla.hrl").

-export([
     new/0,
     new_entry/0,
     new/2,
     name_flow/2,
     make_flow_entry/3,
     make_flow_entry/4,
     add_flow_entry/2,
     delete_flow_entry/2,
     describe_flow/1,
     execute/2
]).

new() ->
    #flow{}.

new(Name, Flow) when is_list(Flow)
                     andalso ( is_atom(Name)
                     orelse is_binary(Name)
                     orelse is_list(Name) ) ->
    true = validate_flow(Flow),
    #flow{
       name = Name,
       pipeline = Flow
    }.

new_entry() ->
    #entry{}.

name_flow(Name, Flow = #flow{}) ->
    true = is_valid_name(Name),
    Flow#flow{ name = Name }.

make_flow_entry(Name, F, R) when is_atom(Name)
                 orelse is_binary(Name)
                 orelse is_list(Name) ->
    true = validate_flow_entry_function(F),
    true = validate_flow_entry_function(R),
    #entry{ name = Name, forward = F, rollback = R }.

make_flow_entry(Name, F, R, Timeout) when is_integer(Timeout)
                      andalso Timeout >= 0 ->
    Flow = make_flow_entry(Name, F, R),
    Flow#entry{ timeout = Timeout }.

add_flow_entry(E = #entry{}, Flow = #flow{ pipeline = P }) ->
    true = validate_flow_record(E),
    Flow#flow{ pipeline = P ++ [E] }.

delete_flow_entry(#entry{name = N}, Flow = #flow{ pipeline = P }) ->
    true = is_valid_name(N),
    NewPipeline = lists:keydelete(N, #entry.name, P),
    Flow#flow{ pipeline = NewPipeline }.

describe_flow(#flow{ name = N, pipeline = P }) ->
    {N, [ E#flow.name || E <- P ]}.

execute(F = #flow{ name = N, pipeline = P }, State) ->
    io:format("Starting flow ~p", [N]),
    do_pipeline(P, F, State).

%% Private functions

do_pipeline([], _F, State) -> State;
do_pipeline([H|T], F = #flow{ pipeline = P, direction = D }, State) ->
    {Tail, NewFlow, NewState} = case do_entry(H, State, D) of 
    {ok, State0} ->
        {T, F, State0};
    {failed, State1} ->
        case D of
        forward ->
            Name = H#entry.name,
            ReversePipeline = lists:reverse(P),
            NewTail = lists:dropwhile( fun(E) -> E#entry.name /= Name end, ReversePipeline ),
            {NewTail, F#flow{ direction = rollback }, State1};
        rollback ->
            io:format("Error during rollback. Giving up."),
            error(failed_rollback)
        end
    end,
    do_pipeline(Tail, NewFlow, NewState).

do_entry(#entry{ name = N, rollback = R, timeout = T }, State, rollback) ->
    exec_flow(N, R, T, State);
do_entry(#entry{ name = N, forward = F, timeout = T }, State, forward) ->
    exec_flow(N, F, T, State).


exec_flow(Name, Func, 0, State) ->
    exec_flow(Name, Func, infinity, State);
exec_flow(Name, Func, Timeout, State) ->
    F = make_closure(Func, self(), State),
    {Mref, Pid} = spawn_monitor(fun() -> F() end),
    io:format("Started pid ~p to execute flow entry ~p", [Pid, Name]),
    receive_loop(Mref, Pid, Timeout, State).

receive_loop(Mref, Pid, Timeout, State) ->
    receive
    {race_conditions_are_bad_mmmkay, NewState} ->
        {ok, NewState};
    {result, NewState} ->
        demonitor(Mref, [flush]), %% prevent us from getting any spurious failures and clean out our mailbox
        self() ! {race_conditions_are_bad_mmmkay, NewState},
        receive_loop(Mref, Pid, Timeout, State);
    {'DOWN', Mref, process, Pid, normal} ->
        %% so we exited fine but didn't get a results reply yet... let's loop around maybe it will be
        %% the next message in our mailbox.
        receive_loop(Mref, Pid, Timeout, State);
    {'DOWN', Mref, process, Pid, Reason} ->
        %% We crashed for some reason
        io:format("Pid ~p failed because ~p", [Pid, Reason]),
        {failed, State};
    Msg ->
        io:format("Some rando message just showed up! ~p Ignoring.", [Msg]),
        receive_loop(Mref, Pid, Timeout, State)
    after Timeout ->
    io:format("Pid ~p timed out after ~p milliseconds", [Pid, Timeout]),
    {failed, State}
    end.

make_closure({M, F, A}, ReplyPid, State) ->
    fun() -> ReplyPid ! {result, M:F(A ++ [State])} end;
make_closure(F, ReplyPid, State) when is_function(F) ->
    fun() -> ReplyPid ! {result, F(State)} end.

validate_flow(L) when is_list(L) ->
    lists:all(fun validate_flow_record/1, L).

validate_flow_record(#entry{ name = N, forward = F, rollback = R }) ->
    is_valid_name(N)
    andalso validate_flow_entry_function(F)
    andalso validate_flow_entry_function(R).

validate_flow_entry_function(E) when is_function(E) -> true;
validate_flow_entry_function({M, F, A}) when is_atom(M)
                                             andalso is_atom(F)
                                             andalso is_list(A) -> true;
validate_flow_entry_function(_) -> false.

is_valid_name(N) ->
    is_atom(N) orelse is_binary(N) orelse is_list(N).

%% unit tests

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-compile([export_all]).

test_function() -> <<"foo">>.

valid_name_test_() ->
    [
      ?_assert(is_valid_name("moogle")),
      ?_assert(is_valid_name(<<"froogle">>)),
      ?_assert(is_valid_name(good)),
      ?_assert_equal(false, is_valid_name(1))
    ].

validate_flow_entry_function_test_() ->
    F = fun(E) -> E, ok end,
    [
      ?_assert(validate_flow_entry_function(fun() -> ok end)),
      ?_assert(validate_flow_entry_function({?MODULE, test_function, []})),
      ?_assert(validate_flow_entry_function(F)),
      ?_assertEqual(false, validate_flow_entry_function(<<"function">>)),
      ?_assertEqual(false, validate_flow_entry_function(decepticons)),
      ?_assertEqual(false, validate_flow_entry_function("function")),
      ?_assertEqual(false, validate_flow_entry_function(42))
    ].

validate_flow_test_() ->
    F = fun(E) -> E, ok, end,
    G = {?MODULE, test_function, []},
    TestEntry1 = #entry{ name = test1, forward = F, rollback = G },
    TestEntry2 = #entry{ name = test2, forward = G, rollback = F },
    TestFlow = #flow{ name = test_flow, pipeline = [ TestEntry1, TestEntry2 ] },
    BadNameFlow = #flow{ name = 4, pipeline = [ TestEntry1, TestEntry2 ] },
    BadPipeline = #flow{ name = foo, pipeline = kevin },
    [
      ?_assert(validate_flow(TestFlow)),
      ?_assertEqual(false, validate_flow(BadNameFlow)),
      ?_assertEqual(false, validate_flow(BadPipeline))
    ].

-endif.