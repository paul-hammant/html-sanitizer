'use strict';
/**
 * htmlsanitizer — JavaScript binding for the shared HtmlSanitizer engine.
 *
 * The engine (HTML5 tokenizer, DOM, CSS parser, URL resolver, allow-lists) is
 * pure Aether in core/htmlsanitizer.ae and is shared by every language
 * binding in this monorepo. This package is marshalling only.
 *
 *     const { HtmlSanitizer } = require('htmlsanitizer');
 *
 *     const s = new HtmlSanitizer();
 *     console.log(s.sanitize('<div onclick="evil()">hi</div>'));
 *     s.close();
 */

const { HtmlSanitizer, Node, Attribute, AllowList } = require('./lib/sanitizer');
const native = require('./lib/native');

module.exports = {
  HtmlSanitizer,
  Node,
  Attribute,
  AllowList,

  // ---- allow-list selectors ----
  TAGS: native.TAGS,
  ATTRIBUTES: native.ATTRIBUTES,
  CSS_PROPERTIES: native.CSS_PROPERTIES,
  SCHEMES: native.SCHEMES,
  CLASSES: native.CLASSES,
  URI_ATTRIBUTES: native.URI_ATTRIBUTES,

  // ---- node kinds ----
  NODE_DOCUMENT: native.NODE_DOCUMENT,
  NODE_ELEMENT: native.NODE_ELEMENT,
  NODE_TEXT: native.NODE_TEXT,
  NODE_COMMENT: native.NODE_COMMENT,

  // ---- removal reasons ----
  REASON_NOT_ALLOWED_TAG: native.REASON_NOT_ALLOWED_TAG,
  REASON_NOT_ALLOWED_ATTRIBUTE: native.REASON_NOT_ALLOWED_ATTRIBUTE,
  REASON_NOT_ALLOWED_STYLE: native.REASON_NOT_ALLOWED_STYLE,
  REASON_NOT_ALLOWED_URL_VALUE: native.REASON_NOT_ALLOWED_URL_VALUE,
  REASON_NOT_ALLOWED_VALUE: native.REASON_NOT_ALLOWED_VALUE,
  REASON_NOT_ALLOWED_CSS_CLASS: native.REASON_NOT_ALLOWED_CSS_CLASS,
  REASON_CLASS_ATTRIBUTE_EMPTY: native.REASON_CLASS_ATTRIBUTE_EMPTY,
  REASON_STYLE_ATTRIBUTE_EMPTY: native.REASON_STYLE_ATTRIBUTE_EMPTY,
};
