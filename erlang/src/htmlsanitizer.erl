%%% htmlsanitizer — clean HTML of constructs that can lead to XSS.
%%%
%%% A thin Erlang binding over the monorepo's ONE shared native engine
%%% (core/native/libhtmlsanitizer.so, compiled from pure Aether). No sanitizer
%%% logic lives here: every function marshals to an `aether_hs_embed_*` call
%%% through htmlsanitizer_nif.
%%%
%%%     {ok, S} = htmlsanitizer:new(),
%%%     <<"<div>Hello </div>">> =
%%%         htmlsanitizer:sanitize(S, <<"<div>Hello <script>x</script></div>">>),
%%%     ok = htmlsanitizer:close(S).
%%%
%%% This module's job is to turn the NIF's integer selectors into atoms, and
%%% its {ok, Binary} tuples into plain binaries for the common path. The
%%% *_r ("result") variants keep the tuple where a caller wants to distinguish
%%% a closed sanitizer from a legitimately empty result.
%%%
%%% NOTE ON CALLBACKS: this binding exposes NONE of the engine's hooks
%%% (on_removing_tag, on_filter_url, …). See README.md — a NIF cannot safely
%%% call back into the BEAM synchronously, so conformance checks 10 and 11 are
%%% skipped rather than faked.
-module(htmlsanitizer).

-export([new/0, close/1, is_closed/1,
         sanitize/2, sanitize/3, sanitize_r/3,
         sanitize_document/2, sanitize_document/3, sanitize_document_r/3,
         keep_child_nodes/1, set_keep_child_nodes/2,
         allow_data_attributes/1, set_allow_data_attributes/2,
         allow/3, disallow/3, is_allowed/3,
         clear/2, count/2, items/2, sorted_items/2,
         abi_version/0]).

-type sanitizer() :: htmlsanitizer_nif:sanitizer().
-export_type([sanitizer/0, list_name/0]).

%% The engine's six policy lists. These atoms map onto the ABI's integer
%% selectors, which are append-only and must never be renumbered.
-type list_name() :: tags
                   | attributes
                   | css_properties
                   | schemes
                   | classes
                   | uri_attributes.

%%------------------------------------------------------------------
%% Lifecycle
%%------------------------------------------------------------------

%% Create a sanitizer with the engine's secure defaults populated.
-spec new() -> {ok, sanitizer()} | {error, term()}.
new() -> htmlsanitizer_nif:new().

%% Release the native handle. Safe to call more than once. The resource's
%% destructor would do this anyway at GC time; close/1 makes it deterministic.
-spec close(sanitizer()) -> ok.
close(S) -> htmlsanitizer_nif:close(S).

-spec is_closed(sanitizer()) -> boolean().
is_closed(S) -> htmlsanitizer_nif:is_closed(S).

%%------------------------------------------------------------------
%% Sanitizing
%%------------------------------------------------------------------

%% Clean an HTML fragment with no base URL (relative URLs are not resolved).
-spec sanitize(sanitizer(), iodata()) -> binary().
sanitize(S, Html) -> sanitize(S, Html, <<>>).

%% Clean an HTML fragment, resolving relative URLs against BaseUrl.
%% Returns <<>> on a closed sanitizer; use sanitize_r/3 to tell the two apart.
-spec sanitize(sanitizer(), iodata(), iodata()) -> binary().
sanitize(S, Html, BaseUrl) -> unwrap(sanitize_r(S, Html, BaseUrl)).

-spec sanitize_r(sanitizer(), iodata(), iodata()) -> {ok, binary()} | {error, closed}.
sanitize_r(S, Html, BaseUrl) -> htmlsanitizer_nif:sanitize(S, Html, BaseUrl).

-spec sanitize_document(sanitizer(), iodata()) -> binary().
sanitize_document(S, Html) -> sanitize_document(S, Html, <<>>).

-spec sanitize_document(sanitizer(), iodata(), iodata()) -> binary().
sanitize_document(S, Html, BaseUrl) -> unwrap(sanitize_document_r(S, Html, BaseUrl)).

-spec sanitize_document_r(sanitizer(), iodata(), iodata()) -> {ok, binary()} | {error, closed}.
sanitize_document_r(S, Html, BaseUrl) -> htmlsanitizer_nif:sanitize_document(S, Html, BaseUrl).

unwrap({ok, Bin}) -> Bin;
unwrap({error, _}) -> <<>>.

%%------------------------------------------------------------------
%% Flags
%%------------------------------------------------------------------

%% Keep the children of a removed element instead of dropping the subtree.
-spec keep_child_nodes(sanitizer()) -> boolean().
keep_child_nodes(S) -> htmlsanitizer_nif:get_keep_child_nodes(S).

-spec set_keep_child_nodes(sanitizer(), boolean()) -> ok.
set_keep_child_nodes(S, On) when is_boolean(On) ->
    htmlsanitizer_nif:set_keep_child_nodes(S, On).

%% Let data-* attributes through without listing each one.
-spec allow_data_attributes(sanitizer()) -> boolean().
allow_data_attributes(S) -> htmlsanitizer_nif:get_allow_data_attributes(S).

-spec set_allow_data_attributes(sanitizer(), boolean()) -> ok.
set_allow_data_attributes(S, On) when is_boolean(On) ->
    htmlsanitizer_nif:set_allow_data_attributes(S, On).

%%------------------------------------------------------------------
%% Policy lists
%%------------------------------------------------------------------

%% ABI selectors — append only, never renumber (core/embed.ae).
-spec which(list_name()) -> 0..5.
which(tags)           -> 0;
which(attributes)     -> 1;
which(css_properties) -> 2;
which(schemes)        -> 3;
which(classes)        -> 4;
which(uri_attributes) -> 5.

%% Add an item (or a list of items) to a policy list.
-spec allow(sanitizer(), list_name(), iodata() | [iodata()]) -> boolean().
allow(S, List, Items) when is_list(Items), not is_integer(hd(Items)) ->
    lists:all(fun(I) -> allow(S, List, I) end, Items);
allow(S, List, Item) ->
    htmlsanitizer_nif:allow(S, which(List), Item).

%% Remove an item from a policy list (the "deny" direction).
-spec disallow(sanitizer(), list_name(), iodata() | [iodata()]) -> boolean().
disallow(S, List, Items) when is_list(Items), not is_integer(hd(Items)) ->
    lists:all(fun(I) -> disallow(S, List, I) end, Items);
disallow(S, List, Item) ->
    htmlsanitizer_nif:disallow(S, which(List), Item).

-spec is_allowed(sanitizer(), list_name(), iodata()) -> boolean().
is_allowed(S, List, Item) -> htmlsanitizer_nif:is_allowed(S, which(List), Item).

%% Empty a policy list — the "start from nothing" move for a caller who wants
%% a strict allow-list rather than the permissive defaults.
-spec clear(sanitizer(), list_name()) -> boolean().
clear(S, List) -> htmlsanitizer_nif:clear(S, which(List)).

-spec count(sanitizer(), list_name()) -> non_neg_integer().
count(S, List) -> htmlsanitizer_nif:count(S, which(List)).

%% Enumerate a policy list. Order is unspecified but stable between
%% mutations; use sorted_items/2 when a deterministic order matters.
-spec items(sanitizer(), list_name()) -> [binary()].
items(S, List) -> htmlsanitizer_nif:items(S, which(List)).

-spec sorted_items(sanitizer(), list_name()) -> [binary()].
sorted_items(S, List) -> lists:sort(items(S, List)).

%%------------------------------------------------------------------
%% Introspection
%%------------------------------------------------------------------

%% The engine's ABI revision.
-spec abi_version() -> non_neg_integer().
abi_version() -> htmlsanitizer_nif:abi_version().
