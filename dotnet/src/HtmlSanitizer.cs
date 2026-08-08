// The idiomatic C# surface over the HtmlSanitizer engine.
//
// Carries no sanitizer logic — every member here marshals to an
// aether_hs_embed_* call in Native.cs.

using System;
using System.Collections;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace HtmlSanitization;

/// <summary>
/// A DOM attribute, <b>borrowed</b> for the duration of a callback.
/// </summary>
/// <remarks>
/// Do not retain one past the callback that gave it to you — the DOM is freed
/// when <see cref="HtmlSanitizer.Sanitize"/> returns.
/// </remarks>
public readonly struct Attribute
{
    internal Attribute(IntPtr ptr) => Pointer = ptr;

    /// <summary>The raw borrowed pointer, for advanced interop.</summary>
    public IntPtr Pointer { get; }

    /// <summary>The attribute's name.</summary>
    public string Name => Native.TakeString(Native.AttrName(Pointer));

    /// <summary>The attribute's value.</summary>
    public string Value => Native.TakeString(Native.AttrValue(Pointer));

    /// <summary>
    /// Rewrite the value in place (e.g. to canonicalise a URL rather than
    /// remove the attribute). The engine copies the string, so the transient
    /// buffer is safe.
    /// </summary>
    public void SetValue(string value) =>
        Native.AttrSetValue(Pointer, Native.Encode(value));

    /// <inheritdoc/>
    public override string ToString() => $"Attribute({Name}={Value})";
}

/// <summary>A DOM node, <b>borrowed</b> for the duration of a callback.</summary>
public readonly struct Node
{
    internal Node(IntPtr ptr) => Pointer = ptr;

    /// <summary>The raw borrowed pointer, for advanced interop.</summary>
    public IntPtr Pointer { get; }

    /// <summary>Document, Element, Text or Comment.</summary>
    public NodeKind Kind => (NodeKind)Native.NodeKindOf(Pointer);

    /// <summary>Element tag name, lowercased by the parser; "" for non-elements.</summary>
    public string Name => Native.TakeString(Native.NodeName(Pointer));

    /// <summary>Text/comment content; "" for elements and documents.</summary>
    public string Value => Native.TakeString(Native.NodeValue(Pointer));

    /// <summary>The parent node, or null at the root.</summary>
    public Node? Parent
    {
        get
        {
            var p = Native.NodeParent(Pointer);
            return p == IntPtr.Zero ? null : new Node(p);
        }
    }

    /// <summary>How many child nodes this node has.</summary>
    public int ChildCount => Native.NodeChildCount(Pointer);

    /// <summary>The child at <paramref name="index"/>.</summary>
    public Node ChildAt(int index) => new(Native.NodeChildAt(Pointer, index));

    /// <summary>Every child node.</summary>
    public IReadOnlyList<Node> Children
    {
        get
        {
            int n = ChildCount;
            var list = new List<Node>(n);
            for (int i = 0; i < n; i++) list.Add(ChildAt(i));
            return list;
        }
    }

    /// <summary>How many attributes this element has.</summary>
    public int AttributeCount => Native.NodeAttrCount(Pointer);

    /// <summary>The attribute at <paramref name="index"/>.</summary>
    public Attribute AttributeAt(int index) => new(Native.NodeAttrAt(Pointer, index));

    /// <summary>Every attribute.</summary>
    public IReadOnlyList<Attribute> Attributes
    {
        get
        {
            int n = AttributeCount;
            var list = new List<Attribute>(n);
            for (int i = 0; i < n; i++) list.Add(AttributeAt(i));
            return list;
        }
    }

    /// <inheritdoc/>
    public override string ToString() => $"Node(Kind={Kind}, Name={Name})";
}

/// <summary>
/// A set-like view over one of the engine's six policy lists. Every operation
/// reads or writes the engine's own set — there is no managed mirror to fall
/// out of sync.
/// </summary>
public sealed class AllowList : IReadOnlyCollection<string>
{
    private readonly HtmlSanitizer _owner;
    private readonly int _which;

    internal AllowList(HtmlSanitizer owner, AllowListKind which)
    {
        _owner = owner;
        _which = (int)which;
    }

    /// <summary>Add one item. Returns this, so calls chain.</summary>
    public AllowList Add(string item)
    {
        Native.Allow(_owner.Handle, _which, Native.Encode(item));
        return this;
    }

    /// <summary>Add several items.</summary>
    public AllowList Add(params string[] items)
    {
        foreach (var i in items) Add(i);
        return this;
    }

    /// <summary>Add every item of a sequence.</summary>
    public AllowList AddRange(IEnumerable<string> items)
    {
        foreach (var i in items) Add(i);
        return this;
    }

    /// <summary>Remove one item — the "deny" direction.</summary>
    public AllowList Remove(string item)
    {
        Native.Disallow(_owner.Handle, _which, Native.Encode(item));
        return this;
    }

    /// <summary>Empty the list — the "start from nothing" move.</summary>
    public AllowList Clear()
    {
        Native.Clear(_owner.Handle, _which);
        return this;
    }

    /// <summary>Is <paramref name="item"/> currently allowed?</summary>
    public bool Contains(string item) =>
        Native.IsAllowed(_owner.Handle, _which, Native.Encode(item)) != 0;

    /// <inheritdoc/>
    public int Count => Native.Count(_owner.Handle, _which);

    /// <summary>The item at <paramref name="index"/>, or "" when out of range.</summary>
    public string this[int index] =>
        Native.TakeString(Native.ItemAt(_owner.Handle, _which, index));

    /// <inheritdoc/>
    public IEnumerator<string> GetEnumerator()
    {
        _owner.ThrowIfDisposed();
        int n = Count;
        for (int i = 0; i < n; i++) yield return this[i];
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    /// <summary>The items, sorted — the deterministic enumeration.</summary>
    public List<string> ToSortedList()
    {
        var list = new List<string>(this);
        list.Sort(StringComparer.Ordinal);
        return list;
    }

    /// <inheritdoc/>
    public override string ToString() => "{" + string.Join(", ", ToSortedList()) + "}";
}

/// <summary>Called before a disallowed tag is removed; return true to KEEP it.</summary>
public delegate bool RemovingTagHandler(Node node, RemovalReason reason);

/// <summary>Called before a disallowed attribute is removed; return true to KEEP it.</summary>
public delegate bool RemovingAttributeHandler(Node element, Attribute attribute, RemovalReason reason);

/// <summary>Called before a disallowed CSS property is removed; return true to KEEP it.</summary>
public delegate bool RemovingStyleHandler(Node element, string name, string value, RemovalReason reason);

/// <summary>Called before a comment is removed; return true to KEEP it.</summary>
public delegate bool RemovingCommentHandler(Node node);

/// <summary>Called for each node (or the document) after filtering.</summary>
public delegate void PostProcessHandler(Node node);

/// <summary>
/// Called for each URL-bearing attribute. Return the URL to use — the
/// <c>resolved</c> argument unchanged for no rewrite, or "" to drop the
/// attribute.
/// </summary>
public delegate string FilterUrlHandler(Node element, string raw, string resolved);

/// <summary>
/// Cleans HTML of constructs that can lead to Cross-Site Scripting (XSS).
/// </summary>
/// <remarks>
/// <code>
/// using var s = new HtmlSanitizer();
/// s.AllowedTags.Add("my-widget");
/// var clean = s.Sanitize("&lt;div onclick=\"evil()\"&gt;hi&lt;/div&gt;");
/// </code>
/// A sanitizer is <b>not</b> thread-safe — the native handle carries mutable
/// policy and hook state. Use one per thread, or guard it.
/// </remarks>
public sealed class HtmlSanitizer : IDisposable
{
    private IntPtr _handle;

    // Registered delegates must be kept alive for as long as the engine can
    // call them. A local delegate would be collected — or its marshalling stub
    // freed — and the process would crash on the next callback. This list is
    // the .NET equivalent of ctypes' keepalive list, and is cleared only in
    // Dispose, after aether_hs_embed_free has run.
    private readonly List<Delegate> _keepAlive = new();

    /// <summary>
    /// Create a sanitizer with the engine's secure defaults populated.
    /// </summary>
    /// <param name="nativeLibraryPath">
    /// An explicit engine path. Otherwise: $HTMLSANITIZER_LIB, then native/
    /// next to the assembly, then ../core/native/, then the OS loader.
    /// </param>
    public HtmlSanitizer(string? nativeLibraryPath = null)
    {
        Native.EnsureResolver(nativeLibraryPath);
        _handle = Native.New();
        if (_handle == IntPtr.Zero)
            throw new InvalidOperationException("failed to create the native sanitizer");

        AllowedTags = new AllowList(this, AllowListKind.Tags);
        AllowedAttributes = new AllowList(this, AllowListKind.Attributes);
        AllowedCssProperties = new AllowList(this, AllowListKind.CssProperties);
        AllowedSchemes = new AllowList(this, AllowListKind.Schemes);
        AllowedClasses = new AllowList(this, AllowListKind.Classes);
        UriAttributes = new AllowList(this, AllowListKind.UriAttributes);
    }

    internal IntPtr Handle
    {
        get
        {
            ThrowIfDisposed();
            return _handle;
        }
    }

    internal void ThrowIfDisposed()
    {
        if (_handle == IntPtr.Zero)
            throw new ObjectDisposedException(nameof(HtmlSanitizer));
    }

    /// <summary>The engine's allowed tag names.</summary>
    public AllowList AllowedTags { get; }

    /// <summary>The engine's allowed attribute names.</summary>
    public AllowList AllowedAttributes { get; }

    /// <summary>The engine's allowed CSS property names.</summary>
    public AllowList AllowedCssProperties { get; }

    /// <summary>The engine's allowed URL schemes.</summary>
    public AllowList AllowedSchemes { get; }

    /// <summary>The engine's allowed CSS class names.</summary>
    public AllowList AllowedClasses { get; }

    /// <summary>Which attributes the engine treats as carrying a URL.</summary>
    public AllowList UriAttributes { get; }

    /// <summary>Where the engine was loaded from, once known.</summary>
    public static string? NativeLibraryPath => Native.ResolvedPath;

    /// <summary>The engine's ABI revision.</summary>
    public static int AbiVersion
    {
        get
        {
            Native.EnsureResolver();
            return Native.AbiVersion();
        }
    }

    // ---- lifecycle ----

    /// <summary>Release the native handle. Idempotent.</summary>
    public void Dispose()
    {
        Release(disposing: true);
        GC.SuppressFinalize(this);
    }

    /// <summary>
    /// Backstop for a dropped sanitizer; <see cref="Dispose"/> is the way.
    /// </summary>
    ~HtmlSanitizer() => Release(disposing: false);

    /// <summary>
    /// The standard Dispose(bool) split. `disposing` is false when this runs
    /// from the finalizer, where touching another managed object is unsafe —
    /// it may already have been finalized. Freeing the native handle is always
    /// safe and is what actually matters; the keepalive list only needs
    /// clearing on the deterministic path, and if we are being finalized the
    /// GC is about to reclaim it regardless.
    /// </summary>
    private void Release(bool disposing)
    {
        if (_handle == IntPtr.Zero) return;
        var h = _handle;
        _handle = IntPtr.Zero;
        Native.Free(h);
        if (disposing)
        {
            // Only now is it certain the engine can no longer invoke a hook.
            _keepAlive.Clear();
        }
    }

    // ---- the main entry point ----

    /// <summary>
    /// Sanitize an HTML fragment. <paramref name="baseUrl"/> resolves relative
    /// URLs; pass "" (the default) for no resolution.
    /// </summary>
    public string Sanitize(string html, string baseUrl = "") =>
        Native.TakeString(Native.Sanitize(Handle, Native.Encode(html), Native.Encode(baseUrl)));

    /// <summary>Sanitize a full HTML document.</summary>
    public string SanitizeDocument(string html, string baseUrl = "") =>
        Native.TakeString(Native.SanitizeDocument(Handle, Native.Encode(html), Native.Encode(baseUrl)));

    // ---- flags ----

    /// <summary>Keep the children of a removed element instead of dropping the subtree.</summary>
    public bool KeepChildNodes
    {
        get => Native.GetKeepChildNodes(Handle) != 0;
        set => Native.SetKeepChildNodes(Handle, value ? 1 : 0);
    }

    /// <summary>Allow <c>data-*</c> attributes through without listing each one.</summary>
    public bool AllowDataAttributes
    {
        get => Native.GetAllowDataAttributes(Handle) != 0;
        set => Native.SetAllowDataAttributes(Handle, value ? 1 : 0);
    }

    // ---- callbacks ----
    //
    // Each On* returns this, so they chain; passing null clears the hook.
    // For the Removing* family, returning true from your handler CANCELS the
    // removal (keeps the node/attribute/property).

    /// <summary>
    /// Hand a trampoline (or null, to clear) to one of the ABI's seven
    /// <c>on_*</c> setters. The trampoline is added to the keepalive list
    /// BEFORE it is registered, so there is no window in which the engine
    /// holds a pointer to a collectable delegate.
    /// </summary>
    private HtmlSanitizer Register(
        Action<IntPtr, IntPtr, IntPtr> register,
        Delegate? trampoline)
    {
        ThrowIfDisposed();
        if (trampoline is null)
        {
            register(_handle, IntPtr.Zero, IntPtr.Zero);
            return this;
        }

        _keepAlive.Add(trampoline);
        // user_data is unused on the .NET side: the delegate already closes
        // over the handler, so there is nothing to look up. The engine's
        // trampoline still round-trips it.
        register(_handle, Marshal.GetFunctionPointerForDelegate(trampoline), IntPtr.Zero);
        return this;
    }

    /// <summary>Called before a disallowed tag is removed; return true to keep it.</summary>
    public HtmlSanitizer OnRemovingTag(RemovingTagHandler? handler)
    {
        if (handler is null) return Register(Native.OnRemovingTag, null);
        CbRemovingTag cb =
            (_, node, reason) => handler(new Node(node), (RemovalReason)reason) ? 1 : 0;
        return Register(Native.OnRemovingTag, cb);
    }

    /// <summary>Called before a disallowed attribute is removed; return true to keep it.</summary>
    public HtmlSanitizer OnRemovingAttribute(RemovingAttributeHandler? handler)
    {
        if (handler is null) return Register(Native.OnRemovingAttribute, null);
        CbRemovingAttribute cb =
            (_, elem, attr, reason) =>
                handler(new Node(elem), new Attribute(attr), (RemovalReason)reason) ? 1 : 0;
        return Register(Native.OnRemovingAttribute, cb);
    }

    /// <summary>Called before a disallowed CSS property is removed; return true to keep it.</summary>
    public HtmlSanitizer OnRemovingStyle(RemovingStyleHandler? handler)
    {
        if (handler is null) return Register(Native.OnRemovingStyle, null);
        CbRemovingStyle cb =
            (_, elem, name, value, reason) =>
                handler(new Node(elem), Native.BorrowString(name),
                        Native.BorrowString(value), (RemovalReason)reason) ? 1 : 0;
        return Register(Native.OnRemovingStyle, cb);
    }

    /// <summary>Called before a comment is removed; return true to keep it.</summary>
    public HtmlSanitizer OnRemovingComment(RemovingCommentHandler? handler)
    {
        if (handler is null) return Register(Native.OnRemovingComment, null);
        CbRemovingComment cb = (_, node) => handler(new Node(node)) ? 1 : 0;
        return Register(Native.OnRemovingComment, cb);
    }

    /// <summary>Called for each node after it has been filtered.</summary>
    public HtmlSanitizer OnPostProcessNode(PostProcessHandler? handler)
    {
        if (handler is null) return Register(Native.OnPostProcessNode, null);
        CbPostProcess cb = (_, node) => handler(new Node(node));
        return Register(Native.OnPostProcessNode, cb);
    }

    /// <summary>Called once with the whole document after filtering.</summary>
    public HtmlSanitizer OnPostProcessDom(PostProcessHandler? handler)
    {
        if (handler is null) return Register(Native.OnPostProcessDom, null);
        CbPostProcess cb = (_, doc) => handler(new Node(doc));
        return Register(Native.OnPostProcessDom, cb);
    }

    /// <summary>
    /// Called for each URL-bearing attribute. The returned string is copied
    /// into a malloc'd C buffer the engine takes ownership of — you do not
    /// free it.
    /// </summary>
    public HtmlSanitizer OnFilterUrl(FilterUrlHandler? handler)
    {
        if (handler is null) return Register(Native.OnFilterUrl, null);
        CbFilterUrl cb = (_, elem, raw, resolved) => Native.StrDup(
            handler(new Node(elem), Native.BorrowString(raw),
                    Native.BorrowString(resolved)));
        return Register(Native.OnFilterUrl, cb);
    }

    // ---- one-shots ----

    /// <summary>Sanitize <paramref name="html"/> with the engine's defaults.</summary>
    public static string SanitizeOnce(string html, string baseUrl = "")
    {
        using var s = new HtmlSanitizer();
        return s.Sanitize(html, baseUrl);
    }

    /// <summary>Sanitize a full document with the engine's defaults.</summary>
    public static string SanitizeDocumentOnce(string html, string baseUrl = "")
    {
        using var s = new HtmlSanitizer();
        return s.SanitizeDocument(html, baseUrl);
    }
}
