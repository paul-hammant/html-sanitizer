%%% htmlsanitizer_nif — the raw NIF surface.
%%%
%%% This module exists only to load c_src/htmlsanitizer_nif.c and to give each
%%% native function a stub. Nothing here is meant to be called directly;
%%% `htmlsanitizer` is the module with the friendly API. It is exported all the
%%% same, because Elixir and Gleam bind against THIS module: they defdelegate /
%%% @external straight to these arities rather than each shipping their own
%%% copy of the C.
%%%
%%% Every stub raises if the NIF failed to load, which is the standard idiom —
%%% a stub that silently returned a wrong answer would be far worse than a
%%% crash pointing at the real problem.
-module(htmlsanitizer_nif).

-export([new/0, close/1, is_closed/1,
         sanitize/3, sanitize_document/3,
         set_keep_child_nodes/2, get_keep_child_nodes/1,
         set_allow_data_attributes/2, get_allow_data_attributes/1,
         allow/3, disallow/3, is_allowed/3,
         clear/2, count/2, items/2,
         abi_version/0]).

-on_load(init/0).

-define(APPNAME, htmlsanitizer_nif).
-define(LIBNAME, htmlsanitizer_nif).

%% The opaque sanitizer handle — an enif_resource. The GC frees the native
%% handle when the last reference goes; close/1 makes that deterministic.
-opaque sanitizer() :: reference().
-export_type([sanitizer/0]).

-type which() :: 0..5.

%%------------------------------------------------------------------
%% Loading
%%------------------------------------------------------------------

%% Load the NIF, handing the C side our priv/ directory so it can find the
%% bundled engine .so without guessing. The C load callback tries
%% $HTMLSANITIZER_LIB first, then priv/, then the OS loader path.
init() ->
    PrivDir = priv_dir(),
    SoPath = filename:join(PrivDir, atom_to_list(?LIBNAME)),
    erlang:load_nif(SoPath, list_to_binary(PrivDir)).

%% code:priv_dir/1 fails when the app is only on the code path as loose beams
%% (which is how a bare `erl -pa ebin` run looks); fall back to the sibling of
%% the ebin directory this module was loaded from.
priv_dir() ->
    case code:priv_dir(?APPNAME) of
        {error, bad_name} ->
            case code:which(?MODULE) of
                Beam when is_list(Beam) ->
                    filename:join(filename:dirname(filename:dirname(Beam)), "priv");
                _ ->
                    "priv"
            end;
        Dir ->
            Dir
    end.

%%------------------------------------------------------------------
%% Stubs — replaced by the NIF at load time
%%------------------------------------------------------------------

-spec new() -> {ok, sanitizer()} | {error, term()}.
new() -> not_loaded(?LINE).

-spec close(sanitizer()) -> ok.
close(_S) -> not_loaded(?LINE).

-spec is_closed(sanitizer()) -> boolean().
is_closed(_S) -> not_loaded(?LINE).

-spec sanitize(sanitizer(), iodata(), iodata()) -> {ok, binary()} | {error, closed}.
sanitize(_S, _Html, _BaseUrl) -> not_loaded(?LINE).

-spec sanitize_document(sanitizer(), iodata(), iodata()) -> {ok, binary()} | {error, closed}.
sanitize_document(_S, _Html, _BaseUrl) -> not_loaded(?LINE).

-spec set_keep_child_nodes(sanitizer(), boolean()) -> ok | {error, closed}.
set_keep_child_nodes(_S, _On) -> not_loaded(?LINE).

-spec get_keep_child_nodes(sanitizer()) -> boolean() | {error, closed}.
get_keep_child_nodes(_S) -> not_loaded(?LINE).

-spec set_allow_data_attributes(sanitizer(), boolean()) -> ok | {error, closed}.
set_allow_data_attributes(_S, _On) -> not_loaded(?LINE).

-spec get_allow_data_attributes(sanitizer()) -> boolean() | {error, closed}.
get_allow_data_attributes(_S) -> not_loaded(?LINE).

-spec allow(sanitizer(), which(), iodata()) -> boolean() | {error, term()}.
allow(_S, _Which, _Item) -> not_loaded(?LINE).

-spec disallow(sanitizer(), which(), iodata()) -> boolean() | {error, term()}.
disallow(_S, _Which, _Item) -> not_loaded(?LINE).

-spec is_allowed(sanitizer(), which(), iodata()) -> boolean() | {error, term()}.
is_allowed(_S, _Which, _Item) -> not_loaded(?LINE).

-spec clear(sanitizer(), which()) -> boolean() | {error, term()}.
clear(_S, _Which) -> not_loaded(?LINE).

-spec count(sanitizer(), which()) -> non_neg_integer() | {error, term()}.
count(_S, _Which) -> not_loaded(?LINE).

-spec items(sanitizer(), which()) -> [binary()] | {error, term()}.
items(_S, _Which) -> not_loaded(?LINE).

-spec abi_version() -> non_neg_integer().
abi_version() -> not_loaded(?LINE).

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).
