"""HtmlSanitizer — clean HTML of XSS vectors.

A thin Python binding over one shared native engine (pure Aether), the same
artifact every other language binding in this monorepo uses. Cross-language
behaviour is therefore identical by construction, not by test.

    from htmlsanitizer import HtmlSanitizer

    s = HtmlSanitizer()
    s.sanitize('<div onclick="evil()">hi <script>x</script></div>')
    # '<div>hi </div>'
"""

from ._native import (
    ATTRIBUTES,
    CLASSES,
    CSS_PROPERTIES,
    NODE_COMMENT,
    NODE_DOCUMENT,
    NODE_ELEMENT,
    NODE_TEXT,
    REASON_CLASS_ATTRIBUTE_EMPTY,
    REASON_NOT_ALLOWED_ATTRIBUTE,
    REASON_NOT_ALLOWED_CSS_CLASS,
    REASON_NOT_ALLOWED_STYLE,
    REASON_NOT_ALLOWED_TAG,
    REASON_NOT_ALLOWED_URL_VALUE,
    REASON_NOT_ALLOWED_VALUE,
    REASON_STYLE_ATTRIBUTE_EMPTY,
    SCHEMES,
    TAGS,
    URI_ATTRIBUTES,
)
from ._sanitizer import Attribute, HtmlSanitizer, Node

__version__ = "0.1.0"

__all__ = [
    "HtmlSanitizer", "Node", "Attribute",
    "TAGS", "ATTRIBUTES", "CSS_PROPERTIES", "SCHEMES", "CLASSES",
    "URI_ATTRIBUTES",
    "NODE_DOCUMENT", "NODE_ELEMENT", "NODE_TEXT", "NODE_COMMENT",
    "REASON_NOT_ALLOWED_TAG", "REASON_NOT_ALLOWED_ATTRIBUTE",
    "REASON_NOT_ALLOWED_STYLE", "REASON_NOT_ALLOWED_URL_VALUE",
    "REASON_NOT_ALLOWED_VALUE", "REASON_NOT_ALLOWED_CSS_CLASS",
    "REASON_CLASS_ATTRIBUTE_EMPTY", "REASON_STYLE_ATTRIBUTE_EMPTY",
]
