// The 1:1 symbol table for the HtmlSanitizer C ABI (core/embed.ae).
//
// This file is the ONLY place in the .NET binding that knows about the C ABI.
// Everything above it (HtmlSanitizer.cs) is idiomatic C# over these symbols.
// No sanitizer logic lives here or anywhere else in this assembly — the sanitizer core
// is core/htmlsanitizer.ae, shared by every language binding.
//
// ## Naming
//
// core/embed.ae names its exports `hs_embed_<name>`; building with
// `--emit=lib` mangles them to **`aether_hs_embed_<name>`**. That mangled name
// is what these DllImports bind.
//
// ## The two ownership rules
//
//  1. **Every char* this ABI returns is caller-owned** and must be handed back
//     to `aether_hs_embed_free_string`. Leaking it is the single most common
//     bug in a binding. Note the returns are declared `IntPtr`, *not*
//     `string`: the default marshaller would copy the string and then free it
//     with `Marshal.FreeCoTaskMem`, which is the wrong allocator and corrupts
//     the heap. `Native.TakeString` does the right thing.
//  2. **Node and attribute pointers handed to a callback are borrowed** —
//     valid only for the duration of that callback, because the DOM is freed
//     when `sanitize` returns. Never retain one.
//
// ## Callback ABI
//
// Each hook receives the opaque `user_data` registered alongside it as its
// **first** argument; the sanitizer core's C trampolines (core/_embed_support.c)
// supply it. Integer arguments are C `int`, NOT `long` — which is why every
// delegate below uses `int` and never `nint`/`long`.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace HtmlSanitization;

/// <summary>Allow-list selectors (ABI constants — append only, never renumber).</summary>
public enum AllowListKind
{
    /// <summary>allowed_tags</summary>
    Tags = 0,
    /// <summary>allowed_attributes</summary>
    Attributes = 1,
    /// <summary>allowed_css_properties</summary>
    CssProperties = 2,
    /// <summary>allowed_schemes</summary>
    Schemes = 3,
    /// <summary>allowed_classes</summary>
    Classes = 4,
    /// <summary>uri_attributes</summary>
    UriAttributes = 5,
}

/// <summary>Why the sanitizer core is about to remove something.</summary>
public enum RemovalReason
{
    /// <summary>The tag is not in <c>AllowedTags</c>.</summary>
    NotAllowedTag = 0,
    /// <summary>The attribute is not in <c>AllowedAttributes</c>.</summary>
    NotAllowedAttribute = 1,
    /// <summary>The CSS property is not in <c>AllowedCssProperties</c>.</summary>
    NotAllowedStyle = 2,
    /// <summary>The URL's scheme is not in <c>AllowedSchemes</c>.</summary>
    NotAllowedUrlValue = 3,
    /// <summary>The attribute's value was rejected.</summary>
    NotAllowedValue = 4,
    /// <summary>The class is not in <c>AllowedClasses</c>.</summary>
    NotAllowedCssClass = 5,
    /// <summary>Filtering emptied the <c>class</c> attribute.</summary>
    ClassAttributeEmpty = 6,
    /// <summary>Filtering emptied the <c>style</c> attribute.</summary>
    StyleAttributeEmpty = 7,
}

/// <summary>What kind of DOM node this is.</summary>
public enum NodeKind
{
    /// <summary>A null node, or a kind this binding does not know.</summary>
    Unknown = 0,
    /// <summary>The document root.</summary>
    Document = 1,
    /// <summary>An element.</summary>
    Element = 2,
    /// <summary>A text node.</summary>
    Text = 3,
    /// <summary>A comment node.</summary>
    Comment = 4,
}

// ---- callback delegate types ----
//
// Every one takes the opaque user_data FIRST, and every integer is `int`.
// UnmanagedFunctionPointer(Cdecl) is explicit rather than relied upon: the
// platform default differs on 32-bit Windows, and a stdcall/cdecl mismatch
// corrupts the stack.

/// <summary>int f(void* ud, void* node, int reason) — non-zero CANCELS the removal.</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CbRemovingTag(IntPtr userData, IntPtr node, int reason);

/// <summary>int f(void* ud, void* elem, void* attr, int reason) — non-zero CANCELS.</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CbRemovingAttribute(IntPtr userData, IntPtr elem, IntPtr attr, int reason);

/// <summary>
/// int f(void* ud, void* elem, const char* name, const char* value, int reason)
/// — non-zero CANCELS. The two strings are BORROWED; they are declared IntPtr
/// so the marshaller does not try to free them.
/// </summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CbRemovingStyle(IntPtr userData, IntPtr elem, IntPtr name, IntPtr value, int reason);

/// <summary>int f(void* ud, void* node) — non-zero CANCELS the removal.</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate int CbRemovingComment(IntPtr userData, IntPtr node);

/// <summary>void f(void* ud, void* node)</summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate void CbPostProcess(IntPtr userData, IntPtr node);

/// <summary>
/// char* f(void* ud, void* elem, const char* raw, const char* resolved)
/// — returns a malloc'd C string the sanitizer core takes ownership of, or the
/// `resolved` pointer unchanged to mean "no rewrite".
/// </summary>
[UnmanagedFunctionPointer(CallingConvention.Cdecl)]
public delegate IntPtr CbFilterUrl(IntPtr userData, IntPtr elem, IntPtr raw, IntPtr resolved);

/// <summary>
/// The raw P/Invoke surface. Public so an advanced caller can reach it, but
/// <see cref="HtmlSanitizer"/> is the supported API.
/// </summary>
public static class Native
{
    /// <summary>
    /// The name .NET resolves. A bare name (no "lib" prefix, no extension)
    /// lets the default probing find libhtmlsanitizer.so / .dylib /
    /// htmlsanitizer.dll per platform; <see cref="EnsureResolver"/> installs
    /// the explicit-path and $HTMLSANITIZER_LIB rules on top.
    /// </summary>
    public const string Lib = "htmlsanitizer";

    // ---- lifecycle ----

    [DllImport(Lib, EntryPoint = "aether_hs_embed_new", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr New();

    [DllImport(Lib, EntryPoint = "aether_hs_embed_free", CallingConvention = CallingConvention.Cdecl)]
    public static extern void Free(IntPtr handle);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_free_string", CallingConvention = CallingConvention.Cdecl)]
    public static extern void FreeString(IntPtr str);

    // ---- the main entry point ----
    //
    // The two string arguments are byte[] (UTF-8 the binding encodes itself)
    // rather than `string`: .NET's default marshalling of `string` on a
    // DllImport is ANSI on some platforms, which mangles non-ASCII HTML. The
    // returns are IntPtr — see the ownership note at the top of this file.

    [DllImport(Lib, EntryPoint = "aether_hs_embed_sanitize", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr Sanitize(IntPtr handle, byte[] html, byte[] baseUrl);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_sanitize_document", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SanitizeDocument(IntPtr handle, byte[] html, byte[] baseUrl);

    // ---- boolean flags ----

    [DllImport(Lib, EntryPoint = "aether_hs_embed_set_keep_child_nodes", CallingConvention = CallingConvention.Cdecl)]
    public static extern void SetKeepChildNodes(IntPtr handle, int on);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_get_keep_child_nodes", CallingConvention = CallingConvention.Cdecl)]
    public static extern int GetKeepChildNodes(IntPtr handle);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_set_allow_data_attributes", CallingConvention = CallingConvention.Cdecl)]
    public static extern void SetAllowDataAttributes(IntPtr handle, int on);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_get_allow_data_attributes", CallingConvention = CallingConvention.Cdecl)]
    public static extern int GetAllowDataAttributes(IntPtr handle);

    // ---- allow-list mutation ----

    [DllImport(Lib, EntryPoint = "aether_hs_embed_allow", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Allow(IntPtr handle, int which, byte[] item);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_disallow", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Disallow(IntPtr handle, int which, byte[] item);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_is_allowed", CallingConvention = CallingConvention.Cdecl)]
    public static extern int IsAllowed(IntPtr handle, int which, byte[] item);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_clear", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Clear(IntPtr handle, int which);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_count", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Count(IntPtr handle, int which);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_item_at", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ItemAt(IntPtr handle, int which, int index);

    // ---- callbacks ----
    //
    // Registered as IntPtr rather than the delegate type. Passing a delegate
    // directly would let the marshaller create a stub whose lifetime the
    // caller cannot see; taking the pointer explicitly with
    // Marshal.GetFunctionPointerForDelegate makes the keepalive requirement
    // impossible to overlook.

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_removing_tag", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnRemovingTag(IntPtr handle, IntPtr fn, IntPtr userData);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_removing_attribute", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnRemovingAttribute(IntPtr handle, IntPtr fn, IntPtr userData);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_removing_style", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnRemovingStyle(IntPtr handle, IntPtr fn, IntPtr userData);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_removing_comment", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnRemovingComment(IntPtr handle, IntPtr fn, IntPtr userData);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_post_process_node", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnPostProcessNode(IntPtr handle, IntPtr fn, IntPtr userData);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_post_process_dom", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnPostProcessDom(IntPtr handle, IntPtr fn, IntPtr userData);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_on_filter_url", CallingConvention = CallingConvention.Cdecl)]
    public static extern void OnFilterUrl(IntPtr handle, IntPtr fn, IntPtr userData);

    // ---- DOM accessors (for use inside callbacks) ----

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_kind", CallingConvention = CallingConvention.Cdecl)]
    public static extern int NodeKindOf(IntPtr node);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_name", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr NodeName(IntPtr node);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_value", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr NodeValue(IntPtr node);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_child_count", CallingConvention = CallingConvention.Cdecl)]
    public static extern int NodeChildCount(IntPtr node);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_child_at", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr NodeChildAt(IntPtr node, int index);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_parent", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr NodeParent(IntPtr node);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_attr_count", CallingConvention = CallingConvention.Cdecl)]
    public static extern int NodeAttrCount(IntPtr node);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_node_attr_at", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr NodeAttrAt(IntPtr node, int index);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_attr_name", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr AttrName(IntPtr attr);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_attr_value", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr AttrValue(IntPtr attr);

    [DllImport(Lib, EntryPoint = "aether_hs_embed_attr_set_value", CallingConvention = CallingConvention.Cdecl)]
    public static extern void AttrSetValue(IntPtr attr, byte[] value);

    // ---- version / introspection ----

    [DllImport(Lib, EntryPoint = "aether_hs_embed_abi_version", CallingConvention = CallingConvention.Cdecl)]
    public static extern int AbiVersion();

    // ---- the allocator the sanitizer core itself frees with ----
    //
    // on_filter_url must return a buffer the sanitizer core frees. Marshal's
    // AllocHGlobal/StringToCoTaskMemUTF8 use allocators the sanitizer core's free()
    // knows nothing about, so the replacement URL has to come from malloc.
    //
    // hs_raw_dup is the sanitizer core's own malloc'd strdup (core/_embed_support.c),
    // exported by the same library. Using it rather than P/Invoking libc's
    // strdup avoids a second DllImport whose module name differs per platform
    // ("libc" vs "msvcrt", "_strdup" vs "strdup"), and is by construction the
    // exact counterpart of the free() that will release the buffer.

    [DllImport(Lib, EntryPoint = "hs_raw_dup", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr RawDup(byte[] s);

    /// <summary>
    /// Duplicate a string into a malloc'd buffer the sanitizer core takes ownership
    /// of. Only for <see cref="CbFilterUrl"/> returns.
    /// </summary>
    public static IntPtr StrDup(string? value) => RawDup(Encode(value));

    // ---- string marshalling ----

    /// <summary>NUL-terminated UTF-8 for a string argument.</summary>
    public static byte[] Encode(string? value)
    {
        value ??= string.Empty;
        int n = Encoding.UTF8.GetByteCount(value);
        var buf = new byte[n + 1];
        Encoding.UTF8.GetBytes(value, 0, value.Length, buf, 0);
        buf[n] = 0;
        return buf;
    }

    /// <summary>
    /// Copy an ABI-returned string out and free it through the ABI.
    ///
    /// Every char* the sanitizer core returns is caller-owned; leaking it is the
    /// single easiest mistake to make in any of these bindings. Every string
    /// result in this assembly goes through here.
    /// </summary>
    public static string TakeString(IntPtr ptr)
    {
        if (ptr == IntPtr.Zero) return string.Empty;
        try
        {
            return Marshal.PtrToStringUTF8(ptr) ?? string.Empty;
        }
        finally
        {
            FreeString(ptr);
        }
    }

    /// <summary>
    /// Read a BORROWED const char* (a callback argument) without freeing it —
    /// the sanitizer core owns those.
    /// </summary>
    public static string BorrowString(IntPtr ptr) =>
        ptr == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUTF8(ptr) ?? string.Empty;

    // ---- library resolution ----

    private static readonly object ResolverLock = new();
    private static bool _resolverInstalled;
    private static string? _explicitPath;

    /// <summary>The path the sanitizer core was actually loaded from, once known.</summary>
    public static string? ResolvedPath { get; private set; }

    /// <summary>
    /// Install the DllImport resolver, in resolution order:
    /// <list type="number">
    ///   <item>an explicit path passed here</item>
    ///   <item>$HTMLSANITIZER_LIB (what the in-tree .tests.ae leaf sets)</item>
    ///   <item>native/ next to the assembly, then ../core/native/</item>
    ///   <item>the OS loader's own search path (the default probing)</item>
    /// </list>
    /// </summary>
    public static void EnsureResolver(string? explicitPath = null)
    {
        lock (ResolverLock)
        {
            if (explicitPath is { Length: > 0 }) _explicitPath = explicitPath;
            if (_resolverInstalled) return;
            _resolverInstalled = true;

            NativeLibrary.SetDllImportResolver(
                typeof(Native).Assembly,
                (name, assembly, searchPath) =>
                {
                    if (name != Lib) return IntPtr.Zero;
                    foreach (var candidate in Candidates())
                    {
                        if (NativeLibrary.TryLoad(candidate, out var handle))
                        {
                            ResolvedPath = candidate;
                            return handle;
                        }
                    }
                    return IntPtr.Zero;   // fall back to the default probing
                });
        }
    }

    private static string FileName =>
        RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "htmlsanitizer.dll"
        : RuntimeInformation.IsOSPlatform(OSPlatform.OSX) ? "libhtmlsanitizer.dylib"
        : "libhtmlsanitizer.so";

    private static IEnumerable<string> Candidates()
    {
        if (_explicitPath is { Length: > 0 })
        {
            yield return _explicitPath;
            yield break;
        }

        var env = Environment.GetEnvironmentVariable("HTMLSANITIZER_LIB");
        if (!string.IsNullOrEmpty(env)) yield return env;

        var name = FileName;
        var dir = Path.GetDirectoryName(typeof(Native).Assembly.Location);
        if (!string.IsNullOrEmpty(dir))
        {
            yield return Path.Combine(dir, "native", name);
            yield return Path.Combine(dir, name);
        }

        var cwd = Directory.GetCurrentDirectory();
        yield return Path.Combine(cwd, "native", name);
        yield return Path.Combine(cwd, "..", "core", "native", name);
        yield return Path.Combine(cwd, "..", "..", "core", "native", name);
    }
}
