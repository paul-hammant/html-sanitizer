"""ctypes bindings for the HtmlSanitizer core (libhtmlsanitizer.so).

This module is the ONLY place in the Python binding that knows about the C
ABI. Everything above it (`_sanitizer.py`) is idiomatic Python over these
symbols. No sanitizer logic lives here or anywhere else in this package —
the sanitizer core is `core/htmlsanitizer.ae`, shared by every language binding.

Library resolution, in order:
  1. an explicit path passed to `load(path)` / `HtmlSanitizer(native_lib=...)`
  2. $HTMLSANITIZER_LIB          (what the in-tree .tests.ae leaves set)
  3. native/ bundled next to this package (what an installed wheel ships)
  4. the OS loader's own search path
"""

import ctypes
import os
import sys

_LIB_NAME = {
    "darwin": "libhtmlsanitizer.dylib",
    "win32": "htmlsanitizer.dll",
}.get(sys.platform, "libhtmlsanitizer.so")

# ---- allow-list selectors (ABI constants — append only, never renumber) ----
TAGS = 0
ATTRIBUTES = 1
CSS_PROPERTIES = 2
SCHEMES = 3
CLASSES = 4
URI_ATTRIBUTES = 5

# ---- removal reasons, as passed to the callbacks ----
REASON_NOT_ALLOWED_TAG = 0
REASON_NOT_ALLOWED_ATTRIBUTE = 1
REASON_NOT_ALLOWED_STYLE = 2
REASON_NOT_ALLOWED_URL_VALUE = 3
REASON_NOT_ALLOWED_VALUE = 4
REASON_NOT_ALLOWED_CSS_CLASS = 5
REASON_CLASS_ATTRIBUTE_EMPTY = 6
REASON_STYLE_ATTRIBUTE_EMPTY = 7

# ---- node kinds ----
NODE_DOCUMENT = 1
NODE_ELEMENT = 2
NODE_TEXT = 3
NODE_COMMENT = 4

# ---- callback prototypes ----
# Each takes an opaque user_data first; the sanitizer core's trampoline supplies it.
CB_REMOVING_TAG = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int)
CB_REMOVING_ATTRIBUTE = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int)
CB_REMOVING_STYLE = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p,
    ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int)
CB_REMOVING_COMMENT = ctypes.CFUNCTYPE(
    ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
CB_POST_PROCESS = ctypes.CFUNCTYPE(
    None, ctypes.c_void_p, ctypes.c_void_p)
CB_FILTER_URL = ctypes.CFUNCTYPE(
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
    ctypes.c_char_p, ctypes.c_char_p)

_lib = None


def _candidates(explicit=None):
    if explicit:
        yield explicit
        return
    env = os.environ.get("HTMLSANITIZER_LIB")
    if env:
        yield env
    here = os.path.dirname(os.path.abspath(__file__))
    yield os.path.join(here, "native", _LIB_NAME)
    yield _LIB_NAME


def load(path=None):
    """Load the sanitizer core .so, caching it process-wide. Returns the CDLL."""
    global _lib
    if _lib is not None and path is None:
        return _lib

    last = None
    for cand in _candidates(path):
        try:
            lib = ctypes.CDLL(cand)
            break
        except OSError as exc:
            last = exc
    else:
        raise OSError(
            "could not load the HtmlSanitizer core ({}). Set "
            "HTMLSANITIZER_LIB to its absolute path, or install a wheel that "
            "bundles it. Last error: {}".format(_LIB_NAME, last))

    _declare(lib)
    if path is None:
        _lib = lib
    return lib


def _declare(lib):
    """Pin argtypes/restype for every symbol.

    Not optional hygiene: without restype on the pointer-returning calls,
    ctypes truncates them to 32-bit int on 64-bit platforms and the handle
    is silently corrupt.
    """
    P = ctypes.c_void_p
    S = ctypes.c_char_p
    I = ctypes.c_int

    sigs = {
        "aether_hs_embed_new": ([], P),
        "aether_hs_embed_free": ([P], None),
        "aether_hs_embed_free_string": ([P], None),
        "aether_hs_embed_sanitize": ([P, S, S], P),
        "aether_hs_embed_sanitize_document": ([P, S, S], P),
        "aether_hs_embed_set_keep_child_nodes": ([P, I], None),
        "aether_hs_embed_get_keep_child_nodes": ([P], I),
        "aether_hs_embed_set_allow_data_attributes": ([P, I], None),
        "aether_hs_embed_get_allow_data_attributes": ([P], I),
        "aether_hs_embed_allow": ([P, I, S], I),
        "aether_hs_embed_disallow": ([P, I, S], I),
        "aether_hs_embed_is_allowed": ([P, I, S], I),
        "aether_hs_embed_clear": ([P, I], I),
        "aether_hs_embed_count": ([P, I], I),
        "aether_hs_embed_item_at": ([P, I, I], P),
        "aether_hs_embed_abi_version": ([], I),
        "aether_hs_embed_on_removing_tag": ([P, P, P], None),
        "aether_hs_embed_on_removing_attribute": ([P, P, P], None),
        "aether_hs_embed_on_removing_style": ([P, P, P], None),
        "aether_hs_embed_on_removing_comment": ([P, P, P], None),
        "aether_hs_embed_on_post_process_node": ([P, P, P], None),
        "aether_hs_embed_on_post_process_dom": ([P, P, P], None),
        "aether_hs_embed_on_filter_url": ([P, P, P], None),
        "aether_hs_embed_node_kind": ([P], I),
        "aether_hs_embed_node_name": ([P], P),
        "aether_hs_embed_node_value": ([P], P),
        "aether_hs_embed_node_child_count": ([P], I),
        "aether_hs_embed_node_child_at": ([P, I], P),
        "aether_hs_embed_node_parent": ([P], P),
        "aether_hs_embed_node_attr_count": ([P], I),
        "aether_hs_embed_node_attr_at": ([P, I], P),
        "aether_hs_embed_attr_name": ([P], P),
        "aether_hs_embed_attr_value": ([P], P),
        "aether_hs_embed_attr_set_value": ([P, S], None),
    }
    for name, (argtypes, restype) in sigs.items():
        fn = getattr(lib, name)
        fn.argtypes = argtypes
        fn.restype = restype


def take_string(lib, ptr):
    """Copy an ABI-returned string out and free it through the ABI.

    Every char* the sanitizer core returns is caller-owned; leaking it is the single
    easiest mistake to make in any of these bindings.
    """
    if not ptr:
        return ""
    try:
        return ctypes.cast(ptr, ctypes.c_char_p).value.decode("utf-8", "replace")
    finally:
        lib.aether_hs_embed_free_string(ptr)
