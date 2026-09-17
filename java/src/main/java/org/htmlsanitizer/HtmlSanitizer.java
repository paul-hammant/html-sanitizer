package org.htmlsanitizer;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.MemorySegment;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;

/**
 * Cleans HTML of constructs that can lead to XSS.
 *
 * <pre>{@code
 * try (HtmlSanitizer s = new HtmlSanitizer()) {
 *     s.allowedTags().add("my-widget");
 *     String clean = s.sanitize("<div onclick=\"evil()\">hi</div>");
 * }
 * }</pre>
 *
 * <p>This class carries <b>no sanitizer logic</b>. The sanitizer core — HTML5
 * tokenizer, DOM, CSS parser, URL resolver, allow-lists — is the pure-Aether
 * {@code core/htmlsanitizer.ae}, shared by every language binding in this
 * monorepo. Everything here marshals to an {@code aether_hs_embed_*} call in
 * {@link Native}.
 *
 * <p>Instances are {@link AutoCloseable}; {@link #close()} releases the native
 * handle and the upcall stubs. Not thread-safe: the sanitizer core calls hooks
 * re-entrantly during {@code sanitize}.
 *
 * <p>Requires {@code --enable-native-access=ALL-UNNAMED} on the command line.
 */
public final class HtmlSanitizer implements AutoCloseable {

    private final Native api;
    private MemorySegment handle;

    /**
     * Upcall stubs and any other native memory tied to this sanitizer's
     * lifetime. Closed in {@link #close()}, never before: an upcall stub that
     * is freed while the sanitizer core can still call it crashes the VM.
     */
    private final Arena callbackArena = Arena.ofShared();

    // Installed handlers, kept as fields so the upcall stubs (which are
    // per-instance and dispatch back through `this`) can find them.
    private RemovingTagHandler removingTag;
    private RemovingAttributeHandler removingAttribute;
    private RemovingStyleHandler removingStyle;
    private RemovingCommentHandler removingComment;
    private PostProcessHandler postProcessNode;
    private PostProcessHandler postProcessDom;
    private FilterUrlHandler filterUrl;

    private final AllowList allowedTags;
    private final AllowList allowedAttributes;
    private final AllowList allowedCssProperties;
    private final AllowList allowedSchemes;
    private final AllowList allowedClasses;
    private final AllowList uriAttributes;

    // ---- handler interfaces ----
    //
    // For the removing* family, returning true CANCELS the removal — i.e.
    // keeps the node/attribute/property.

    @FunctionalInterface
    public interface RemovingTagHandler {
        boolean onRemovingTag(Node node, int reason);
    }

    @FunctionalInterface
    public interface RemovingAttributeHandler {
        boolean onRemovingAttribute(Node element, Attribute attribute, int reason);
    }

    @FunctionalInterface
    public interface RemovingStyleHandler {
        boolean onRemovingStyle(Node element, String name, String value, int reason);
    }

    @FunctionalInterface
    public interface RemovingCommentHandler {
        boolean onRemovingComment(Node node);
    }

    @FunctionalInterface
    public interface PostProcessHandler {
        void onPostProcess(Node node);
    }

    /** Returns the URL to use; an empty string drops the attribute. */
    @FunctionalInterface
    public interface FilterUrlHandler {
        String onFilterUrl(Node element, String rawUrl, String resolvedUrl);
    }

    // ---- lifecycle ----

    /** Load the sanitizer core and create a sanitizer with the secure defaults. */
    public HtmlSanitizer() {
        this(null);
    }

    /**
     * As {@link #HtmlSanitizer()}, but loading the sanitizer core from an explicit
     * path instead of the usual {@code $HTMLSANITIZER_LIB} / bundled /
     * loader-path search.
     */
    public HtmlSanitizer(String nativeLibPath) {
        this.api = Native.load(nativeLibPath);
        try {
            this.handle = (MemorySegment) api.hsNew.invokeExact();
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
        if (handle == null || handle.equals(MemorySegment.NULL)) {
            throw new IllegalStateException("failed to create the native sanitizer");
        }
        this.allowedTags = new AllowList(this, Native.TAGS);
        this.allowedAttributes = new AllowList(this, Native.ATTRIBUTES);
        this.allowedCssProperties = new AllowList(this, Native.CSS_PROPERTIES);
        this.allowedSchemes = new AllowList(this, Native.SCHEMES);
        this.allowedClasses = new AllowList(this, Native.CLASSES);
        this.uriAttributes = new AllowList(this, Native.URI_ATTRIBUTES);
    }

    @Override
    public void close() {
        if (handle != null) {
            try {
                // Frees the sanitizer core's callback boxes too, so no upcall stub can
                // fire after this — which is what makes closing the arena
                // immediately afterwards safe.
                api.free.invokeExact(handle);
            } catch (Throwable t) {
                throw Native.wrap(t);
            } finally {
                handle = null;
                callbackArena.close();
            }
        }
    }

    private void check() {
        if (handle == null) throw new IllegalStateException("sanitizer is closed");
    }

    Native api() {
        return api;
    }

    MemorySegment handle() {
        check();
        return handle;
    }

    /** The sanitizer core's ABI revision. */
    public int abiVersion() {
        try {
            return (int) api.abiVersion.invokeExact();
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    // ---- the main entry points ----

    /** Sanitize an HTML fragment, without resolving relative URLs. */
    public String sanitize(String html) {
        return sanitize(html, "");
    }

    /**
     * Sanitize an HTML fragment, resolving relative URLs against
     * {@code baseUrl} (which may be empty).
     */
    public String sanitize(String html, String baseUrl) {
        check();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment h = arena.allocateFrom(html == null ? "" : html);
            MemorySegment b = arena.allocateFrom(baseUrl == null ? "" : baseUrl);
            return api.takeString((MemorySegment) api.sanitize.invokeExact(handle, h, b));
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /** Sanitize a full HTML document. */
    public String sanitizeDocument(String html) {
        return sanitizeDocument(html, "");
    }

    public String sanitizeDocument(String html, String baseUrl) {
        check();
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment h = arena.allocateFrom(html == null ? "" : html);
            MemorySegment b = arena.allocateFrom(baseUrl == null ? "" : baseUrl);
            return api.takeString((MemorySegment) api.sanitizeDocument.invokeExact(handle, h, b));
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    // ---- flags ----

    /** Keep the children of a removed element instead of dropping the subtree. */
    public boolean keepChildNodes() {
        try {
            return (int) api.getKeepChildNodes.invokeExact(handle()) != 0;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public HtmlSanitizer keepChildNodes(boolean on) {
        try {
            api.setKeepChildNodes.invokeExact(handle(), on ? 1 : 0);
            return this;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    /** Allow {@code data-*} attributes through without listing each one. */
    public boolean allowDataAttributes() {
        try {
            return (int) api.getAllowDataAttributes.invokeExact(handle()) != 0;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    public HtmlSanitizer allowDataAttributes(boolean on) {
        try {
            api.setAllowDataAttributes.invokeExact(handle(), on ? 1 : 0);
            return this;
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    // ---- allow-lists ----

    public AllowList allowedTags() {
        return allowedTags;
    }

    public AllowList allowedAttributes() {
        return allowedAttributes;
    }

    public AllowList allowedCssProperties() {
        return allowedCssProperties;
    }

    public AllowList allowedSchemes() {
        return allowedSchemes;
    }

    public AllowList allowedClasses() {
        return allowedClasses;
    }

    public AllowList uriAttributes() {
        return uriAttributes;
    }

    // ---- callbacks ----
    //
    // Each on* builds an upcall stub bound to `this` and registers it with a
    // NULL user_data: the stub already closes over the instance, so the ABI's
    // user_data channel is spare here (other bindings use it to find their
    // handler). Passing a null handler clears the hook.

    public HtmlSanitizer onRemovingTag(RemovingTagHandler handler) {
        check();
        this.removingTag = handler;
        install(api.onRemovingTag, handler, "tagUpcall", Native.CB_REMOVING_TAG,
                MethodType.methodType(int.class, MemorySegment.class, MemorySegment.class, int.class));
        return this;
    }

    public HtmlSanitizer onRemovingAttribute(RemovingAttributeHandler handler) {
        check();
        this.removingAttribute = handler;
        install(api.onRemovingAttribute, handler, "attributeUpcall", Native.CB_REMOVING_ATTRIBUTE,
                MethodType.methodType(int.class, MemorySegment.class, MemorySegment.class,
                        MemorySegment.class, int.class));
        return this;
    }

    public HtmlSanitizer onRemovingStyle(RemovingStyleHandler handler) {
        check();
        this.removingStyle = handler;
        install(api.onRemovingStyle, handler, "styleUpcall", Native.CB_REMOVING_STYLE,
                MethodType.methodType(int.class, MemorySegment.class, MemorySegment.class,
                        MemorySegment.class, MemorySegment.class, int.class));
        return this;
    }

    public HtmlSanitizer onRemovingComment(RemovingCommentHandler handler) {
        check();
        this.removingComment = handler;
        install(api.onRemovingComment, handler, "commentUpcall", Native.CB_REMOVING_COMMENT,
                MethodType.methodType(int.class, MemorySegment.class, MemorySegment.class));
        return this;
    }

    public HtmlSanitizer onPostProcessNode(PostProcessHandler handler) {
        check();
        this.postProcessNode = handler;
        install(api.onPostProcessNode, handler, "postNodeUpcall", Native.CB_POST_PROCESS,
                MethodType.methodType(void.class, MemorySegment.class, MemorySegment.class));
        return this;
    }

    public HtmlSanitizer onPostProcessDom(PostProcessHandler handler) {
        check();
        this.postProcessDom = handler;
        install(api.onPostProcessDom, handler, "postDomUpcall", Native.CB_POST_PROCESS,
                MethodType.methodType(void.class, MemorySegment.class, MemorySegment.class));
        return this;
    }

    public HtmlSanitizer onFilterUrl(FilterUrlHandler handler) {
        check();
        this.filterUrl = handler;
        install(api.onFilterUrl, handler, "filterUrlUpcall", Native.CB_FILTER_URL,
                MethodType.methodType(MemorySegment.class, MemorySegment.class,
                        MemorySegment.class, MemorySegment.class, MemorySegment.class));
        return this;
    }

    /**
     * Register (or, for a null handler, clear) one hook.
     *
     * <p>The upcall target is bound to {@code this}, so each sanitizer gets
     * its own stub; the stub lives in {@link #callbackArena} and is released
     * only by {@link #close()}.
     */
    private void install(MethodHandle register, Object handler, String upcallName,
                         FunctionDescriptor descriptor, MethodType type) {
        try {
            if (handler == null) {
                register.invokeExact(handle, MemorySegment.NULL, MemorySegment.NULL);
                return;
            }
            MethodHandle target = MethodHandles.lookup()
                    .findVirtual(HtmlSanitizer.class, upcallName, type)
                    .bindTo(this);
            MemorySegment stub = api.linker.upcallStub(target, descriptor, callbackArena);
            register.invokeExact(handle, stub, MemorySegment.NULL);
        } catch (Throwable t) {
            throw Native.wrap(t);
        }
    }

    // ---- upcall targets ----
    //
    // Reached only from a native trampoline. They must not declare checked
    // exceptions (the linker rejects that), so anything thrown is wrapped.
    // `ud` is the ABI's user_data — always NULL here, since the stub is bound
    // to the instance instead.

    private int tagUpcall(MemorySegment ud, MemorySegment node, int reason) {
        RemovingTagHandler h = removingTag;
        if (h == null) return 0;
        return h.onRemovingTag(new Node(api, node), reason) ? 1 : 0;
    }

    private int attributeUpcall(MemorySegment ud, MemorySegment elem,
                                MemorySegment attr, int reason) {
        RemovingAttributeHandler h = removingAttribute;
        if (h == null) return 0;
        return h.onRemovingAttribute(new Node(api, elem), new Attribute(api, attr), reason) ? 1 : 0;
    }

    private int styleUpcall(MemorySegment ud, MemorySegment elem,
                            MemorySegment name, MemorySegment value, int reason) {
        RemovingStyleHandler h = removingStyle;
        if (h == null) return 0;
        return h.onRemovingStyle(new Node(api, elem), Native.readString(name),
                Native.readString(value), reason) ? 1 : 0;
    }

    private int commentUpcall(MemorySegment ud, MemorySegment node) {
        RemovingCommentHandler h = removingComment;
        if (h == null) return 0;
        return h.onRemovingComment(new Node(api, node)) ? 1 : 0;
    }

    private void postNodeUpcall(MemorySegment ud, MemorySegment node) {
        PostProcessHandler h = postProcessNode;
        if (h != null) h.onPostProcess(new Node(api, node));
    }

    private void postDomUpcall(MemorySegment ud, MemorySegment doc) {
        PostProcessHandler h = postProcessDom;
        if (h != null) h.onPostProcess(new Node(api, doc));
    }

    private MemorySegment filterUrlUpcall(MemorySegment ud, MemorySegment elem,
                                          MemorySegment raw, MemorySegment resolved) {
        FilterUrlHandler h = filterUrl;
        // "No rewrite" — hand the resolved pointer straight back; the C
        // trampoline recognises it and neither copies nor frees it.
        if (h == null) return resolved;
        String out = h.onFilterUrl(new Node(api, elem), Native.readString(raw),
                Native.readString(resolved));
        // The sanitizer core takes ownership of this buffer and frees it with libc free.
        return api.mallocString(out);
    }
}
