/// The 1:1 symbol table for the HtmlSanitizer C ABI (`core/embed.ae`).
///
/// This library is the ONLY place in the Dart binding that knows about the C
/// ABI. Everything above it (`sanitizer.dart`) is idiomatic Dart over these
/// symbols. No sanitizer logic lives here or anywhere else in this package —
/// the engine is `core/htmlsanitizer.ae`, shared by every language binding.
///
/// ## Naming
///
/// `core/embed.ae` names its exports `hs_embed_<name>`; building with
/// `--emit=lib` mangles them to **`aether_hs_embed_<name>`**. That mangled
/// name is what we look up.
///
/// ## The two ownership rules
///
///  1. **Every `char*` this ABI returns is caller-owned** and must be handed
///     back to `aether_hs_embed_free_string`. Leaking it is the single most
///     common bug in a binding — [Api.takeString] does the right thing.
///  2. **Node and attribute pointers handed to a callback are borrowed** —
///     valid only for the duration of that callback, because the DOM is freed
///     when `sanitize` returns. Never retain one.
///
/// ## Callback ABI
///
/// Each hook receives the opaque `user_data` registered alongside it as its
/// **first** argument; the engine's C trampolines (`core/_embed_support.c`)
/// supply it. Integer arguments are C `int` (`ffi.Int`), *not* `long`.
library;

import 'dart:ffi' as ffi;
import 'dart:io' show Directory, Platform;

import 'package:ffi/ffi.dart' as pkgffi;

// ---- allow-list selectors (ABI constants — append only, never renumber) ----

/// `allowed_tags`
const int kTags = 0;

/// `allowed_attributes`
const int kAttributes = 1;

/// `allowed_css_properties`
const int kCssProperties = 2;

/// `allowed_schemes`
const int kSchemes = 3;

/// `allowed_classes`
const int kClasses = 4;

/// `uri_attributes`
const int kUriAttributes = 5;

// ---- removal reasons, as passed to the callbacks ----

const int kReasonNotAllowedTag = 0;
const int kReasonNotAllowedAttribute = 1;
const int kReasonNotAllowedStyle = 2;
const int kReasonNotAllowedUrlValue = 3;
const int kReasonNotAllowedValue = 4;
const int kReasonNotAllowedCssClass = 5;
const int kReasonClassAttributeEmpty = 6;
const int kReasonStyleAttributeEmpty = 7;

// ---- node kinds ----

const int kNodeDocument = 1;
const int kNodeElement = 2;
const int kNodeText = 3;
const int kNodeComment = 4;

// ---- native callback typedefs ----
//
// Note each takes `user_data` first, and every integer is `ffi.Int` (C `int`).

/// `int f(void* ud, void* node, int reason)` — non-zero cancels the removal.
typedef CbRemovingTagNative = ffi.Int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.Int);
typedef CbRemovingTagDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, int);

/// `int f(void* ud, void* elem, void* attr, int reason)` — non-zero cancels.
typedef CbRemovingAttributeNative = ffi.Int Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.Int);
typedef CbRemovingAttributeDart = int Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, int);

/// `int f(void* ud, void* elem, const char* name, const char* value,
/// int reason)` — non-zero cancels.
typedef CbRemovingStyleNative = ffi.Int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Int);
typedef CbRemovingStyleDart = int Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>,
    int);

/// `int f(void* ud, void* node)` — non-zero cancels the removal.
typedef CbRemovingCommentNative = ffi.Int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef CbRemovingCommentDart = int Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

/// `void f(void* ud, void* node)`
typedef CbPostProcessNative = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef CbPostProcessDart = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);

/// `char* f(void* ud, void* elem, const char* raw, const char* resolved)`
///
/// Returns a malloc'd C string the engine takes ownership of, or the
/// `resolved` pointer unchanged to mean "no rewrite".
typedef CbFilterUrlNative = ffi.Pointer<pkgffi.Utf8> Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>);
typedef CbFilterUrlDart = ffi.Pointer<pkgffi.Utf8> Function(
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf8>,
    ffi.Pointer<pkgffi.Utf8>);

// ---- the C signatures, in the order core/embed.ae declares them ----

typedef _NewC = ffi.Pointer<ffi.Void> Function();
typedef _FreeC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _FreeStringC = ffi.Void Function(ffi.Pointer<pkgffi.Utf8>);
typedef _SanitizeC = ffi.Pointer<pkgffi.Utf8> Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _SetFlagC = ffi.Void Function(ffi.Pointer<ffi.Void>, ffi.Int);
typedef _GetFlagC = ffi.Int Function(ffi.Pointer<ffi.Void>);
typedef _SetItemC = ffi.Int Function(
    ffi.Pointer<ffi.Void>, ffi.Int, ffi.Pointer<pkgffi.Utf8>);
typedef _WhichC = ffi.Int Function(ffi.Pointer<ffi.Void>, ffi.Int);
typedef _ItemAtC = ffi.Pointer<pkgffi.Utf8> Function(
    ffi.Pointer<ffi.Void>, ffi.Int, ffi.Int);
typedef _AbiVersionC = ffi.Int Function();
typedef _OnHookC = ffi.Void Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _NodeIntC = ffi.Int Function(ffi.Pointer<ffi.Void>);
typedef _NodeStrC = ffi.Pointer<pkgffi.Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _NodeAtC = ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Void>, ffi.Int);
typedef _NodePtrC = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _AttrSetValueC = ffi.Void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<pkgffi.Utf8>);

// The Dart-side counterparts.
typedef _New = ffi.Pointer<ffi.Void> Function();
typedef _Free = void Function(ffi.Pointer<ffi.Void>);
typedef _FreeString = void Function(ffi.Pointer<pkgffi.Utf8>);
typedef _Sanitize = ffi.Pointer<pkgffi.Utf8> Function(ffi.Pointer<ffi.Void>,
    ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>);
typedef _SetFlag = void Function(ffi.Pointer<ffi.Void>, int);
typedef _GetFlag = int Function(ffi.Pointer<ffi.Void>);
typedef _SetItem = int Function(
    ffi.Pointer<ffi.Void>, int, ffi.Pointer<pkgffi.Utf8>);
typedef _Which = int Function(ffi.Pointer<ffi.Void>, int);
typedef _ItemAt = ffi.Pointer<pkgffi.Utf8> Function(
    ffi.Pointer<ffi.Void>, int, int);
typedef _AbiVersion = int Function();
typedef _OnHook = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>);
typedef _NodeInt = int Function(ffi.Pointer<ffi.Void>);
typedef _NodeStr = ffi.Pointer<pkgffi.Utf8> Function(ffi.Pointer<ffi.Void>);
typedef _NodeAt = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int);
typedef _NodePtr = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>);
typedef _AttrSetValue = void Function(
    ffi.Pointer<ffi.Void>, ffi.Pointer<pkgffi.Utf8>);

/// The default library file name for this platform.
String get defaultLibraryName {
  if (Platform.isMacOS) return 'libhtmlsanitizer.dylib';
  if (Platform.isWindows) return 'htmlsanitizer.dll';
  return 'libhtmlsanitizer.so';
}

/// Candidate paths, in resolution order:
///
///  1. an explicit path passed to [Api.open]
///  2. `$HTMLSANITIZER_LIB` (what the in-tree `.tests.ae` leaves set)
///  3. `native/` bundled next to this package
///  4. `../core/native/` (the in-tree monorepo layout)
///  5. the OS loader's own search path
Iterable<String> libraryCandidates([String? explicit]) sync* {
  if (explicit != null && explicit.isNotEmpty) {
    yield explicit;
    return;
  }
  final env = Platform.environment['HTMLSANITIZER_LIB'];
  if (env != null && env.isNotEmpty) yield env;

  final name = defaultLibraryName;
  final cwd = Directory.current.path;
  // A bundled copy next to the package, then the in-tree monorepo layout
  // (dart/ and core/ are siblings), from both the cwd and its parent so a
  // `dart test` run from either place resolves.
  yield '$cwd/native/$name';
  yield '$cwd/../core/native/$name';
  yield '$cwd/core/native/$name';
  yield name;
}

/// A loaded engine: the `DynamicLibrary` plus every symbol bound once.
///
/// Binding the symbols eagerly (rather than per call) keeps the hot path free
/// of repeated `lookupFunction` work and turns a missing symbol into a clear
/// load-time failure instead of a mysterious one mid-sanitize.
class Api {
  Api._(this.lib, this.path)
      : hsNew = lib.lookupFunction<_NewC, _New>('aether_hs_embed_new'),
        hsFree = lib.lookupFunction<_FreeC, _Free>('aether_hs_embed_free'),
        freeString = lib.lookupFunction<_FreeStringC, _FreeString>(
            'aether_hs_embed_free_string'),
        sanitize = lib.lookupFunction<_SanitizeC, _Sanitize>(
            'aether_hs_embed_sanitize'),
        sanitizeDocument = lib.lookupFunction<_SanitizeC, _Sanitize>(
            'aether_hs_embed_sanitize_document'),
        setKeepChildNodes = lib.lookupFunction<_SetFlagC, _SetFlag>(
            'aether_hs_embed_set_keep_child_nodes'),
        getKeepChildNodes = lib.lookupFunction<_GetFlagC, _GetFlag>(
            'aether_hs_embed_get_keep_child_nodes'),
        setAllowDataAttributes = lib.lookupFunction<_SetFlagC, _SetFlag>(
            'aether_hs_embed_set_allow_data_attributes'),
        getAllowDataAttributes = lib.lookupFunction<_GetFlagC, _GetFlag>(
            'aether_hs_embed_get_allow_data_attributes'),
        allow =
            lib.lookupFunction<_SetItemC, _SetItem>('aether_hs_embed_allow'),
        disallow = lib
            .lookupFunction<_SetItemC, _SetItem>('aether_hs_embed_disallow'),
        isAllowed = lib
            .lookupFunction<_SetItemC, _SetItem>('aether_hs_embed_is_allowed'),
        clear = lib.lookupFunction<_WhichC, _Which>('aether_hs_embed_clear'),
        count = lib.lookupFunction<_WhichC, _Which>('aether_hs_embed_count'),
        itemAt =
            lib.lookupFunction<_ItemAtC, _ItemAt>('aether_hs_embed_item_at'),
        abiVersion = lib.lookupFunction<_AbiVersionC, _AbiVersion>(
            'aether_hs_embed_abi_version'),
        onRemovingTag = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_removing_tag'),
        onRemovingAttribute = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_removing_attribute'),
        onRemovingStyle = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_removing_style'),
        onRemovingComment = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_removing_comment'),
        onPostProcessNode = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_post_process_node'),
        onPostProcessDom = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_post_process_dom'),
        onFilterUrl = lib.lookupFunction<_OnHookC, _OnHook>(
            'aether_hs_embed_on_filter_url'),
        nodeKind = lib
            .lookupFunction<_NodeIntC, _NodeInt>('aether_hs_embed_node_kind'),
        nodeName = lib
            .lookupFunction<_NodeStrC, _NodeStr>('aether_hs_embed_node_name'),
        nodeValue = lib
            .lookupFunction<_NodeStrC, _NodeStr>('aether_hs_embed_node_value'),
        nodeChildCount = lib.lookupFunction<_NodeIntC, _NodeInt>(
            'aether_hs_embed_node_child_count'),
        nodeChildAt = lib.lookupFunction<_NodeAtC, _NodeAt>(
            'aether_hs_embed_node_child_at'),
        nodeParent = lib.lookupFunction<_NodePtrC, _NodePtr>(
            'aether_hs_embed_node_parent'),
        nodeAttrCount = lib.lookupFunction<_NodeIntC, _NodeInt>(
            'aether_hs_embed_node_attr_count'),
        nodeAttrAt = lib.lookupFunction<_NodeAtC, _NodeAt>(
            'aether_hs_embed_node_attr_at'),
        attrName = lib
            .lookupFunction<_NodeStrC, _NodeStr>('aether_hs_embed_attr_name'),
        attrValue = lib
            .lookupFunction<_NodeStrC, _NodeStr>('aether_hs_embed_attr_value'),
        attrSetValue = lib.lookupFunction<_AttrSetValueC, _AttrSetValue>(
            'aether_hs_embed_attr_set_value');

  final ffi.DynamicLibrary lib;

  /// The path the engine was actually loaded from.
  final String path;

  final _New hsNew;
  final _Free hsFree;
  final _FreeString freeString;
  final _Sanitize sanitize;
  final _Sanitize sanitizeDocument;
  final _SetFlag setKeepChildNodes;
  final _GetFlag getKeepChildNodes;
  final _SetFlag setAllowDataAttributes;
  final _GetFlag getAllowDataAttributes;
  final _SetItem allow;
  final _SetItem disallow;
  final _SetItem isAllowed;
  final _Which clear;
  final _Which count;
  final _ItemAt itemAt;
  final _AbiVersion abiVersion;
  final _OnHook onRemovingTag;
  final _OnHook onRemovingAttribute;
  final _OnHook onRemovingStyle;
  final _OnHook onRemovingComment;
  final _OnHook onPostProcessNode;
  final _OnHook onPostProcessDom;
  final _OnHook onFilterUrl;
  final _NodeInt nodeKind;
  final _NodeStr nodeName;
  final _NodeStr nodeValue;
  final _NodeInt nodeChildCount;
  final _NodeAt nodeChildAt;
  final _NodePtr nodeParent;
  final _NodeInt nodeAttrCount;
  final _NodeAt nodeAttrAt;
  final _NodeStr attrName;
  final _NodeStr attrValue;
  final _AttrSetValue attrSetValue;

  static Api? _cached;

  /// Load the engine, caching it process-wide when no explicit [path] is
  /// given. Throws [StateError] with every candidate tried when it cannot.
  static Api open([String? path]) {
    if (path == null && _cached != null) return _cached!;

    final tried = <String>[];
    Object? last;
    for (final cand in libraryCandidates(path)) {
      tried.add(cand);
      try {
        final api = Api._(ffi.DynamicLibrary.open(cand), cand);
        if (path == null) _cached = api;
        return api;
      } catch (e) {
        last = e;
      }
    }
    throw StateError(
        'could not load the HtmlSanitizer engine ($defaultLibraryName). Set '
        'HTMLSANITIZER_LIB to its absolute path, or build it with:\n'
        '  cd core && ae build --emit=lib embed.ae --extra _embed_support.c '
        '-o native/$defaultLibraryName\n'
        'Tried: ${tried.join(", ")}\nLast error: $last');
  }

  /// Copy an ABI-returned string out and free it through the ABI.
  ///
  /// Every `char*` the engine returns is caller-owned; leaking it is the
  /// single easiest mistake to make in any of these bindings. Every string
  /// result in this package goes through here.
  String takeString(ffi.Pointer<pkgffi.Utf8> p) {
    if (p == ffi.nullptr) return '';
    try {
      return p.toDartString();
    } finally {
      freeString(p);
    }
  }
}

/// Read a borrowed `const char*` argument (a callback parameter) without
/// freeing it — the engine owns those.
String borrowString(ffi.Pointer<pkgffi.Utf8> p) =>
    p == ffi.nullptr ? '' : p.toDartString();
