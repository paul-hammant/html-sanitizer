package org.htmlsanitizer.groovy

import groovy.transform.CompileStatic
import org.htmlsanitizer.AllowList
import org.htmlsanitizer.Attribute
import org.htmlsanitizer.HtmlSanitizer
import org.htmlsanitizer.Node

/**
 * Groovy extension methods on the Java binding's types.
 *
 * <p>Registered through
 * {@code META-INF/groovy/org.codehaus.groovy.runtime.ExtensionModule}, so they
 * apply to the Java classes without wrapping them — the objects the engine
 * hands a callback stay the very same borrowed views, which matters, because
 * wrapping them would invite retaining a wrapper past the callback that owns it.
 *
 * <p>These are operators and accessors only. No sanitizer logic, no FFI.
 */
@CompileStatic
class HtmlSanitizerExtensions {

    // ---- AllowList as a Groovy collection ----

    /** {@code s.allowedTags << 'my-widget'} */
    static AllowList leftShift(AllowList self, String item) {
        self.add(item)
    }

    /**
     * {@code s.allowedTags << ['b', 'i']}
     *
     * <p>A typed for-loop rather than {@code items.each { self.add(it) }}:
     * under {@code @CompileStatic} the closure parameter of {@code each}
     * infers as Object on some Groovy versions while {@code add} takes a
     * String, so the {@code each} form compiles on one Groovy and fails on
     * another.
     */
    static AllowList leftShift(AllowList self, Iterable<String> items) {
        for (String item : items) {
            self.add(item)
        }
        self
    }

    /** {@code s.allowedTags + 'my-widget'} — mutates and returns the live view. */
    static AllowList plus(AllowList self, String item) {
        self.add(item)
    }

    /** {@code s.allowedTags - 'script'} — the deny direction. */
    static AllowList minus(AllowList self, String item) {
        self.remove(item)
    }

    /** {@code 'div' in s.allowedTags} */
    static boolean isCase(AllowList self, String item) {
        self.contains(item)
    }

    /** {@code s.allowedSchemes.size()} already works; this makes {@code .size} read too. */
    static int getLength(AllowList self) {
        self.size()
    }

    // ---- Node ----

    /** {@code elem['onclick']} — the attribute, or null. */
    static Attribute getAt(Node self, String attributeName) {
        for (Attribute a : self.attributes()) {
            if (a.name() == attributeName) {
                return a
            }
        }
        return null
    }

    /** {@code node.text} — a node's own value (text/comment content). */
    static String getText(Node self) {
        self.value()
    }

    /**
     * Depth-first list of this node and its descendants.
     *
     * <p>A List rather than a lazy Sequence on purpose: the DOM is freed when
     * {@code sanitize} returns, so a lazy walk escaping the callback would
     * dereference freed memory. Building it eagerly inside the callback is the
     * safe shape.
     */
    static List<Node> walk(Node self) {
        List<Node> out = new ArrayList<Node>()
        collect(self, out)
        out
    }

    private static void collect(Node n, List<Node> out) {
        out.add(n)
        for (Node child : n.children()) {
            collect(child, out)
        }
    }

    // ---- HtmlSanitizer ----

    /** {@code s.keepChildNodes = true} rather than {@code s.keepChildNodes(true)}. */
    static void setKeepChildNodes(HtmlSanitizer self, boolean on) {
        self.keepChildNodes(on)
    }

    static boolean getKeepChildNodes(HtmlSanitizer self) {
        self.keepChildNodes()
    }

    static void setAllowDataAttributes(HtmlSanitizer self, boolean on) {
        self.allowDataAttributes(on)
    }

    static boolean getAllowDataAttributes(HtmlSanitizer self) {
        self.allowDataAttributes()
    }

    /**
     * Reconfigure an existing sanitizer with the same DSL
     * {@link HtmlSanitizers#htmlSanitizer} uses.
     */
    static HtmlSanitizer configure(HtmlSanitizer self,
                                   @DelegatesTo(value = SanitizerSpec,
                                                strategy = Closure.DELEGATE_FIRST)
                                   Closure configure) {
        SanitizerSpec spec = new SanitizerSpec(self)
        Closure c = (Closure) configure.clone()
        c.delegate = spec
        c.resolveStrategy = Closure.DELEGATE_FIRST
        if (c.maximumNumberOfParameters == 0) {
            c.call()
        } else {
            c.call(spec)
        }
        self
    }
}
