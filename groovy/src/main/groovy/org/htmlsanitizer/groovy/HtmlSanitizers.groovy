package org.htmlsanitizer.groovy

import groovy.transform.CompileStatic
import org.htmlsanitizer.Attribute
import org.htmlsanitizer.HtmlSanitizer
import org.htmlsanitizer.Native
import org.htmlsanitizer.Node

/**
 * Idiomatic Groovy over the Java binding — a Closure-based DSL.
 *
 * There is <b>no second FFI here</b>. The one JVM binding to the shared Aether
 * sanitizer core is {@code java/src/main/java/org/htmlsanitizer} (FFM / Panama), and
 * everything in this file is ordinary Groovy/Java interop on top of those
 * classes. A Groovy-specific FFI would be a second copy of the ABI's
 * marshalling and ownership rules to keep in step with {@code core/embed.ae},
 * and the first thing to drift.
 *
 * The entry point is {@link #htmlSanitizer(Closure)}, which runs a
 * configuration closure against a {@link SanitizerSpec} — so a whole policy
 * reads as a block:
 *
 * <pre>{@code
 * def clean = HtmlSanitizers.sanitizing { spec ->
 *     spec.allowTags 'my-widget'
 *     spec.keepChildNodes = true
 *     spec.keepTagIf { node, reason -> node.name() == 'keep-me' }
 * } .sanitize('<div onclick="evil()">hi</div>')
 * }</pre>
 *
 * Not thread-safe, for the same reason the Java class is not: the sanitizer core calls
 * hooks re-entrantly during {@code sanitize}.
 */
@CompileStatic
class HtmlSanitizers {

    private HtmlSanitizers() {
    }

    /**
     * Create a sanitizer and configure it with a closure.
     *
     * <p>The closure's delegate is a {@link SanitizerSpec}, with
     * {@code DELEGATE_FIRST} resolution, so the DSL verbs below can be written
     * bare inside the block. If the closure throws, the half-built sanitizer is
     * closed rather than leaked — it owns a native handle, and letting that
     * escape on an exception path is exactly what this wrapper should prevent.
     *
     * <p>The caller owns the result and must {@code close()} it; use
     * {@link #sanitizing} or {@code withCloseable} to have that done for you.
     *
     * @param nativeLibPath an explicit sanitizer core path, or null for the usual
     *        {@code $HTMLSANITIZER_LIB} / bundled / loader-path search
     */
    static HtmlSanitizer htmlSanitizer(String nativeLibPath = null,
                                       @DelegatesTo(value = SanitizerSpec,
                                                    strategy = Closure.DELEGATE_FIRST)
                                       Closure configure = null) {
        HtmlSanitizer s = new HtmlSanitizer(nativeLibPath)
        try {
            if (configure != null) {
                SanitizerSpec spec = new SanitizerSpec(s)
                Closure c = (Closure) configure.clone()
                c.delegate = spec
                c.resolveStrategy = Closure.DELEGATE_FIRST
                if (c.maximumNumberOfParameters == 0) {
                    c.call()
                } else {
                    c.call(spec)
                }
            }
        } catch (Throwable t) {
            s.close()
            throw t
        }
        return s
    }

    /** Configure-only overload, so the common call needs no null first arg. */
    static HtmlSanitizer htmlSanitizer(@DelegatesTo(value = SanitizerSpec,
                                                    strategy = Closure.DELEGATE_FIRST)
                                       Closure configure) {
        return htmlSanitizer((String) null, configure)
    }

    /**
     * Create a sanitizer, hand it to {@code body}, and close it — the
     * construct-use-close shorthand for when the sanitizer does not outlive one
     * expression.
     */
    static <T> T sanitizing(String nativeLibPath = null,
                            @DelegatesTo(value = SanitizerSpec,
                                         strategy = Closure.DELEGATE_FIRST)
                            Closure configure = null,
                            Closure<T> body) {
        HtmlSanitizer s = htmlSanitizer(nativeLibPath, configure)
        try {
            return body.call(s)
        } finally {
            s.close()
        }
    }

    /** Sanitize one fragment with the secure defaults and close immediately. */
    static String sanitize(String html, String baseUrl = '') {
        HtmlSanitizer s = new HtmlSanitizer()
        try {
            return s.sanitize(html, baseUrl)
        } finally {
            s.close()
        }
    }
}

/**
 * The delegate of a {@link HtmlSanitizers#htmlSanitizer} configuration
 * closure — the DSL surface.
 *
 * <p>Every verb mutates the live sanitizer core through the Java binding; nothing is
 * buffered here, so ordering inside the block is the ordering the sanitizer core sees.
 */
@CompileStatic
class SanitizerSpec {

    /** The sanitizer being configured; reachable if you need the Java API. */
    final HtmlSanitizer sanitizer

    SanitizerSpec(HtmlSanitizer sanitizer) {
        this.sanitizer = sanitizer
    }

    // ---- flags, as Groovy properties ----

    boolean getKeepChildNodes() { sanitizer.keepChildNodes() }

    void setKeepChildNodes(boolean on) { sanitizer.keepChildNodes(on) }

    boolean getAllowDataAttributes() { sanitizer.allowDataAttributes() }

    void setAllowDataAttributes(boolean on) { sanitizer.allowDataAttributes(on) }

    // ---- allow-lists ----
    //
    // Named verbs rather than raw list access, because "allowTags 'x', 'y'"
    // is the thing a policy actually wants to say.

    SanitizerSpec allowTags(String... items) { sanitizer.allowedTags().addAll(items); this }

    // Typed for-loops rather than `items.each { ... remove(it) }`: under
    // @CompileStatic the closure parameter of `each` infers as Object on some
    // Groovy versions, and AllowList.remove takes a String — so the `each`
    // form compiles on one Groovy and fails on another. An explicit loop is
    // version-independent.
    SanitizerSpec denyTags(String... items) {
        for (String item : items) {
            sanitizer.allowedTags().remove(item)
        }
        this
    }

    SanitizerSpec allowAttributes(String... items) {
        sanitizer.allowedAttributes().addAll(items); this
    }

    SanitizerSpec denyAttributes(String... items) {
        for (String item : items) {
            sanitizer.allowedAttributes().remove(item)
        }
        this
    }

    SanitizerSpec allowCssProperties(String... items) {
        sanitizer.allowedCssProperties().addAll(items); this
    }

    SanitizerSpec allowSchemes(String... items) {
        sanitizer.allowedSchemes().addAll(items); this
    }

    SanitizerSpec allowClasses(String... items) {
        sanitizer.allowedClasses().addAll(items); this
    }

    SanitizerSpec uriAttributes(String... items) {
        sanitizer.uriAttributes().addAll(items); this
    }

    /** The six live views, for anything the verbs above do not cover. */
    org.htmlsanitizer.AllowList getAllowedTags() { sanitizer.allowedTags() }

    org.htmlsanitizer.AllowList getAllowedAttributes() { sanitizer.allowedAttributes() }

    org.htmlsanitizer.AllowList getAllowedCssProperties() { sanitizer.allowedCssProperties() }

    org.htmlsanitizer.AllowList getAllowedSchemes() { sanitizer.allowedSchemes() }

    org.htmlsanitizer.AllowList getAllowedClasses() { sanitizer.allowedClasses() }

    org.htmlsanitizer.AllowList getUriAttributes() { sanitizer.uriAttributes() }

    // ---- callbacks, as closures ----
    //
    // For the removing* family the ABI's rule is "non-zero CANCELS the
    // removal". These verbs are named keep*If so the sense of the returned
    // boolean is unmissable: true KEEPS the thing.
    //
    // Groovy truth is deliberately applied to the closure result (asBoolean),
    // so returning null from a branch means "do not keep" rather than blowing
    // up on an unboxing NPE.

    SanitizerSpec keepTagIf(Closure<?> predicate) {
        sanitizer.onRemovingTag({ Node node, int reason ->
            truth(predicate.maximumNumberOfParameters >= 2
                    ? predicate.call(node, reason)
                    : predicate.call(node))
        } as HtmlSanitizer.RemovingTagHandler)
        this
    }

    SanitizerSpec keepAttributeIf(Closure<?> predicate) {
        sanitizer.onRemovingAttribute({ Node elem, Attribute attr, int reason ->
            truth(predicate.maximumNumberOfParameters >= 3
                    ? predicate.call(elem, attr, reason)
                    : predicate.call(elem, attr))
        } as HtmlSanitizer.RemovingAttributeHandler)
        this
    }

    SanitizerSpec keepStyleIf(Closure<?> predicate) {
        sanitizer.onRemovingStyle({ Node elem, String name, String value, int reason ->
            truth(predicate.maximumNumberOfParameters >= 4
                    ? predicate.call(elem, name, value, reason)
                    : predicate.call(elem, name, value))
        } as HtmlSanitizer.RemovingStyleHandler)
        this
    }

    SanitizerSpec keepCommentIf(Closure<?> predicate) {
        sanitizer.onRemovingComment({ Node node ->
            truth(predicate.call(node))
        } as HtmlSanitizer.RemovingCommentHandler)
        this
    }

    SanitizerSpec eachNode(Closure<?> visit) {
        sanitizer.onPostProcessNode({ Node node ->
            visit.call(node)
        } as HtmlSanitizer.PostProcessHandler)
        this
    }

    SanitizerSpec eachDocument(Closure<?> visit) {
        sanitizer.onPostProcessDom({ Node doc ->
            visit.call(doc)
        } as HtmlSanitizer.PostProcessHandler)
        this
    }

    /**
     * Rewrite a URL. Return the URL to use; an <b>empty string drops</b> the
     * attribute entirely. Returning null is treated as "no rewrite" — the
     * resolved URL is used — rather than as an empty string, since a closure
     * falling off the end should not silently strip every URL.
     */
    SanitizerSpec rewriteUrls(Closure<?> rewrite) {
        sanitizer.onFilterUrl({ Node elem, String raw, String resolved ->
            Object out = rewrite.maximumNumberOfParameters >= 3
                    ? rewrite.call(elem, raw, resolved)
                    : (rewrite.maximumNumberOfParameters == 2
                        ? rewrite.call(raw, resolved)
                        : rewrite.call(resolved))
            out == null ? resolved : out.toString()
        } as HtmlSanitizer.FilterUrlHandler)
        this
    }

    /**
     * Groovy truth for a closure's result, so a null return means "false"
     * rather than an unboxing NPE.
     *
     * <p>Do NOT reach for {@code DefaultGroovyMethods.asBoolean(Object)} here.
     * That overload answers "is this a non-null object?" and so returns TRUE
     * for {@code Boolean.FALSE} — the boolean-specific overload only applies
     * when the argument's STATIC type is {@code boolean}, which it is not once
     * a closure result has been boxed into an Object. Using it silently
     * inverted every "do not keep" answer: {@code keepTagIf { ... false }}
     * cancelled the removal and kept the tag, which is a security-relevant
     * failure in a sanitizer, not a cosmetic one.
     *
     * <p>{@code DefaultTypeTransformation.castToBoolean} is the function that
     * actually implements Groovy truth for an arbitrary object.
     */
    private static boolean truth(Object o) {
        o != null && org.codehaus.groovy.runtime.typehandling.DefaultTypeTransformation.castToBoolean(o)
    }
}

/**
 * ABI constants, as Groovy-friendly names.
 *
 * <p>Kept as plain ints matching {@link Native}: the ABI's constants are
 * append-only, and an enum with an exhaustive switch would be a latent break
 * when the sanitizer core adds one.
 */
@CompileStatic
class Reasons {
    static final int NOT_ALLOWED_TAG = Native.REASON_NOT_ALLOWED_TAG
    static final int NOT_ALLOWED_ATTRIBUTE = Native.REASON_NOT_ALLOWED_ATTRIBUTE
    static final int NOT_ALLOWED_STYLE = Native.REASON_NOT_ALLOWED_STYLE
    static final int NOT_ALLOWED_URL_VALUE = Native.REASON_NOT_ALLOWED_URL_VALUE
    static final int NOT_ALLOWED_VALUE = Native.REASON_NOT_ALLOWED_VALUE
    static final int NOT_ALLOWED_CSS_CLASS = Native.REASON_NOT_ALLOWED_CSS_CLASS
    static final int CLASS_ATTRIBUTE_EMPTY = Native.REASON_CLASS_ATTRIBUTE_EMPTY
    static final int STYLE_ATTRIBUTE_EMPTY = Native.REASON_STYLE_ATTRIBUTE_EMPTY

    private Reasons() {
    }
}

/** 1=Document, 2=Element, 3=Text, 4=Comment. */
@CompileStatic
class NodeKinds {
    static final int DOCUMENT = Native.NODE_DOCUMENT
    static final int ELEMENT = Native.NODE_ELEMENT
    static final int TEXT = Native.NODE_TEXT
    static final int COMMENT = Native.NODE_COMMENT

    private NodeKinds() {
    }
}
