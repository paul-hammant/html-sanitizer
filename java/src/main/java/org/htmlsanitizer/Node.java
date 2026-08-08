package org.htmlsanitizer;

import java.lang.foreign.MemorySegment;
import java.util.ArrayList;
import java.util.List;

/**
 * A DOM node, <b>borrowed</b> for the duration of a callback.
 *
 * <p>Do not retain one past the callback that gave it to you — the DOM is
 * freed when {@code sanitize} returns, and a retained Node would then be a
 * dangling pointer.
 */
public final class Node {

    private final Native api;
    private final MemorySegment ptr;

    Node(Native api, MemorySegment ptr) {
        this.api = api;
        this.ptr = ptr;
    }

    /**
     * {@link Native#NODE_DOCUMENT}, {@link Native#NODE_ELEMENT},
     * {@link Native#NODE_TEXT} or {@link Native#NODE_COMMENT}.
     */
    public int kind() {
        try {
            return (int) api.nodeKind.invokeExact(ptr);
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /** Element tag name, lowercased by the parser; empty for non-elements. */
    public String name() {
        try {
            return api.takeString((MemorySegment) api.nodeName.invokeExact(ptr));
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /** Text/comment content; empty for elements and documents. */
    public String value() {
        try {
            return api.takeString((MemorySegment) api.nodeValue.invokeExact(ptr));
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /** The parent node, or null at the root. */
    public Node parent() {
        try {
            MemorySegment p = (MemorySegment) api.nodeParent.invokeExact(ptr);
            return p.equals(MemorySegment.NULL) ? null : new Node(api, p);
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public List<Node> children() {
        try {
            int n = (int) api.nodeChildCount.invokeExact(ptr);
            List<Node> out = new ArrayList<>(Math.max(n, 0));
            for (int i = 0; i < n; i++) {
                out.add(new Node(api, (MemorySegment) api.nodeChildAt.invokeExact(ptr, i)));
            }
            return out;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public List<Attribute> attributes() {
        try {
            int n = (int) api.nodeAttrCount.invokeExact(ptr);
            List<Attribute> out = new ArrayList<>(Math.max(n, 0));
            for (int i = 0; i < n; i++) {
                out.add(new Attribute(api, (MemorySegment) api.nodeAttrAt.invokeExact(ptr, i)));
            }
            return out;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    @Override
    public String toString() {
        return "Node(kind=" + kind() + ", name='" + name() + "')";
    }
}
