@file:JvmName("HtmlSanitizerKt")

package org.htmlsanitizer.kotlin

import org.htmlsanitizer.Attribute
import org.htmlsanitizer.HtmlSanitizer
import org.htmlsanitizer.Native
import org.htmlsanitizer.Node

/**
 * Idiomatic Kotlin over the Java binding.
 *
 * There is **no second FFI here**. The one JVM binding to the shared Aether
 * sanitizer core is `java/src/main/java/org/htmlsanitizer` (FFM / Panama); everything
 * in this file is ordinary Kotlin/Java interop on top of those classes. That
 * is deliberate — a Kotlin-specific FFI would be a second copy of the
 * marshalling rules to keep in sync with `core/embed.ae`, and the first thing
 * to drift.
 *
 * What Kotlin adds, and all it adds:
 *
 *  * [htmlSanitizer] — a `use`-friendly builder with a configuration lambda,
 *    so a whole policy reads as one expression.
 *  * `on*` extensions taking **trailing lambdas**, so callbacks look like
 *    language syntax rather than SAM constructions.
 *  * Operator/property sugar on [org.htmlsanitizer.AllowList] — `in`, `+=`,
 *    `-=`, `size` — so an allow-list behaves like a Kotlin collection.
 *  * [RemovalReason] and [NodeKind] enums over the ABI's bare ints.
 *
 * `HtmlSanitizer` is `AutoCloseable`, so Kotlin's `use` already does the right
 * thing:
 *
 * ```kotlin
 * htmlSanitizer {
 *     allowedTags += "my-widget"
 *     keepChildNodes = true
 * }.use { s ->
 *     println(s.sanitize("""<div onclick="evil()">hi</div>"""))
 * }
 * ```
 *
 * Not thread-safe, for the same reason the Java class is not: the sanitizer core calls
 * hooks re-entrantly during `sanitize`.
 */

// ---- construction ----

/**
 * Create a sanitizer and configure it in one expression.
 *
 * The receiver of [configure] is the sanitizer itself, so the extension
 * properties and `on*` builders below are all in scope. If [configure] throws,
 * the half-built sanitizer is closed rather than leaked — it owns a native
 * handle, and letting that escape on an exception path is exactly the leak
 * this wrapper should prevent.
 *
 * @param nativeLibPath an explicit sanitizer core path, or null for the usual
 *   `$HTMLSANITIZER_LIB` / bundled / loader-path search.
 */
fun htmlSanitizer(
    nativeLibPath: String? = null,
    configure: HtmlSanitizer.() -> Unit = {},
): HtmlSanitizer {
    val s = HtmlSanitizer(nativeLibPath)
    try {
        s.configure()
    } catch (t: Throwable) {
        s.close()
        throw t
    }
    return s
}

/**
 * Create a sanitizer, run [block] against it, and close it — the
 * `use`-with-construction shorthand, for when the sanitizer does not outlive
 * one expression.
 */
inline fun <R> sanitizing(
    nativeLibPath: String? = null,
    block: (HtmlSanitizer) -> R,
): R = HtmlSanitizer(nativeLibPath).use(block)

// ---- flags as properties ----
//
// The Java binding spells these as an overloaded getter/setter pair
// (keepChildNodes() / keepChildNodes(b)), which is right for a fluent Java
// API. In Kotlin a `var` is the natural spelling.

/** Keep the children of a removed element instead of dropping the subtree. */
var HtmlSanitizer.keepChildNodes: Boolean
    get() = keepChildNodes()
    set(value) {
        keepChildNodes(value)
    }

/** Allow `data-*` attributes through without listing each one. */
var HtmlSanitizer.allowDataAttributes: Boolean
    get() = allowDataAttributes()
    set(value) {
        allowDataAttributes(value)
    }

// ---- allow-lists as Kotlin collections ----
//
// Read-only aliases so `s.allowedTags += "x"` reads as a property rather than
// a call. The underlying AllowList is a live view on the sanitizer core — these add no
// caching, and must not.

val HtmlSanitizer.allowedTags: org.htmlsanitizer.AllowList get() = allowedTags()
val HtmlSanitizer.allowedAttributes: org.htmlsanitizer.AllowList get() = allowedAttributes()
val HtmlSanitizer.allowedCssProperties: org.htmlsanitizer.AllowList get() = allowedCssProperties()
val HtmlSanitizer.allowedSchemes: org.htmlsanitizer.AllowList get() = allowedSchemes()
val HtmlSanitizer.allowedClasses: org.htmlsanitizer.AllowList get() = allowedClasses()
val HtmlSanitizer.uriAttributes: org.htmlsanitizer.AllowList get() = uriAttributes()

// `"my-widget" in s.allowedTags` already works: AllowList.contains(String) is
// a member and Kotlin's `in` binds straight to it. An extension named
// `contains` would be unreachable (members win) AND would recurse forever if
// it ever were reached, so there deliberately is not one here.

/** `s.allowedTags += "my-widget"` */
operator fun org.htmlsanitizer.AllowList.plusAssign(item: String) {
    add(item)
}

/** `s.allowedTags += listOf("b", "i")` */
operator fun org.htmlsanitizer.AllowList.plusAssign(items: Iterable<String>) {
    items.forEach { add(it) }
}

/** `s.allowedTags -= "script"` — the deny direction. */
operator fun org.htmlsanitizer.AllowList.minusAssign(item: String) {
    remove(item)
}

operator fun org.htmlsanitizer.AllowList.minusAssign(items: Iterable<String>) {
    items.forEach { remove(it) }
}

/**
 * `s.allowedSchemes.count` — the live count straight from the sanitizer core.
 *
 * Named `count`, not `size`: `size` would collide with the `size()` member
 * (unreachable, and self-recursive if it were not), and Kotlin's own
 * `Iterable.count()` would otherwise snapshot the whole list just to measure
 * it. This asks the sanitizer core.
 */
val org.htmlsanitizer.AllowList.count: Int get() = size()

/** Replace the whole list — the "start from nothing" move for a strict policy. */
fun org.htmlsanitizer.AllowList.replaceWith(vararg items: String): org.htmlsanitizer.AllowList =
    clear().addAll(*items)

// ---- callbacks, as trailing lambdas ----
//
// The Java class already accepts a SAM-convertible lambda, so
// `s.onRemovingTag { node, reason -> ... }` works out of the box — with
// `reason` as the ABI's bare Int. These extensions add the enum-typed variant.
//
// They are deliberately NOT named onRemovingTag and friends. In Kotlin a
// MEMBER always wins over an extension of the same name, so an extension
// called `onRemovingTag` would be silently unreachable: every call site would
// bind to the Java method and the enum conversion would never run. The names
// below say what the lambda decides instead, which reads better at the call
// site anyway.
//
// For the removing* family, returning TRUE CANCELS the removal — i.e. KEEPS
// the node. That inversion is the ABI's ("non-zero cancels"), and the `keepX`
// naming is what makes it obvious which way round it goes.

/** Returning true KEEPS the tag. */
inline fun HtmlSanitizer.keepTagIf(
    crossinline predicate: (node: Node, reason: RemovalReason) -> Boolean,
): HtmlSanitizer = onRemovingTag { node, reason -> predicate(node, RemovalReason.of(reason)) }

/** Returning true KEEPS the attribute. */
inline fun HtmlSanitizer.keepAttributeIf(
    crossinline predicate: (element: Node, attribute: Attribute, reason: RemovalReason) -> Boolean,
): HtmlSanitizer = onRemovingAttribute { elem, attr, reason ->
    predicate(elem, attr, RemovalReason.of(reason))
}

/** Returning true KEEPS the CSS property. */
inline fun HtmlSanitizer.keepStyleIf(
    crossinline predicate: (element: Node, name: String, value: String, reason: RemovalReason) -> Boolean,
): HtmlSanitizer = onRemovingStyle { elem, name, value, reason ->
    predicate(elem, name, value, RemovalReason.of(reason))
}

/** Returning true KEEPS the comment. */
inline fun HtmlSanitizer.keepCommentIf(
    crossinline predicate: (node: Node) -> Boolean,
): HtmlSanitizer = onRemovingComment { node -> predicate(node) }

/**
 * Visit every node after processing. Sugar over the Java hook only in that the
 * lambda gets [NodeKind] territory via [nodeKind]; the shape is the same.
 */
inline fun HtmlSanitizer.eachNode(
    crossinline visit: (node: Node) -> Unit,
): HtmlSanitizer = onPostProcessNode { node -> visit(node) }

inline fun HtmlSanitizer.eachDocument(
    crossinline visit: (document: Node) -> Unit,
): HtmlSanitizer = onPostProcessDom { doc -> visit(doc) }

/**
 * Rewrite a URL. Return the URL to use; an **empty string drops** the
 * attribute entirely.
 */
inline fun HtmlSanitizer.rewriteUrls(
    crossinline rewrite: (element: Node, raw: String, resolved: String) -> String,
): HtmlSanitizer = onFilterUrl { elem, raw, resolved -> rewrite(elem, raw, resolved) }

// ---- DOM sugar ----

/** `node.kind` as an enum rather than the ABI's bare int. */
val Node.nodeKind: NodeKind get() = NodeKind.of(kind())

/** Attributes by name, or null — the lookup the raw list makes verbose. */
operator fun Node.get(attributeName: String): Attribute? =
    attributes().firstOrNull { it.name() == attributeName }

/** Depth-first walk from this node, inclusive. */
fun Node.walk(): Sequence<Node> = sequence {
    yield(this@walk)
    children().forEach { yieldAll(it.walk()) }
}

// ---- ABI enums ----

/**
 * Why the sanitizer core is about to remove something.
 *
 * [UNKNOWN] exists so a newer sanitizer core adding a reason cannot make this binding
 * throw — the ABI constants are append-only, and an exhaustive `when` over a
 * closed set would be a latent break.
 */
enum class RemovalReason(val code: Int) {
    NOT_ALLOWED_TAG(Native.REASON_NOT_ALLOWED_TAG),
    NOT_ALLOWED_ATTRIBUTE(Native.REASON_NOT_ALLOWED_ATTRIBUTE),
    NOT_ALLOWED_STYLE(Native.REASON_NOT_ALLOWED_STYLE),
    NOT_ALLOWED_URL_VALUE(Native.REASON_NOT_ALLOWED_URL_VALUE),
    NOT_ALLOWED_VALUE(Native.REASON_NOT_ALLOWED_VALUE),
    NOT_ALLOWED_CSS_CLASS(Native.REASON_NOT_ALLOWED_CSS_CLASS),
    CLASS_ATTRIBUTE_EMPTY(Native.REASON_CLASS_ATTRIBUTE_EMPTY),
    STYLE_ATTRIBUTE_EMPTY(Native.REASON_STYLE_ATTRIBUTE_EMPTY),
    UNKNOWN(-1);

    companion object {
        fun of(code: Int): RemovalReason =
            entries.firstOrNull { it.code == code } ?: UNKNOWN
    }
}

/** 1=Document, 2=Element, 3=Text, 4=Comment. */
enum class NodeKind(val code: Int) {
    DOCUMENT(Native.NODE_DOCUMENT),
    ELEMENT(Native.NODE_ELEMENT),
    TEXT(Native.NODE_TEXT),
    COMMENT(Native.NODE_COMMENT),
    UNKNOWN(-1);

    companion object {
        fun of(code: Int): NodeKind = entries.firstOrNull { it.code == code } ?: UNKNOWN
    }
}
