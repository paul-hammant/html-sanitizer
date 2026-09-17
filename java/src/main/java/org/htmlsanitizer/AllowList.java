package org.htmlsanitizer;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.util.ArrayList;
import java.util.Collection;
import java.util.Iterator;
import java.util.List;

/**
 * A set-like view over one of the sanitizer core's six policy lists.
 *
 * <p>Obtained from {@link HtmlSanitizer#allowedTags()} and friends. Mutations
 * go straight through to the native sanitizer — there is no local copy.
 */
public final class AllowList implements Iterable<String> {

    private final HtmlSanitizer owner;
    private final int which;

    AllowList(HtmlSanitizer owner, int which) {
        this.owner = owner;
        this.which = which;
    }

    /** Allow {@code item}. Returns this, so calls chain. */
    public AllowList add(String item) {
        try (Arena arena = Arena.ofConfined()) {
            Native api = owner.api();
            int ignored = (int) api.allow.invokeExact(
                    owner.handle(), which, arena.allocateFrom(item == null ? "" : item));
            return this;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public AllowList addAll(Collection<String> items) {
        for (String i : items) add(i);
        return this;
    }

    public AllowList addAll(String... items) {
        for (String i : items) add(i);
        return this;
    }

    /** The "deny" direction — drop an entry that is currently allowed. */
    public AllowList remove(String item) {
        try (Arena arena = Arena.ofConfined()) {
            Native api = owner.api();
            int ignored = (int) api.disallow.invokeExact(
                    owner.handle(), which, arena.allocateFrom(item == null ? "" : item));
            return this;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public boolean contains(String item) {
        try (Arena arena = Arena.ofConfined()) {
            Native api = owner.api();
            return (int) api.isAllowed.invokeExact(
                    owner.handle(), which, arena.allocateFrom(item == null ? "" : item)) != 0;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /** Empty the list — the "start from nothing" move for a strict policy. */
    public AllowList clear() {
        try {
            Native api = owner.api();
            int ignored = (int) api.clear.invokeExact(owner.handle(), which);
            return this;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public int size() {
        try {
            return (int) owner.api().count.invokeExact(owner.handle(), which);
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public boolean isEmpty() {
        return size() == 0;
    }

    /**
     * Snapshot the list. Iteration order is unspecified but each entry appears
     * exactly once.
     */
    public List<String> toList() {
        try {
            Native api = owner.api();
            int n = (int) api.count.invokeExact(owner.handle(), which);
            List<String> out = new ArrayList<>(Math.max(n, 0));
            for (int i = 0; i < n; i++) {
                out.add(api.takeString(
                        (MemorySegment) api.itemAt.invokeExact(owner.handle(), which, i)));
            }
            return out;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    @Override
    public Iterator<String> iterator() {
        return toList().iterator();
    }

    @Override
    public String toString() {
        List<String> v = toList();
        java.util.Collections.sort(v);
        return v.toString();
    }
}
