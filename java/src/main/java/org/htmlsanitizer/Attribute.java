package org.htmlsanitizer;

import java.lang.foreign.Arena;   // referenced from setValue's javadoc
import java.lang.foreign.MemorySegment;

/**
 * A DOM attribute, <b>borrowed</b> for the duration of a callback.
 *
 * <p>Do not retain one past the callback that gave it to you — the DOM is
 * freed when {@code sanitize} returns.
 */
public final class Attribute {

    private final Native api;
    private final MemorySegment ptr;

    Attribute(Native api, MemorySegment ptr) {
        this.api = api;
        this.ptr = ptr;
    }

    public String name() {
        try {
            return api.takeString((MemorySegment) api.attrName.invokeExact(ptr));
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public String value() {
        try {
            return api.takeString((MemorySegment) api.attrValue.invokeExact(ptr));
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /**
     * Rewrite the attribute's value in place — e.g. to canonicalise a URL
     * rather than let the attribute be removed.
     *
     * <p>The ABI stores the pointer we pass straight into the DOM node
     * ({@code at.value = value} in {@code core/embed.ae}) rather than copying
     * it, so the buffer must outlive the callback. A confined {@link Arena}
     * would be freed at the end of this method and leave the DOM pointing at
     * released memory; a libc-{@code malloc}'d copy stays valid for the rest
     * of the sanitize run. It is not freed here — the sanitizer core owns it once
     * stored, the same contract as {@code on_filter_url}'s return value.
     */
    public void setValue(String v) {
        try {
            MemorySegment s = api.mallocString(v);
            api.attrSetValue.invokeExact(ptr, s);
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    @Override
    public String toString() {
        return "Attribute(" + name() + "='" + value() + "')";
    }
}
