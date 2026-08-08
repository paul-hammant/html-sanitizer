"""Idiomatic Python surface over the HtmlSanitizer engine.

Carries no sanitizer logic — see the monorepo's one rule in LLM.md. Every
method here marshals to a `aether_hs_embed_*` call in `_native.py`.
"""

import ctypes

from . import _native
from ._native import (
    TAGS, ATTRIBUTES, CSS_PROPERTIES, SCHEMES, CLASSES, URI_ATTRIBUTES,
    NODE_DOCUMENT, NODE_ELEMENT, NODE_TEXT, NODE_COMMENT,
    REASON_NOT_ALLOWED_TAG, REASON_NOT_ALLOWED_ATTRIBUTE,
    REASON_NOT_ALLOWED_STYLE, REASON_NOT_ALLOWED_URL_VALUE,
    REASON_NOT_ALLOWED_VALUE, REASON_NOT_ALLOWED_CSS_CLASS,
    REASON_CLASS_ATTRIBUTE_EMPTY, REASON_STYLE_ATTRIBUTE_EMPTY,
)


def _enc(s):
    return (s or "").encode("utf-8")


class Attribute:
    """A DOM attribute, borrowed for the duration of a callback.

    Do not retain one past the callback that gave it to you — the DOM is
    freed when sanitize() returns.
    """

    __slots__ = ("_lib", "_ptr")

    def __init__(self, lib, ptr):
        self._lib = lib
        self._ptr = ptr

    @property
    def name(self):
        return _native.take_string(self._lib, self._lib.aether_hs_embed_attr_name(self._ptr))

    @property
    def value(self):
        return _native.take_string(self._lib, self._lib.aether_hs_embed_attr_value(self._ptr))

    @value.setter
    def value(self, v):
        self._lib.aether_hs_embed_attr_set_value(self._ptr, _enc(v))

    def __repr__(self):
        return "Attribute({!r}={!r})".format(self.name, self.value)


class Node:
    """A DOM node, borrowed for the duration of a callback."""

    __slots__ = ("_lib", "_ptr")

    def __init__(self, lib, ptr):
        self._lib = lib
        self._ptr = ptr

    @property
    def kind(self):
        return self._lib.aether_hs_embed_node_kind(self._ptr)

    @property
    def name(self):
        return _native.take_string(self._lib, self._lib.aether_hs_embed_node_name(self._ptr))

    @property
    def value(self):
        return _native.take_string(self._lib, self._lib.aether_hs_embed_node_value(self._ptr))

    @property
    def parent(self):
        p = self._lib.aether_hs_embed_node_parent(self._ptr)
        return Node(self._lib, p) if p else None

    @property
    def children(self):
        n = self._lib.aether_hs_embed_node_child_count(self._ptr)
        return [Node(self._lib, self._lib.aether_hs_embed_node_child_at(self._ptr, i))
                for i in range(n)]

    @property
    def attributes(self):
        n = self._lib.aether_hs_embed_node_attr_count(self._ptr)
        return [Attribute(self._lib, self._lib.aether_hs_embed_node_attr_at(self._ptr, i))
                for i in range(n)]

    def __repr__(self):
        return "Node(kind={}, name={!r})".format(self.kind, self.name)


class _AllowList:
    """Set-like view over one of the engine's six policy lists."""

    __slots__ = ("_owner", "_which")

    def __init__(self, owner, which):
        self._owner = owner
        self._which = which

    def add(self, item):
        self._owner._lib.aether_hs_embed_allow(self._owner._h, self._which, _enc(item))
        return self

    def update(self, items):
        for i in items:
            self.add(i)
        return self

    def discard(self, item):
        self._owner._lib.aether_hs_embed_disallow(self._owner._h, self._which, _enc(item))
        return self

    def clear(self):
        self._owner._lib.aether_hs_embed_clear(self._owner._h, self._which)
        return self

    def __contains__(self, item):
        return bool(self._owner._lib.aether_hs_embed_is_allowed(
            self._owner._h, self._which, _enc(item)))

    def __len__(self):
        return self._owner._lib.aether_hs_embed_count(self._owner._h, self._which)

    def __iter__(self):
        lib, h = self._owner._lib, self._owner._h
        for i in range(len(self)):
            yield _native.take_string(lib, lib.aether_hs_embed_item_at(h, self._which, i))

    def __repr__(self):
        return "{" + ", ".join(repr(x) for x in sorted(self)) + "}"


class HtmlSanitizer:
    """Cleans HTML of constructs that can lead to XSS.

        s = HtmlSanitizer()
        s.allowed_tags.add("my-widget")
        clean = s.sanitize('<div onclick="evil()">hi</div>')

    Usable as a context manager; otherwise call close() (or let refcounting
    do it) to release the native handle.
    """

    def __init__(self, native_lib=None):
        self._lib = _native.load(native_lib)
        self._h = self._lib.aether_hs_embed_new()
        if not self._h:
            raise RuntimeError("failed to create the native sanitizer")
        # ctypes callbacks must be kept alive for as long as the engine can
        # call them — a local trampoline would be GC'd and crash the process.
        self._keepalive = []

        self.allowed_tags = _AllowList(self, TAGS)
        self.allowed_attributes = _AllowList(self, ATTRIBUTES)
        self.allowed_css_properties = _AllowList(self, CSS_PROPERTIES)
        self.allowed_schemes = _AllowList(self, SCHEMES)
        self.allowed_classes = _AllowList(self, CLASSES)
        self.uri_attributes = _AllowList(self, URI_ATTRIBUTES)

    # ---- lifecycle ----

    def close(self):
        if getattr(self, "_h", None):
            self._lib.aether_hs_embed_free(self._h)
            self._h = None
            self._keepalive = []

    __del__ = close

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def _check(self):
        if not self._h:
            raise ValueError("sanitizer is closed")

    # ---- the main entry point ----

    def sanitize(self, html, base_url=""):
        self._check()
        return _native.take_string(
            self._lib,
            self._lib.aether_hs_embed_sanitize(self._h, _enc(html), _enc(base_url)))

    def sanitize_document(self, html, base_url=""):
        self._check()
        return _native.take_string(
            self._lib,
            self._lib.aether_hs_embed_sanitize_document(self._h, _enc(html), _enc(base_url)))

    # ---- flags ----

    @property
    def keep_child_nodes(self):
        return bool(self._lib.aether_hs_embed_get_keep_child_nodes(self._h))

    @keep_child_nodes.setter
    def keep_child_nodes(self, on):
        self._lib.aether_hs_embed_set_keep_child_nodes(self._h, 1 if on else 0)

    @property
    def allow_data_attributes(self):
        return bool(self._lib.aether_hs_embed_get_allow_data_attributes(self._h))

    @allow_data_attributes.setter
    def allow_data_attributes(self, on):
        self._lib.aether_hs_embed_set_allow_data_attributes(self._h, 1 if on else 0)

    @property
    def abi_version(self):
        return self._lib.aether_hs_embed_abi_version()

    # ---- callbacks ----
    #
    # Each `on_*` takes a Python callable and returns self, so they chain.
    # Passing None clears the hook. For the `removing_*` family, returning
    # True from your handler CANCELS the removal (keeps the node); returning
    # False/None lets it proceed.

    def _install(self, register, factory, handler):
        self._check()
        if handler is None:
            register(self._h, None, None)
            return self
        trampoline = factory(handler)
        self._keepalive.append(trampoline)
        register(self._h, ctypes.cast(trampoline, ctypes.c_void_p), None)
        return self

    def on_removing_tag(self, handler):
        def factory(fn):
            def impl(_ud, node, reason):
                return 1 if fn(Node(self._lib, node), reason) else 0
            return _native.CB_REMOVING_TAG(impl)
        return self._install(self._lib.aether_hs_embed_on_removing_tag, factory, handler)

    def on_removing_attribute(self, handler):
        def factory(fn):
            def impl(_ud, elem, attr, reason):
                return 1 if fn(Node(self._lib, elem), Attribute(self._lib, attr), reason) else 0
            return _native.CB_REMOVING_ATTRIBUTE(impl)
        return self._install(self._lib.aether_hs_embed_on_removing_attribute, factory, handler)

    def on_removing_style(self, handler):
        def factory(fn):
            def impl(_ud, elem, name, value, reason):
                return 1 if fn(Node(self._lib, elem),
                               (name or b"").decode("utf-8", "replace"),
                               (value or b"").decode("utf-8", "replace"),
                               reason) else 0
            return _native.CB_REMOVING_STYLE(impl)
        return self._install(self._lib.aether_hs_embed_on_removing_style, factory, handler)

    def on_removing_comment(self, handler):
        def factory(fn):
            def impl(_ud, node):
                return 1 if fn(Node(self._lib, node)) else 0
            return _native.CB_REMOVING_COMMENT(impl)
        return self._install(self._lib.aether_hs_embed_on_removing_comment, factory, handler)

    def on_post_process_node(self, handler):
        def factory(fn):
            def impl(_ud, node):
                fn(Node(self._lib, node))
            return _native.CB_POST_PROCESS(impl)
        return self._install(self._lib.aether_hs_embed_on_post_process_node, factory, handler)

    def on_post_process_dom(self, handler):
        def factory(fn):
            def impl(_ud, doc):
                fn(Node(self._lib, doc))
            return _native.CB_POST_PROCESS(impl)
        return self._install(self._lib.aether_hs_embed_on_post_process_dom, factory, handler)

    def on_filter_url(self, handler):
        """handler(node, raw_url, resolved_url) -> str

        Return the URL to use ("" drops the attribute). The returned string is
        copied into a C buffer the engine takes ownership of.
        """
        import ctypes.util  # noqa: F401  (keep libc lookup local to this path)
        libc = ctypes.CDLL(None)
        libc.strdup.argtypes = [ctypes.c_char_p]
        libc.strdup.restype = ctypes.c_void_p

        def factory(fn):
            def impl(_ud, elem, raw, resolved):
                out = fn(Node(self._lib, elem),
                         (raw or b"").decode("utf-8", "replace"),
                         (resolved or b"").decode("utf-8", "replace"))
                return libc.strdup(_enc(out))
            return _native.CB_FILTER_URL(impl)
        return self._install(self._lib.aether_hs_embed_on_filter_url, factory, handler)
