package org.htmlsanitizer;

import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.SymbolLookup;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.List;

/**
 * The 1:1 symbol table for the HtmlSanitizer C ABI ({@code core/embed.ae}),
 * bound with the Java 22+ Foreign Function &amp; Memory API (JEP 454).
 *
 * <p>This class is the ONLY place in the Java binding that knows about the C
 * ABI. Everything above it ({@link HtmlSanitizer}) is idiomatic Java over
 * these handles. No sanitizer logic lives here or anywhere else in this
 * package — the sanitizer core is {@code core/htmlsanitizer.ae}, shared by every
 * language binding.
 *
 * <h2>Naming</h2>
 * {@code core/embed.ae} names its exports {@code hs_embed_<name>}; building
 * with {@code --emit=lib} mangles them to {@code aether_hs_embed_<name>},
 * which is what we look up.
 *
 * <h2>The two ownership rules</h2>
 * <ol>
 *   <li>Every {@code char*} this ABI returns is <b>caller-owned</b> and must
 *       come back through {@code free_string}. {@link #takeString} does that;
 *       leaking is the single most common binding bug.</li>
 *   <li>Node and attribute pointers handed to a callback are <b>borrowed</b>,
 *       valid only for that callback — the DOM is freed when sanitize
 *       returns. Never retain one.</li>
 * </ol>
 *
 * <h2>Running</h2>
 * FFM needs {@code --enable-native-access=ALL-UNNAMED} on the command line.
 * It does <b>not</b> need {@code --enable-preview}: FFM is final since JDK 22.
 */
public final class Native {

    // ---- allow-list selectors (ABI constants — append only, never renumber) ----
    public static final int TAGS = 0;
    public static final int ATTRIBUTES = 1;
    public static final int CSS_PROPERTIES = 2;
    public static final int SCHEMES = 3;
    public static final int CLASSES = 4;
    public static final int URI_ATTRIBUTES = 5;

    // ---- removal reasons, as passed to the callbacks ----
    public static final int REASON_NOT_ALLOWED_TAG = 0;
    public static final int REASON_NOT_ALLOWED_ATTRIBUTE = 1;
    public static final int REASON_NOT_ALLOWED_STYLE = 2;
    public static final int REASON_NOT_ALLOWED_URL_VALUE = 3;
    public static final int REASON_NOT_ALLOWED_VALUE = 4;
    public static final int REASON_NOT_ALLOWED_CSS_CLASS = 5;
    public static final int REASON_CLASS_ATTRIBUTE_EMPTY = 6;
    public static final int REASON_STYLE_ATTRIBUTE_EMPTY = 7;

    // ---- node kinds ----
    public static final int NODE_DOCUMENT = 1;
    public static final int NODE_ELEMENT = 2;
    public static final int NODE_TEXT = 3;
    public static final int NODE_COMMENT = 4;

    private static final ValueLayout.OfInt I = ValueLayout.JAVA_INT;
    private static final java.lang.foreign.AddressLayout P = ValueLayout.ADDRESS;

    /** The platform's shared-library file name for the sanitizer core. */
    public static final String LIB_NAME = libName();

    private static String libName() {
        String os = System.getProperty("os.name", "").toLowerCase();
        if (os.contains("mac")) return "libhtmlsanitizer.dylib";
        if (os.contains("win")) return "htmlsanitizer.dll";
        return "libhtmlsanitizer.so";
    }

    // ---- callback descriptors ----
    //
    // Each hook receives the opaque user_data registered alongside it as its
    // FIRST argument; the sanitizer core's C trampolines supply it. Integer arguments
    // are C `int` (JAVA_INT), not `long` — the doc block in core/embed.ae says
    // `long`, but core/_embed_support.c, which is what actually runs, uses
    // `int`. For the removing_* family a NON-ZERO return CANCELS the removal.

    /** {@code int f(void* ud, void* node, int reason)} */
    public static final FunctionDescriptor CB_REMOVING_TAG =
            FunctionDescriptor.of(I, P, P, I);
    /** {@code int f(void* ud, void* elem, void* attr, int reason)} */
    public static final FunctionDescriptor CB_REMOVING_ATTRIBUTE =
            FunctionDescriptor.of(I, P, P, P, I);
    /** {@code int f(void* ud, void* elem, const char* name, const char* value, int reason)} */
    public static final FunctionDescriptor CB_REMOVING_STYLE =
            FunctionDescriptor.of(I, P, P, P, P, I);
    /** {@code int f(void* ud, void* node)} */
    public static final FunctionDescriptor CB_REMOVING_COMMENT =
            FunctionDescriptor.of(I, P, P);
    /** {@code void f(void* ud, void* node)} — both post-process hooks. */
    public static final FunctionDescriptor CB_POST_PROCESS =
            FunctionDescriptor.ofVoid(P, P);
    /** {@code char* f(void* ud, void* elem, const char* raw, const char* resolved)} */
    public static final FunctionDescriptor CB_FILTER_URL =
            FunctionDescriptor.of(P, P, P, P, P);

    public final Linker linker;
    private final SymbolLookup lookup;

    // ---- lifecycle ----
    public final MethodHandle hsNew;
    public final MethodHandle free;
    public final MethodHandle freeString;

    // ---- the main entry points ----
    public final MethodHandle sanitize;
    public final MethodHandle sanitizeDocument;

    // ---- boolean flags ----
    public final MethodHandle setKeepChildNodes;
    public final MethodHandle getKeepChildNodes;
    public final MethodHandle setAllowDataAttributes;
    public final MethodHandle getAllowDataAttributes;

    // ---- allow-list mutation (the `which` selector is an ABI constant) ----
    public final MethodHandle allow;
    public final MethodHandle disallow;
    public final MethodHandle isAllowed;
    public final MethodHandle clear;
    public final MethodHandle count;
    public final MethodHandle itemAt;

    // ---- callbacks (fn pointer + opaque user_data; NULL fn clears) ----
    public final MethodHandle onRemovingTag;
    public final MethodHandle onRemovingAttribute;
    public final MethodHandle onRemovingStyle;
    public final MethodHandle onRemovingComment;
    public final MethodHandle onPostProcessNode;
    public final MethodHandle onPostProcessDom;
    public final MethodHandle onFilterUrl;

    // ---- DOM accessors (borrowed pointers, valid only inside a callback) ----
    public final MethodHandle nodeKind;
    public final MethodHandle nodeName;
    public final MethodHandle nodeValue;
    public final MethodHandle nodeChildCount;
    public final MethodHandle nodeChildAt;
    public final MethodHandle nodeParent;
    public final MethodHandle nodeAttrCount;
    public final MethodHandle nodeAttrAt;
    public final MethodHandle attrName;
    public final MethodHandle attrValue;
    public final MethodHandle attrSetValue;

    // ---- version / introspection ----
    public final MethodHandle abiVersion;

    /** libc {@code malloc}, for the one hook that hands the sanitizer core a string it then owns. */
    private final MethodHandle malloc;

    private static volatile Native cached;

    /**
     * Load the sanitizer core and bind every symbol, caching the result process-wide.
     *
     * <p>Resolution order, matching every other binding in the monorepo:
     * <ol>
     *   <li>{@code explicitPath}, when non-null</li>
     *   <li>{@code $HTMLSANITIZER_LIB}</li>
     *   <li>{@code native/} beside the jar</li>
     *   <li>the OS loader's own search path</li>
     * </ol>
     */
    public static Native load(String explicitPath) {
        if (explicitPath == null) {
            Native c = cached;
            if (c != null) return c;
        }
        Native n = new Native(explicitPath);
        if (explicitPath == null) cached = n;
        return n;
    }

    private Native(String explicitPath) {
        this.linker = Linker.nativeLinker();
        this.lookup = openLibrary(explicitPath);

        hsNew = downcall("aether_hs_embed_new", FunctionDescriptor.of(P));
        free = downcall("aether_hs_embed_free", FunctionDescriptor.ofVoid(P));
        freeString = downcall("aether_hs_embed_free_string", FunctionDescriptor.ofVoid(P));

        sanitize = downcall("aether_hs_embed_sanitize", FunctionDescriptor.of(P, P, P, P));
        sanitizeDocument = downcall("aether_hs_embed_sanitize_document",
                FunctionDescriptor.of(P, P, P, P));

        setKeepChildNodes = downcall("aether_hs_embed_set_keep_child_nodes",
                FunctionDescriptor.ofVoid(P, I));
        getKeepChildNodes = downcall("aether_hs_embed_get_keep_child_nodes",
                FunctionDescriptor.of(I, P));
        setAllowDataAttributes = downcall("aether_hs_embed_set_allow_data_attributes",
                FunctionDescriptor.ofVoid(P, I));
        getAllowDataAttributes = downcall("aether_hs_embed_get_allow_data_attributes",
                FunctionDescriptor.of(I, P));

        allow = downcall("aether_hs_embed_allow", FunctionDescriptor.of(I, P, I, P));
        disallow = downcall("aether_hs_embed_disallow", FunctionDescriptor.of(I, P, I, P));
        isAllowed = downcall("aether_hs_embed_is_allowed", FunctionDescriptor.of(I, P, I, P));
        clear = downcall("aether_hs_embed_clear", FunctionDescriptor.of(I, P, I));
        count = downcall("aether_hs_embed_count", FunctionDescriptor.of(I, P, I));
        itemAt = downcall("aether_hs_embed_item_at", FunctionDescriptor.of(P, P, I, I));

        onRemovingTag = downcall("aether_hs_embed_on_removing_tag",
                FunctionDescriptor.ofVoid(P, P, P));
        onRemovingAttribute = downcall("aether_hs_embed_on_removing_attribute",
                FunctionDescriptor.ofVoid(P, P, P));
        onRemovingStyle = downcall("aether_hs_embed_on_removing_style",
                FunctionDescriptor.ofVoid(P, P, P));
        onRemovingComment = downcall("aether_hs_embed_on_removing_comment",
                FunctionDescriptor.ofVoid(P, P, P));
        onPostProcessNode = downcall("aether_hs_embed_on_post_process_node",
                FunctionDescriptor.ofVoid(P, P, P));
        onPostProcessDom = downcall("aether_hs_embed_on_post_process_dom",
                FunctionDescriptor.ofVoid(P, P, P));
        onFilterUrl = downcall("aether_hs_embed_on_filter_url",
                FunctionDescriptor.ofVoid(P, P, P));

        nodeKind = downcall("aether_hs_embed_node_kind", FunctionDescriptor.of(I, P));
        nodeName = downcall("aether_hs_embed_node_name", FunctionDescriptor.of(P, P));
        nodeValue = downcall("aether_hs_embed_node_value", FunctionDescriptor.of(P, P));
        nodeChildCount = downcall("aether_hs_embed_node_child_count",
                FunctionDescriptor.of(I, P));
        nodeChildAt = downcall("aether_hs_embed_node_child_at",
                FunctionDescriptor.of(P, P, I));
        nodeParent = downcall("aether_hs_embed_node_parent", FunctionDescriptor.of(P, P));
        nodeAttrCount = downcall("aether_hs_embed_node_attr_count",
                FunctionDescriptor.of(I, P));
        nodeAttrAt = downcall("aether_hs_embed_node_attr_at",
                FunctionDescriptor.of(P, P, I));
        attrName = downcall("aether_hs_embed_attr_name", FunctionDescriptor.of(P, P));
        attrValue = downcall("aether_hs_embed_attr_value", FunctionDescriptor.of(P, P));
        attrSetValue = downcall("aether_hs_embed_attr_set_value",
                FunctionDescriptor.ofVoid(P, P));

        abiVersion = downcall("aether_hs_embed_abi_version", FunctionDescriptor.of(I));

        // The sanitizer core's C side frees filter_url's result with free(), so the
        // matching malloc must be libc's — a Java Arena allocation handed
        // over there would be freed by the wrong allocator.
        malloc = linker.downcallHandle(
                linker.defaultLookup().find("malloc")
                        .orElseThrow(() -> new IllegalStateException("libc malloc not found")),
                FunctionDescriptor.of(P, ValueLayout.JAVA_LONG));
    }

    private SymbolLookup openLibrary(String explicitPath) {
        List<String> candidates = new ArrayList<>();
        if (explicitPath != null) {
            candidates.add(explicitPath);
        } else {
            String env = System.getenv("HTMLSANITIZER_LIB");
            if (env != null && !env.isEmpty()) candidates.add(env);
            String prop = System.getProperty("htmlsanitizer.lib");
            if (prop != null && !prop.isEmpty()) candidates.add(prop);
            candidates.add(Paths.get("native", LIB_NAME).toString());
            candidates.add(LIB_NAME);
        }

        RuntimeException last = null;
        for (String cand : candidates) {
            try {
                Path p = Paths.get(cand);
                // libraryLookup(String) goes through the OS loader; give it a
                // Path only when the file really is there, so a bare name
                // still falls through to the loader's search path.
                if (Files.exists(p)) {
                    return SymbolLookup.libraryLookup(p, Arena.global());
                }
                return SymbolLookup.libraryLookup(cand, Arena.global());
            } catch (RuntimeException e) {
                last = e;
            }
        }
        throw new IllegalStateException(
                "could not load the HtmlSanitizer core (" + LIB_NAME + "). Set "
                        + "HTMLSANITIZER_LIB to its absolute path. Last error: "
                        + (last == null ? "no candidates" : last.getMessage()), last);
    }

    private MethodHandle downcall(String name, FunctionDescriptor fd) {
        MemorySegment sym = lookup.find(name).orElseThrow(
                () -> new IllegalStateException("missing symbol " + name + " (sanitizer core too old?)"));
        return linker.downcallHandle(sym, fd);
    }

    // ---- string marshalling ----

    /**
     * Copy an ABI-returned string out and free it through the ABI.
     *
     * <p>Every {@code char*} the sanitizer core returns is caller-owned; leaking it is
     * the single easiest mistake to make in any of these bindings.
     */
    public String takeString(MemorySegment ptr) {
        if (ptr == null || ptr.equals(MemorySegment.NULL)) return "";
        try {
            // A returned pointer has zero byteSize; reinterpret so the string
            // can actually be read from it.
            return ptr.reinterpret(Long.MAX_VALUE).getString(0);
        } finally {
            try {
                freeString.invokeExact(ptr);
            } catch (Throwable t) {
                throw wrap(t);
            }
        }
    }

    /**
     * Read a borrowed {@code const char*} a callback was handed. NOT owned by
     * us — the sanitizer core keeps it, so there is nothing to free.
     */
    public static String readString(MemorySegment ptr) {
        if (ptr == null || ptr.equals(MemorySegment.NULL)) return "";
        return ptr.reinterpret(Long.MAX_VALUE).getString(0);
    }

    /**
     * Copy a Java string into a libc-{@code malloc}'d buffer the sanitizer core will
     * own and {@code free}. Used only by the {@code on_filter_url} hook.
     */
    public MemorySegment mallocString(String s) {
        byte[] bytes = (s == null ? "" : s).getBytes(java.nio.charset.StandardCharsets.UTF_8);
        try {
            MemorySegment p = (MemorySegment) malloc.invokeExact((long) bytes.length + 1);
            if (p.equals(MemorySegment.NULL)) return MemorySegment.NULL;
            MemorySegment w = p.reinterpret(bytes.length + 1);
            MemorySegment.copy(bytes, 0, w, ValueLayout.JAVA_BYTE, 0, bytes.length);
            w.set(ValueLayout.JAVA_BYTE, bytes.length, (byte) 0);
            return p;
        } catch (Throwable t) {
            throw wrap(t);
        }
    }

    /** MethodHandle invocation throws Throwable; funnel it into an unchecked type. */
    public static RuntimeException wrap(Throwable t) {
        if (t instanceof RuntimeException re) return re;
        if (t instanceof Error e) throw e;
        return new RuntimeException(t);
    }
}
