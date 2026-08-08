%%% The binding conformance suite (docs/conformance.md), as EUnit.
%%%
%%% Proves the Erlang binding marshals every value shape across the FFI. It is
%%% NOT a sanitizer test suite — the behavioural cases live in the engine's own
%%% tests and run once, in Aether.
%%%
%%% Checks 10 (on_removing_tag cancels) and 11 (on_filter_url rewrites) are
%%% ABSENT ON PURPOSE. A NIF cannot synchronously call back into the BEAM, so
%%% this binding exposes no hooks at all; see README.md. Every other check is
%%% here in full, plus a few BEAM-specific ones (resource GC, iodata input).
%%%
%%% Named _SUITE for consistency with the OTP convention, but it is EUnit —
%%% one file, no ct_run, no configuration. `.build.ae` runs it with eunit:test.
-module(htmlsanitizer_conformance_SUITE).

-include_lib("eunit/include/eunit.hrl").

%% Every test takes a freshly created sanitizer and closes it afterwards, so
%% no test can leak policy state into the next.
with_sanitizer(F) ->
    {ok, S} = htmlsanitizer:new(),
    try F(S)
    after htmlsanitizer:close(S)
    end.

%%------------------------------------------------------------------
%% The 12 checks (10 and 11 deliberately absent — see the module doc)
%%------------------------------------------------------------------

t01_script_removed_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<div>Hello  world!</div>">>,
                     htmlsanitizer:sanitize(S, <<"<div>Hello <script>alert(1)</script> world!</div>">>))
    end).

t02_onclick_removed_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<div>Hello</div>">>,
                     htmlsanitizer:sanitize(S, <<"<div onclick=\"alert(1)\">Hello</div>">>))
    end).

t03_empty_string_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<>>, htmlsanitizer:sanitize(S, <<>>))
    end).

%% The literal is written as an explicit UTF-8 binary rather than a source
%% literal so the test does not depend on the compiler's encoding setting.
t04_utf8_round_trip_test() ->
    with_sanitizer(fun(S) ->
        Html = unicode:characters_to_binary("<div>café ☕</div>", utf8, utf8),
        ?assertEqual(Html, htmlsanitizer:sanitize(S, Html))
    end).

t05_allow_custom_tag_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<>>, htmlsanitizer:sanitize(S, <<"<my-widget>x</my-widget>">>)),
        ?assert(htmlsanitizer:allow(S, tags, <<"my-widget">>)),
        ?assertEqual(<<"<my-widget>x</my-widget>">>,
                     htmlsanitizer:sanitize(S, <<"<my-widget>x</my-widget>">>))
    end).

t06_disallow_tag_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<div>x</div>">>, htmlsanitizer:sanitize(S, <<"<div>x</div>">>)),
        ?assert(htmlsanitizer:disallow(S, tags, <<"div">>)),
        ?assertEqual(<<>>, htmlsanitizer:sanitize(S, <<"<div>x</div>">>))
    end).

t07_membership_and_count_test() ->
    with_sanitizer(fun(S) ->
        ?assert(htmlsanitizer:is_allowed(S, schemes, <<"http">>)),
        ?assertNot(htmlsanitizer:is_allowed(S, schemes, <<"gopher">>)),
        ?assertEqual(2, htmlsanitizer:count(S, schemes))
    end).

t08_enumeration_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual([<<"http">>, <<"https">>], htmlsanitizer:sorted_items(S, schemes))
    end).

t09_keep_child_nodes_test() ->
    with_sanitizer(fun(S) ->
        In = <<"<div><nope>Hello <span>world</span></nope></div>">>,
        ?assertEqual(<<"<div></div>">>, htmlsanitizer:sanitize(S, In)),
        ok = htmlsanitizer:set_keep_child_nodes(S, true),
        ?assert(htmlsanitizer:keep_child_nodes(S)),
        ?assertEqual(<<"<div>Hello <span>world</span></div>">>, htmlsanitizer:sanitize(S, In))
    end).

%% Checks 10 and 11 are not implementable on the BEAM — see README.md.
%% This test documents the gap rather than leaving a silent hole: if someone
%% later adds hooks to the NIF, they will find this and delete it.
t10_and_t11_callbacks_not_supported_test() ->
    ?assertNot(erlang:function_exported(htmlsanitizer, on_removing_tag, 2)),
    ?assertNot(erlang:function_exported(htmlsanitizer, on_filter_url, 2)).

t12_handles_are_independent_test() ->
    {ok, A} = htmlsanitizer:new(),
    {ok, B} = htmlsanitizer:new(),
    try
        ?assert(htmlsanitizer:allow(A, tags, <<"only-in-a">>)),
        ?assert(htmlsanitizer:is_allowed(A, tags, <<"only-in-a">>)),
        ?assertNot(htmlsanitizer:is_allowed(B, tags, <<"only-in-a">>))
    after
        htmlsanitizer:close(A),
        htmlsanitizer:close(B)
    end.

%%------------------------------------------------------------------
%% Extras — the marshalling corners the 12 do not reach
%%------------------------------------------------------------------

abi_version_test() ->
    ?assert(htmlsanitizer:abi_version() >= 1).

sanitize_document_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<div>doc</div>">>,
                     htmlsanitizer:sanitize_document(S, <<"<div>doc<script>x</script></div>">>))
    end).

base_url_resolution_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<img src=\"https://example.com/logo.png\">">>,
                     htmlsanitizer:sanitize(S, <<"<img src=\"logo.png\">">>,
                                            <<"https://example.com">>))
    end).

%% The NIF takes iodata, not just binaries — a caller assembling HTML from a
%% list should not have to flatten it first.
iodata_input_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<div>ab</div>">>,
                     htmlsanitizer:sanitize(S, [<<"<div>">>, "a", [<<"b">>], <<"</div>">>]))
    end).

allow_data_attributes_test() ->
    with_sanitizer(fun(S) ->
        ?assertEqual(<<"<div></div>">>, htmlsanitizer:sanitize(S, <<"<div data-x=\"1\"></div>">>)),
        ok = htmlsanitizer:set_allow_data_attributes(S, true),
        ?assert(htmlsanitizer:allow_data_attributes(S)),
        ?assertEqual(<<"<div data-x=\"1\"></div>">>,
                     htmlsanitizer:sanitize(S, <<"<div data-x=\"1\"></div>">>))
    end).

clear_empties_a_list_test() ->
    with_sanitizer(fun(S) ->
        ?assert(htmlsanitizer:clear(S, schemes)),
        ?assertEqual(0, htmlsanitizer:count(S, schemes)),
        ?assertEqual([], htmlsanitizer:items(S, schemes))
    end).

%% allow/3 and disallow/3 accept a list of items for the common bulk case.
bulk_allow_test() ->
    with_sanitizer(fun(S) ->
        ?assert(htmlsanitizer:allow(S, tags, [<<"one-tag">>, <<"two-tag">>])),
        ?assert(htmlsanitizer:is_allowed(S, tags, <<"one-tag">>)),
        ?assert(htmlsanitizer:is_allowed(S, tags, <<"two-tag">>))
    end).

%% A closed sanitizer must report itself closed rather than dereference a
%% freed pointer — the resource is still a live BEAM term after close/1.
closed_sanitizer_rejects_use_test() ->
    {ok, S} = htmlsanitizer:new(),
    ok = htmlsanitizer:close(S),
    ?assert(htmlsanitizer:is_closed(S)),
    ?assertEqual({error, closed}, htmlsanitizer:sanitize_r(S, <<"<div>x</div>">>, <<>>)),
    %% close/1 is idempotent
    ?assertEqual(ok, htmlsanitizer:close(S)).

%% A sanitizer nobody closed must still release its native handle when the GC
%% collects the resource. We cannot observe the free directly, but we can prove
%% the destructor path runs without crashing the VM under a forced GC.
dropped_sanitizer_is_collected_test() ->
    lists:foreach(fun(_) ->
        {ok, S} = htmlsanitizer:new(),
        _ = htmlsanitizer:sanitize(S, <<"<div>x</div>">>)
        %% deliberately no close/1
    end, lists:seq(1, 50)),
    erlang:garbage_collect(),
    ?assert(true).
