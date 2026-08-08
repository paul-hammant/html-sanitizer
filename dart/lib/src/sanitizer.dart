/// The idiomatic Dart surface over the HtmlSanitizer engine.
///
/// Carries no sanitizer logic — every member here marshals to an
/// `aether_hs_embed_*` call in `native.dart`.
library;

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkgffi;

import 'native.dart' as n;

/// Why the engine is about to remove something.
enum Reason {
  notAllowedTag(n.kReasonNotAllowedTag),
  notAllowedAttribute(n.kReasonNotAllowedAttribute),
  notAllowedStyle(n.kReasonNotAllowedStyle),
  notAllowedUrlValue(n.kReasonNotAllowedUrlValue),
  notAllowedValue(n.kReasonNotAllowedValue),
  notAllowedCssClass(n.kReasonNotAllowedCssClass),
  classAttributeEmpty(n.kReasonClassAttributeEmpty),
  styleAttributeEmpty(n.kReasonStyleAttributeEmpty);

  const Reason(this.code);

  /// The ABI integer.
  final int code;

  /// Map an ABI integer back to a [Reason]; unknown codes fall back to
  /// [Reason.notAllowedTag] rather than throwing inside a callback.
  static Reason fromCode(int code) {
    for (final r in Reason.values) {
      if (r.code == code) return r;
    }
    return Reason.notAllowedTag;
  }
}

/// What kind of DOM node this is.
enum NodeKind {
  document(n.kNodeDocument),
  element(n.kNodeElement),
  text(n.kNodeText),
  comment(n.kNodeComment),
  unknown(0);

  const NodeKind(this.code);

  final int code;

  static NodeKind fromCode(int code) {
    for (final k in NodeKind.values) {
      if (k.code == code) return k;
    }
    return NodeKind.unknown;
  }
}

/// A DOM attribute, **borrowed** for the duration of a callback.
///
/// Do not retain one past the callback that gave it to you — the DOM is freed
/// when `sanitize` returns.
class Attribute {
  Attribute(this._api, this._ptr);

  final n.Api _api;
  final ffi.Pointer<ffi.Void> _ptr;

  /// The raw borrowed pointer, for advanced interop.
  ffi.Pointer<ffi.Void> get pointer => _ptr;

  String get name => _api.takeString(_api.attrName(_ptr));

  String get value => _api.takeString(_api.attrValue(_ptr));

  /// Rewrite the attribute's value in place (e.g. to canonicalise a URL
  /// rather than remove the attribute). The engine copies the string, so the
  /// transient buffer allocated here is safe to free immediately.
  set value(String v) {
    final p = v.toNativeUtf8();
    try {
      _api.attrSetValue(_ptr, p);
    } finally {
      pkgffi.calloc.free(p);
    }
  }

  @override
  String toString() => 'Attribute($name=$value)';
}

/// A DOM node, **borrowed** for the duration of a callback.
class Node {
  Node(this._api, this._ptr);

  final n.Api _api;
  final ffi.Pointer<ffi.Void> _ptr;

  /// The raw borrowed pointer, for advanced interop.
  ffi.Pointer<ffi.Void> get pointer => _ptr;

  NodeKind get kind => NodeKind.fromCode(_api.nodeKind(_ptr));

  /// Element tag name, lowercased by the parser; `''` for non-elements.
  String get name => _api.takeString(_api.nodeName(_ptr));

  /// Text/comment content; `''` for elements and documents.
  String get value => _api.takeString(_api.nodeValue(_ptr));

  Node? get parent {
    final p = _api.nodeParent(_ptr);
    return p == ffi.nullptr ? null : Node(_api, p);
  }

  List<Node> get children {
    final c = _api.nodeChildCount(_ptr);
    return [
      for (var i = 0; i < c; i++) Node(_api, _api.nodeChildAt(_ptr, i)),
    ];
  }

  List<Attribute> get attributes {
    final c = _api.nodeAttrCount(_ptr);
    return [
      for (var i = 0; i < c; i++) Attribute(_api, _api.nodeAttrAt(_ptr, i)),
    ];
  }

  @override
  String toString() => 'Node(kind: ${kind.name}, name: $name)';
}

/// A set-like view over one of the engine's six policy lists.
///
/// Every operation reads or writes the engine's own set — there is no Dart
/// mirror to fall out of sync.
class AllowList {
  AllowList(this._owner, this._which);

  final HtmlSanitizer _owner;
  final int _which;

  /// Add one item. Returns this, so calls chain.
  AllowList add(String item) {
    _owner._checkOpen();
    final p = item.toNativeUtf8();
    try {
      _owner._api.allow(_owner._handle, _which, p);
    } finally {
      pkgffi.calloc.free(p);
    }
    return this;
  }

  /// Add every item in [items].
  AllowList addAll(Iterable<String> items) {
    for (final i in items) {
      add(i);
    }
    return this;
  }

  /// Remove one item (the "deny" direction).
  AllowList remove(String item) {
    _owner._checkOpen();
    final p = item.toNativeUtf8();
    try {
      _owner._api.disallow(_owner._handle, _which, p);
    } finally {
      pkgffi.calloc.free(p);
    }
    return this;
  }

  /// Empty the list — the "start from nothing" move for a strict policy.
  AllowList clear() {
    _owner._checkOpen();
    _owner._api.clear(_owner._handle, _which);
    return this;
  }

  bool contains(String item) {
    _owner._checkOpen();
    final p = item.toNativeUtf8();
    try {
      return _owner._api.isAllowed(_owner._handle, _which, p) != 0;
    } finally {
      pkgffi.calloc.free(p);
    }
  }

  int get length {
    _owner._checkOpen();
    return _owner._api.count(_owner._handle, _which);
  }

  bool get isEmpty => length == 0;

  bool get isNotEmpty => length != 0;

  /// The items, in the engine's own (unspecified but stable) order.
  List<String> toList() {
    _owner._checkOpen();
    final api = _owner._api;
    final h = _owner._handle;
    final count = api.count(h, _which);
    return [
      for (var i = 0; i < count; i++)
        api.takeString(api.itemAt(h, _which, i)),
    ];
  }

  /// The items, sorted — the deterministic version of [toList].
  List<String> toSortedList() => toList()..sort();

  @override
  String toString() => '{${toSortedList().join(", ")}}';
}

/// `handler(node, reason)` — return `true` to CANCEL the removal.
typedef RemovingTagHandler = bool Function(Node node, Reason reason);

/// `handler(elem, attr, reason)` — return `true` to CANCEL the removal.
typedef RemovingAttributeHandler = bool Function(
    Node elem, Attribute attr, Reason reason);

/// `handler(elem, name, value, reason)` — return `true` to CANCEL.
typedef RemovingStyleHandler = bool Function(
    Node elem, String name, String value, Reason reason);

/// `handler(node)` — return `true` to CANCEL the removal.
typedef RemovingCommentHandler = bool Function(Node node);

/// `handler(node)`
typedef PostProcessHandler = void Function(Node node);

/// `handler(elem, raw, resolved)` — return the URL to use; `''` drops the
/// attribute.
typedef FilterUrlHandler = String Function(
    Node elem, String raw, String resolved);

/// Cleans HTML of constructs that can lead to Cross-Site Scripting (XSS).
///
/// ```dart
/// final s = HtmlSanitizer();
/// s.allowedTags.add('my-widget');
/// final clean = s.sanitize('<div onclick="evil()">hi</div>');
/// s.close();
/// ```
///
/// Call [close] (or use [use]) to release the native handle. A sanitizer is
/// **not** safe for concurrent use — the native handle carries mutable policy
/// and hook state.
class HtmlSanitizer {
  /// Create a sanitizer with the engine's secure defaults populated.
  ///
  /// [nativeLibrary] overrides the library search; see
  /// `native.dart`'s resolution order.
  HtmlSanitizer({String? nativeLibrary}) : _api = n.Api.open(nativeLibrary) {
    _handle = _api.hsNew();
    if (_handle == ffi.nullptr) {
      throw StateError('failed to create the native sanitizer');
    }
    allowedTags = AllowList(this, n.kTags);
    allowedAttributes = AllowList(this, n.kAttributes);
    allowedCssProperties = AllowList(this, n.kCssProperties);
    allowedSchemes = AllowList(this, n.kSchemes);
    allowedClasses = AllowList(this, n.kClasses);
    uriAttributes = AllowList(this, n.kUriAttributes);
  }

  final n.Api _api;
  late final ffi.Pointer<ffi.Void> _handle;

  /// Every live `NativeCallable`. Dart's FFI callbacks must be kept alive and
  /// explicitly closed — dropping the reference leaks the trampoline, and
  /// closing it while the engine can still call it crashes the process. The
  /// engine can call a hook until it is replaced or the handle is freed, so
  /// these are closed only in [close] (and, for a replaced hook, once the
  /// engine has been told to forget it).
  final List<ffi.NativeCallable> _keepalive = [];

  bool _closed = false;

  /// The engine's allowed tag names.
  late final AllowList allowedTags;

  /// The engine's allowed attribute names.
  late final AllowList allowedAttributes;

  /// The engine's allowed CSS property names.
  late final AllowList allowedCssProperties;

  /// The engine's allowed URL schemes.
  late final AllowList allowedSchemes;

  /// The engine's allowed CSS class names.
  late final AllowList allowedClasses;

  /// Which attributes the engine treats as carrying a URL.
  late final AllowList uriAttributes;

  /// The path the engine `.so` was loaded from.
  String get nativeLibraryPath => _api.path;

  void _checkOpen() {
    if (_closed) throw StateError('sanitizer is closed');
  }

  /// Release the native handle and every callback trampoline. Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _api.hsFree(_handle);
    // Only now is it certain the engine can no longer invoke a hook.
    for (final cb in _keepalive) {
      cb.close();
    }
    _keepalive.clear();
  }

  /// Run [body] with this sanitizer, closing it afterwards.
  static T use<T>(T Function(HtmlSanitizer s) body, {String? nativeLibrary}) {
    final s = HtmlSanitizer(nativeLibrary: nativeLibrary);
    try {
      return body(s);
    } finally {
      s.close();
    }
  }

  // ---- the main entry point ----

  /// Sanitize an HTML fragment. [baseUrl] resolves relative URLs; pass `''`
  /// for no resolution.
  String sanitize(String html, [String baseUrl = '']) =>
      _sanitizeWith(_api.sanitize, html, baseUrl);

  /// Sanitize a full HTML document.
  String sanitizeDocument(String html, [String baseUrl = '']) =>
      _sanitizeWith(_api.sanitizeDocument, html, baseUrl);

  String _sanitizeWith(
      ffi.Pointer<pkgffi.Utf8> Function(ffi.Pointer<ffi.Void>,
              ffi.Pointer<pkgffi.Utf8>, ffi.Pointer<pkgffi.Utf8>)
          fn,
      String html,
      String baseUrl) {
    _checkOpen();
    final h = html.toNativeUtf8();
    final b = baseUrl.toNativeUtf8();
    try {
      return _api.takeString(fn(_handle, h, b));
    } finally {
      pkgffi.calloc.free(h);
      pkgffi.calloc.free(b);
    }
  }

  // ---- flags ----

  /// Keep the children of a removed element instead of dropping the subtree.
  bool get keepChildNodes {
    _checkOpen();
    return _api.getKeepChildNodes(_handle) != 0;
  }

  set keepChildNodes(bool on) {
    _checkOpen();
    _api.setKeepChildNodes(_handle, on ? 1 : 0);
  }

  /// Allow `data-*` attributes through without listing each one.
  bool get allowDataAttributes {
    _checkOpen();
    return _api.getAllowDataAttributes(_handle) != 0;
  }

  set allowDataAttributes(bool on) {
    _checkOpen();
    _api.setAllowDataAttributes(_handle, on ? 1 : 0);
  }

  /// The engine's ABI revision.
  int get abiVersion => _api.abiVersion();

  // ---- callbacks ----
  //
  // Each `on*` takes a handler (or null to clear the hook) and returns this,
  // so they chain. For the `removing*` family, returning true from your
  // handler CANCELS the removal (keeps the node/attribute/property).

  void _register(
      void Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Void>,
              ffi.Pointer<ffi.Void>)
          hook,
      ffi.NativeCallable? cb) {
    _checkOpen();
    if (cb == null) {
      hook(_handle, ffi.nullptr, ffi.nullptr);
      return;
    }
    _keepalive.add(cb);
    // `user_data` is unused on the Dart side: an isolate-local
    // NativeCallable already closes over the handler, so there is nothing to
    // look up. It is still round-tripped by the engine's trampoline.
    hook(_handle, cb.nativeFunction.cast<ffi.Void>(), ffi.nullptr);
  }

  /// Called before a disallowed tag is removed. Return `true` to keep it.
  HtmlSanitizer onRemovingTag(RemovingTagHandler? handler) {
    if (handler == null) {
      _register(_api.onRemovingTag, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbRemovingTagNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud, ffi.Pointer<ffi.Void> node, int reason) =>
          handler(Node(_api, node), Reason.fromCode(reason)) ? 1 : 0,
      exceptionalReturn: 0,
    );
    _register(_api.onRemovingTag, cb);
    return this;
  }

  /// Called before a disallowed attribute is removed. Return `true` to keep.
  HtmlSanitizer onRemovingAttribute(RemovingAttributeHandler? handler) {
    if (handler == null) {
      _register(_api.onRemovingAttribute, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbRemovingAttributeNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud, ffi.Pointer<ffi.Void> elem,
              ffi.Pointer<ffi.Void> attr, int reason) =>
          handler(Node(_api, elem), Attribute(_api, attr),
                  Reason.fromCode(reason))
              ? 1
              : 0,
      exceptionalReturn: 0,
    );
    _register(_api.onRemovingAttribute, cb);
    return this;
  }

  /// Called before a disallowed CSS property is removed. Return `true` to
  /// keep it.
  HtmlSanitizer onRemovingStyle(RemovingStyleHandler? handler) {
    if (handler == null) {
      _register(_api.onRemovingStyle, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbRemovingStyleNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud,
              ffi.Pointer<ffi.Void> elem,
              ffi.Pointer<pkgffi.Utf8> name,
              ffi.Pointer<pkgffi.Utf8> value,
              int reason) =>
          handler(Node(_api, elem), n.borrowString(name),
                  n.borrowString(value), Reason.fromCode(reason))
              ? 1
              : 0,
      exceptionalReturn: 0,
    );
    _register(_api.onRemovingStyle, cb);
    return this;
  }

  /// Called before a comment is removed. Return `true` to keep it.
  HtmlSanitizer onRemovingComment(RemovingCommentHandler? handler) {
    if (handler == null) {
      _register(_api.onRemovingComment, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbRemovingCommentNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud, ffi.Pointer<ffi.Void> node) =>
          handler(Node(_api, node)) ? 1 : 0,
      exceptionalReturn: 0,
    );
    _register(_api.onRemovingComment, cb);
    return this;
  }

  /// Called for each node after it has been filtered.
  HtmlSanitizer onPostProcessNode(PostProcessHandler? handler) {
    if (handler == null) {
      _register(_api.onPostProcessNode, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbPostProcessNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud, ffi.Pointer<ffi.Void> node) =>
          handler(Node(_api, node)),
    );
    _register(_api.onPostProcessNode, cb);
    return this;
  }

  /// Called once with the whole document after filtering.
  HtmlSanitizer onPostProcessDom(PostProcessHandler? handler) {
    if (handler == null) {
      _register(_api.onPostProcessDom, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbPostProcessNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud, ffi.Pointer<ffi.Void> doc) =>
          handler(Node(_api, doc)),
    );
    _register(_api.onPostProcessDom, cb);
    return this;
  }

  /// Called for each URL-bearing attribute. Return the URL to use — the
  /// `resolved` argument unchanged for no rewrite, or `''` to drop the
  /// attribute.
  ///
  /// The returned string is copied into a malloc'd C buffer the engine takes
  /// ownership of; you do not free it.
  HtmlSanitizer onFilterUrl(FilterUrlHandler? handler) {
    if (handler == null) {
      _register(_api.onFilterUrl, null);
      return this;
    }
    final cb = ffi.NativeCallable<n.CbFilterUrlNative>.isolateLocal(
      (ffi.Pointer<ffi.Void> ud, ffi.Pointer<ffi.Void> elem,
          ffi.Pointer<pkgffi.Utf8> raw, ffi.Pointer<pkgffi.Utf8> resolved) {
        final out = handler(
            Node(_api, elem), n.borrowString(raw), n.borrowString(resolved));
        // The engine frees this; allocate with malloc, not Dart's arena.
        return out.toNativeUtf8(allocator: pkgffi.malloc);
      },
      // No `exceptionalReturn` here: Dart forbids one for a pointer-returning
      // native callback (it defaults to nullptr). A handler that throws
      // therefore hands the engine a null URL, so keep handlers total.
    );
    _register(_api.onFilterUrl, cb);
    return this;
  }
}

/// One-shot: sanitize [html] with the engine's defaults.
String sanitize(String html, [String baseUrl = '']) =>
    HtmlSanitizer.use((s) => s.sanitize(html, baseUrl));

/// One-shot: sanitize [html] as a full document, with the engine's defaults.
String sanitizeDocument(String html, [String baseUrl = '']) =>
    HtmlSanitizer.use((s) => s.sanitizeDocument(html, baseUrl));
