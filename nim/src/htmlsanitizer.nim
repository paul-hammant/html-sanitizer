## htmlsanitizer — the Nim binding over the monorepo's one shared native sanitizer core.
##
## Clean HTML of constructs that can lead to Cross-Site Scripting (XSS).
##
## There is **no sanitizer logic in this file**, and there must never be any.
## Parsing, filtering, URL resolution and CSS handling all live in
## `core/htmlsanitizer.ae`; the C ABI over it is `core/embed.ae`, whose exports
## `--emit=lib` mangles to `aether_hs_embed_<name>`. Everything below is
## marshalling: Nim values in, C scalars and `cstring`s out, and back.
##
## Why `importc` + a real link, rather than `dynlib`/dlopen
## ========================================================
##
## Several bindings in this repo (Python/ctypes, Ruby/Fiddle, PHP/FFI) resolve
## the sanitizer core at run time so they can report a friendly error when it is
## missing. Nim is a compiled, statically-linked-by-default language, and the
## house style for that family (Go/cgo, Zig, Rust's `native.rs` aside) is to
## LINK. So we do: `{.passL.}` below points the linker at `nim/native` and
## `../core/native`, and bakes both in as `rpath` so an in-tree binary finds
## the `.so` with no `LD_LIBRARY_PATH`. `nim/.tests.ae` stages the sanitizer core
## artifact into `nim/native/` before compiling, exactly as `go/.tests.ae`
## does for cgo, so the link and the rpath resolve wherever `aeb` put it.
##
## The consequence to be aware of: the sanitizer core must exist at BUILD time, not
## just at run time. A missing `.so` is a link error, not a nice exception.
##
## The two ownership rules
## =======================
##
## 1. **Every `cstring` this ABI returns is caller-owned.** It was malloc'd by
##    `hs_raw_dup` on the C side and must be handed back to
##    `aether_hs_embed_free_string`. Nim will not do this for you: assigning a
##    `cstring` to a `string` *copies*, it does not adopt, so a forgotten free
##    is a silent leak. This is the single most common bug in a binding of this
##    ABI, so exactly one proc — `takeString` — is allowed to touch a returned
##    pointer, and it always frees. Grep this file: there is no other call to
##    `free_string`, and no returned pointer escapes `takeString`.
##
## 2. **Node and attribute pointers handed to a callback are borrowed.** They
##    are valid only for the duration of that callback — the DOM is freed when
##    `sanitize` returns. `Node` and `Attribute` below are therefore bare
##    `pointer` wrappers with no lifetime of their own; retaining one past the
##    callback is a use-after-free that Nim cannot catch for you.
##
## The `int`-not-`long` trap
## =========================
##
## The sanitizer core's codegen emits its closure calls as `int(*)(...)`. A host that
## declares those parameters as C `long` gets a 4-vs-8-byte mismatch on LP64:
## garbage `reason` values, and on some ABIs a corrupted argument register.
## Nim's `int` is pointer-sized (64-bit here) — it is `long`, not `int`. So
## every callback and every ABI proc below uses `cint` explicitly. Do not
## "simplify" one of them to `int`.
##
## The GC keepalive requirement
## ============================
##
## Registration hands the sanitizer core a raw C function pointer plus an opaque
## `user_data` pointer. We pass the `Sanitizer` ref itself as `user_data`, cast
## to `pointer` — that is how a `{.cdecl.}` trampoline, which has no closure
## environment of its own, finds the Nim-side handler to invoke.
##
## The sanitizer core keeps that pointer for as long as the hook is registered, but it
## is invisible to Nim's GC: as far as ORC/refc are concerned, nothing
## references the `Sanitizer`. If the last Nim reference goes out of scope the
## object is freed and the sanitizer core is left holding a dangling `user_data`. So
## `newSanitizer` calls `GC_ref` on itself and `close` calls the matching
## `GC_unref`. That also pins the object's address, which matters for any GC
## that could otherwise move it.
##
## The handlers themselves are ordinary Nim closures stored *in* the pinned
## `Sanitizer`, so they are reachable and stay alive with it.

import std/[algorithm, strutils, os]

# ---------------------------------------------------------------------------
# Linking
# ---------------------------------------------------------------------------
#
# Search nim/native first (where .tests.ae stages the artifact), then the
# in-tree core/native, and bake both in as rpath so the produced binary is
# runnable straight out of the build directory. `currentSourcePath` keeps this
# correct no matter what directory the compiler was invoked from.

const
  srcDir = currentSourcePath().parentDir()
  nativeDir = srcDir & "/../native"
  coreNativeDir = srcDir & "/../../core/native"

{.passL: "-L" & nativeDir & " -L" & coreNativeDir & " -lhtmlsanitizer" &
         " -Wl,-rpath," & nativeDir & " -Wl,-rpath," & coreNativeDir.}

# ---------------------------------------------------------------------------
# ABI constants — append only, never renumber (they are the wire format).
# ---------------------------------------------------------------------------

type
  ListKind* = enum ## Which of the six policy sets an operation addresses.
    ## The values ARE the ABI's `which` selector; an enum keeps callers from
    ## passing a bare `3` and meaning the wrong list.
    lkTags = 0
    lkAttributes = 1
    lkCssProperties = 2
    lkSchemes = 3
    lkClasses = 4
    lkUriAttributes = 5

  Reason* = enum ## Why the sanitizer core is about to remove something.
    rNotAllowedTag = 0
    rNotAllowedAttribute = 1
    rNotAllowedStyle = 2
    rNotAllowedUrlValue = 3
    rNotAllowedValue = 4
    rNotAllowedCssClass = 5
    rClassAttributeEmpty = 6
    rStyleAttributeEmpty = 7

  NodeKind* = enum ## `node.kind`. 0 is what a null node reports.
    nkNone = 0
    nkDocument = 1
    nkElement = 2
    nkText = 3
    nkComment = 4

  HtmlSanitizerError* = object of CatchableError ## Bad handle, or a string the
    ## ABI cannot carry.

# ---------------------------------------------------------------------------
# The 1:1 symbol table.
# ---------------------------------------------------------------------------
#
# Declared in the order core/embed.ae declares them, so the two can be diffed
# by eye. Every integer is `cint`; every returned string is `cstring` and is
# caller-owned (see rule 1).

# ---- lifecycle ----
proc hsNew(): pointer {.importc: "aether_hs_embed_new", cdecl.}
proc hsFree(h: pointer) {.importc: "aether_hs_embed_free", cdecl.}
proc hsFreeString(s: cstring) {.importc: "aether_hs_embed_free_string", cdecl.}

# ---- the main entry points ----
proc hsSanitize(h: pointer, html, baseUrl: cstring): cstring
  {.importc: "aether_hs_embed_sanitize", cdecl.}
proc hsSanitizeDocument(h: pointer, html, baseUrl: cstring): cstring
  {.importc: "aether_hs_embed_sanitize_document", cdecl.}

# ---- boolean flags (marshalled as cint, 0/1) ----
proc hsSetKeepChildNodes(h: pointer, on: cint)
  {.importc: "aether_hs_embed_set_keep_child_nodes", cdecl.}
proc hsGetKeepChildNodes(h: pointer): cint
  {.importc: "aether_hs_embed_get_keep_child_nodes", cdecl.}
proc hsSetAllowDataAttributes(h: pointer, on: cint)
  {.importc: "aether_hs_embed_set_allow_data_attributes", cdecl.}
proc hsGetAllowDataAttributes(h: pointer): cint
  {.importc: "aether_hs_embed_get_allow_data_attributes", cdecl.}

# ---- allow-list mutation ----
proc hsAllow(h: pointer, which: cint, item: cstring): cint
  {.importc: "aether_hs_embed_allow", cdecl.}
proc hsDisallow(h: pointer, which: cint, item: cstring): cint
  {.importc: "aether_hs_embed_disallow", cdecl.}
proc hsIsAllowed(h: pointer, which: cint, item: cstring): cint
  {.importc: "aether_hs_embed_is_allowed", cdecl.}
proc hsClear(h: pointer, which: cint): cint
  {.importc: "aether_hs_embed_clear", cdecl.}
proc hsCount(h: pointer, which: cint): cint
  {.importc: "aether_hs_embed_count", cdecl.}
proc hsItemAt(h: pointer, which, index: cint): cstring
  {.importc: "aether_hs_embed_item_at", cdecl.}

# ---- callback registration (fn pointer + opaque user_data; nil fn clears) ----
proc hsOnRemovingTag(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_removing_tag", cdecl.}
proc hsOnRemovingAttribute(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_removing_attribute", cdecl.}
proc hsOnRemovingStyle(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_removing_style", cdecl.}
proc hsOnRemovingComment(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_removing_comment", cdecl.}
proc hsOnPostProcessNode(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_post_process_node", cdecl.}
proc hsOnPostProcessDom(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_post_process_dom", cdecl.}
proc hsOnFilterUrl(h, fn, ud: pointer)
  {.importc: "aether_hs_embed_on_filter_url", cdecl.}

# ---- DOM accessors (borrowed pointers, valid only inside a callback) ----
proc hsNodeKind(n: pointer): cint {.importc: "aether_hs_embed_node_kind", cdecl.}
proc hsNodeName(n: pointer): cstring {.importc: "aether_hs_embed_node_name", cdecl.}
proc hsNodeValue(n: pointer): cstring {.importc: "aether_hs_embed_node_value", cdecl.}
proc hsNodeChildCount(n: pointer): cint
  {.importc: "aether_hs_embed_node_child_count", cdecl.}
proc hsNodeChildAt(n: pointer, index: cint): pointer
  {.importc: "aether_hs_embed_node_child_at", cdecl.}
proc hsNodeParent(n: pointer): pointer {.importc: "aether_hs_embed_node_parent", cdecl.}
proc hsNodeAttrCount(n: pointer): cint
  {.importc: "aether_hs_embed_node_attr_count", cdecl.}
proc hsNodeAttrAt(n: pointer, index: cint): pointer
  {.importc: "aether_hs_embed_node_attr_at", cdecl.}
proc hsAttrName(a: pointer): cstring {.importc: "aether_hs_embed_attr_name", cdecl.}
proc hsAttrValue(a: pointer): cstring {.importc: "aether_hs_embed_attr_value", cdecl.}
proc hsAttrSetValue(a: pointer, value: cstring)
  {.importc: "aether_hs_embed_attr_set_value", cdecl.}

# ---- version ----
proc hsAbiVersion(): cint {.importc: "aether_hs_embed_abi_version", cdecl.}

# ---- the sanitizer core's own strdup ----
#
# `on_filter_url` is the one hook that must hand the sanitizer core a malloc'd string
# it will then own and `free()`. That free comes from the sanitizer core's libc, so the
# malloc must too — a Nim-allocated buffer would be released by the wrong
# allocator. The sanitizer core already exports its own strdup for exactly this, so we
# use it rather than binding libc `malloc` separately. (Unmangled: it is plain
# C in core/_embed_support.c, not an Aether export.)
proc hsRawDup(s: cstring): cstring {.importc: "hs_raw_dup", cdecl.}

# ---------------------------------------------------------------------------
# String marshalling — the one place a returned pointer is allowed to live.
# ---------------------------------------------------------------------------

proc takeString(p: cstring): string =
  ## Copy an ABI-returned string into a Nim `string` and free the original
  ## through the ABI. **Every** `cstring` this library returns goes through
  ## here, and the pointer is dead the moment this returns.
  if p.isNil:
    return ""
  result = $p          # $ on a cstring copies the bytes into a Nim string
  hsFreeString(p)

proc readBorrowed(p: cstring): string {.inline.} =
  ## Read a `const char*` a callback was handed. NOT ours — never freed.
  if p.isNil: "" else: $p

proc checkNoNul(s: string) =
  ## Nim strings may contain NUL; C strings may not. Truncating silently is how
  ## a sanitizer binding turns `<div>\0<script>` into a bypass, so refuse.
  if s.find('\0') >= 0:
    raise newException(HtmlSanitizerError, "string contains an interior NUL byte")

# ---------------------------------------------------------------------------
# Node and Attribute — borrowed views, valid only inside a callback.
# ---------------------------------------------------------------------------

type
  Node* = object ## A borrowed DOM node. Do NOT retain past the callback.
    p*: pointer
  Attribute* = object ## A borrowed DOM attribute. Same lifetime rule.
    p*: pointer

proc kind*(n: Node): NodeKind =
  ## `nkDocument` | `nkElement` | `nkText` | `nkComment` (`nkNone` if null).
  NodeKind(hsNodeKind(n.p))

proc name*(n: Node): string =
  ## Lowercased tag name; `""` for anything that is not an element.
  takeString(hsNodeName(n.p))

proc value*(n: Node): string =
  ## Text/comment content; `""` for elements and documents.
  takeString(hsNodeValue(n.p))

proc childCount*(n: Node): int = int(hsNodeChildCount(n.p))

proc child*(n: Node, index: int): Node =
  ## Child at `index`; a null-pointer `Node` when out of range.
  Node(p: hsNodeChildAt(n.p, cint(index)))

proc children*(n: Node): seq[Node] =
  result = @[]
  for i in 0 ..< n.childCount:
    result.add n.child(i)

proc parent*(n: Node): Node =
  ## Parent node; a null-pointer `Node` at the root.
  Node(p: hsNodeParent(n.p))

proc isNil*(n: Node): bool = n.p.isNil
proc isNil*(a: Attribute): bool = a.p.isNil

proc attrCount*(n: Node): int = int(hsNodeAttrCount(n.p))

proc attr*(n: Node, index: int): Attribute =
  Attribute(p: hsNodeAttrAt(n.p, cint(index)))

proc attributes*(n: Node): seq[Attribute] =
  result = @[]
  for i in 0 ..< n.attrCount:
    result.add n.attr(i)

proc name*(a: Attribute): string = takeString(hsAttrName(a.p))
proc value*(a: Attribute): string = takeString(hsAttrValue(a.p))

proc `value=`*(a: Attribute, v: string) =
  ## Rewrite an attribute in place from inside a callback — e.g. canonicalise a
  ## URL rather than remove the attribute. The sanitizer core COPIES the bytes
  ## (`hs_embed_attr_set_value` does a `string.concat("", value)`), so handing
  ## it this transient Nim buffer is safe; it does not alias our memory.
  checkNoNul(v)
  hsAttrSetValue(a.p, v.cstring)

# ---------------------------------------------------------------------------
# Handler types
# ---------------------------------------------------------------------------
#
# The `Removing*` family returns `bool`, where **true CANCELS the removal**
# (keeps the node/attribute/property). That inversion trips people up, so the
# names say what happens rather than what is returned.

type
  RemovingTagHandler* = proc (node: Node, reason: Reason): bool {.closure.}
  RemovingAttributeHandler* =
    proc (elem: Node, attr: Attribute, reason: Reason): bool {.closure.}
  RemovingStyleHandler* =
    proc (elem: Node, name, value: string, reason: Reason): bool {.closure.}
  RemovingCommentHandler* = proc (node: Node): bool {.closure.}
  PostProcessHandler* = proc (node: Node) {.closure.}
  FilterUrlHandler* = proc (elem: Node, raw, resolved: string): string {.closure.}

  Sanitizer* = ref object
    ## A configured sanitizer. Wraps one native handle.
    ##
    ## NOT safe for concurrent use — the handle carries mutable policy and hook
    ## state. Use one per thread, or serialise access.
    ##
    ## This is a `ref` on purpose: its address is what the sanitizer core gets as
    ## `user_data`, and `GC_ref`/`GC_unref` pin it for exactly as long as the
    ## sanitizer core can call back into us.
    handle: pointer
    pinned: bool                      ## have we GC_ref'd ourselves?
    # The registered handlers. Storing them here is what keeps them alive: the
    # pinned Sanitizer is a GC root, so its closures (and anything they capture)
    # are reachable for as long as the sanitizer core may invoke them.
    onRemovingTagCb: RemovingTagHandler
    onRemovingAttributeCb: RemovingAttributeHandler
    onRemovingStyleCb: RemovingStyleHandler
    onRemovingCommentCb: RemovingCommentHandler
    onPostProcessNodeCb: PostProcessHandler
    onPostProcessDomCb: PostProcessHandler
    onFilterUrlCb: FilterUrlHandler

# ---------------------------------------------------------------------------
# The trampolines.
# ---------------------------------------------------------------------------
#
# These are the actual C function pointers the sanitizer core calls. They must be
# `{.cdecl.}` top-level procs: a Nim closure is a two-word (proc, env) pair and
# is NOT a C function pointer, which is the whole reason the ABI carries a
# separate `user_data`.
#
# Each recovers the Sanitizer by casting `ud` back — safe because `newSanitizer`
# GC_ref'd it, so the address is both alive and stable.
#
# Note the widths: `cint` in, `cint` out (see the int-not-long note at the top).
#
# A Nim exception escaping into C is undefined behaviour, so every trampoline
# swallows. `removing_*` defaults to 0 = "proceed with the removal", which is
# the fail-safe direction for a sanitizer: a broken handler must never cause
# dangerous markup to be *kept*.

proc ownerOf(ud: pointer): Sanitizer {.inline.} =
  cast[Sanitizer](ud)

proc trampRemovingTag(ud, node: pointer, reason: cint): cint {.cdecl.} =
  let s = ownerOf(ud)
  if s.isNil or s.onRemovingTagCb.isNil: return 0
  try:
    if s.onRemovingTagCb(Node(p: node), Reason(reason)): 1.cint else: 0.cint
  except CatchableError, Defect:
    0.cint

proc trampRemovingAttribute(ud, elem, attr: pointer, reason: cint): cint {.cdecl.} =
  let s = ownerOf(ud)
  if s.isNil or s.onRemovingAttributeCb.isNil: return 0
  try:
    if s.onRemovingAttributeCb(Node(p: elem), Attribute(p: attr), Reason(reason)):
      1.cint
    else:
      0.cint
  except CatchableError, Defect:
    0.cint

proc trampRemovingStyle(ud, elem: pointer, name, value: cstring,
                        reason: cint): cint {.cdecl.} =
  # FIVE parameters counting `ud` — the style hook is the odd one out, and
  # getting its arity wrong is a stack-argument corruption, not a compile error.
  let s = ownerOf(ud)
  if s.isNil or s.onRemovingStyleCb.isNil: return 0
  try:
    if s.onRemovingStyleCb(Node(p: elem), readBorrowed(name),
                           readBorrowed(value), Reason(reason)):
      1.cint
    else:
      0.cint
  except CatchableError, Defect:
    0.cint

proc trampRemovingComment(ud, node: pointer): cint {.cdecl.} =
  let s = ownerOf(ud)
  if s.isNil or s.onRemovingCommentCb.isNil: return 0
  try:
    if s.onRemovingCommentCb(Node(p: node)): 1.cint else: 0.cint
  except CatchableError, Defect:
    0.cint

proc trampPostProcessNode(ud, node: pointer) {.cdecl.} =
  let s = ownerOf(ud)
  if s.isNil or s.onPostProcessNodeCb.isNil: return
  try: s.onPostProcessNodeCb(Node(p: node))
  except CatchableError, Defect: discard

proc trampPostProcessDom(ud, node: pointer) {.cdecl.} =
  let s = ownerOf(ud)
  if s.isNil or s.onPostProcessDomCb.isNil: return
  try: s.onPostProcessDomCb(Node(p: node))
  except CatchableError, Defect: discard

proc trampFilterUrl(ud, elem: pointer, raw, resolved: cstring): cstring {.cdecl.} =
  ## The hardest shape: we must RETURN ownership of a string.
  ##
  ## Returning `resolved` unchanged is the ABI's "no rewrite" signal — the C
  ## trampoline compares pointers, so handing back the very pointer we were
  ## given costs no allocation and no copy. Anything else must be a fresh
  ## malloc'd buffer the sanitizer core will `free()`, which is why this goes through
  ## the sanitizer core's own `hs_raw_dup` and never through Nim's allocator.
  let s = ownerOf(ud)
  if s.isNil or s.onFilterUrlCb.isNil: return resolved
  try:
    let r = readBorrowed(resolved)
    let outv = s.onFilterUrlCb(Node(p: elem), readBorrowed(raw), r)
    if outv == r:
      return resolved                       # no rewrite: hand the original back
    if outv.find('\0') >= 0:
      # A callback cannot report an error to the sanitizer core, so truncate at the NUL
      # rather than smuggle a half-string across.
      return hsRawDup(outv[0 ..< outv.find('\0')].cstring)
    hsRawDup(outv.cstring)
  except CatchableError, Defect:
    resolved

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc close*(s: Sanitizer)

proc newSanitizer*(): Sanitizer =
  ## Create a sanitizer with the sanitizer core's secure defaults already populated.
  ##
  ## Pair with `close`, or use the `withSanitizer` template.
  new(result)
  result.handle = hsNew()
  if result.handle.isNil:
    raise newException(HtmlSanitizerError, "failed to create the native sanitizer")
  # Pin ourselves BEFORE any hook can be registered: from here on the sanitizer core
  # may be handed this address as `user_data`, and it must stay valid and
  # unmoved until `close` unpins it. See the GC keepalive note at the top.
  GC_ref(result)
  result.pinned = true

proc isClosed*(s: Sanitizer): bool =
  ## True once `close` has run. A closed sanitizer rejects every operation
  ## rather than dereferencing a freed handle.
  s.isNil or s.handle.isNil

proc checkOpen(s: Sanitizer) {.inline.} =
  if s.isClosed:
    raise newException(HtmlSanitizerError, "sanitizer is closed")

proc close*(s: Sanitizer) =
  ## Release the native handle. Idempotent.
  ##
  ## Order: free the handle, THEN drop the Nim-side closures, THEN drop the GC
  ## pin. The pin must go last — it may be the reference that frees `s`.
  ##
  ## DO NOT clear the hooks first. It looks like the tidy, defensive thing to
  ## do, and it is exactly wrong: `hs_embed_free` already disposes of a
  ## still-installed hook box correctly, whereas clearing one manually goes
  ## through `swap_hook` in core/embed.ae, whose replace path never frees the
  ## outgoing box. A clear-then-free therefore leaks one 16-byte box PER HOOK,
  ## while a plain free leaks none. Measured from pure C — see the
  ## "Known issues" table in the repo README.
  ##
  ## Nor is the clear needed for safety: the sanitizer core cannot invoke a hook after
  ## `hsFree` returns, and nothing calls into `s` in between.
  if s.isNil or s.handle.isNil:
    return
  let h = s.handle
  s.onRemovingTagCb = nil
  s.onRemovingAttributeCb = nil
  s.onRemovingStyleCb = nil
  s.onRemovingCommentCb = nil
  s.onPostProcessNodeCb = nil
  s.onPostProcessDomCb = nil
  s.onFilterUrlCb = nil
  s.handle = nil
  hsFree(h)
  if s.pinned:
    s.pinned = false
    GC_unref(s)   # must be LAST: this may be the reference that frees `s`

template withSanitizer*(name: untyped, body: untyped) =
  ## Scoped sanitizer — the Nim equivalent of Python's `with HtmlSanitizer()`.
  ##
  ## ```nim
  ## withSanitizer s:
  ##   echo s.sanitize("<div>hi<script>evil()</script></div>")
  ## ```
  let name = newSanitizer()
  try:
    body
  finally:
    name.close()

proc abiVersion*(): int =
  ## ABI revision of the linked sanitizer core. Bumped only when a symbol is ADDED.
  int(hsAbiVersion())

proc abiVersion*(s: Sanitizer): int = abiVersion()

# ---------------------------------------------------------------------------
# The main entry points
# ---------------------------------------------------------------------------

proc sanitize*(s: Sanitizer, html: string, baseUrl: string = ""): string =
  ## Sanitize an HTML fragment.
  ##
  ## `baseUrl` resolves relative URLs; `""` means "do not resolve".
  ## Raises `HtmlSanitizerError` on a closed sanitizer.
  checkOpen(s)
  checkNoNul(html)
  checkNoNul(baseUrl)
  takeString(hsSanitize(s.handle, html.cstring, baseUrl.cstring))

proc sanitizeDocument*(s: Sanitizer, html: string, baseUrl: string = ""): string =
  ## Sanitize a full HTML document. A distinct sanitizer core entry point from
  ## `sanitize`, even though the sanitizer core currently treats the two alike.
  checkOpen(s)
  checkNoNul(html)
  checkNoNul(baseUrl)
  takeString(hsSanitizeDocument(s.handle, html.cstring, baseUrl.cstring))

proc sanitize*(html: string, baseUrl: string = ""): string =
  ## One-shot convenience: create a sanitizer with the defaults, use it, drop
  ## it. Prefer a reused `Sanitizer` when policy is customised or the call is
  ## in a loop — this allocates and frees a native handle per call.
  withSanitizer s:
    result = s.sanitize(html, baseUrl)

proc sanitizeDocument*(html: string, baseUrl: string = ""): string =
  withSanitizer s:
    result = s.sanitizeDocument(html, baseUrl)

# ---------------------------------------------------------------------------
# Boolean flags (bool <-> cint 0/1)
# ---------------------------------------------------------------------------

proc `keepChildNodes=`*(s: Sanitizer, on: bool) =
  ## Keep the children of a removed element instead of dropping the subtree.
  checkOpen(s)
  hsSetKeepChildNodes(s.handle, if on: 1.cint else: 0.cint)

proc keepChildNodes*(s: Sanitizer): bool =
  checkOpen(s)
  hsGetKeepChildNodes(s.handle) != 0

proc `allowDataAttributes=`*(s: Sanitizer, on: bool) =
  ## Let `data-*` attributes through without listing each one.
  checkOpen(s)
  hsSetAllowDataAttributes(s.handle, if on: 1.cint else: 0.cint)

proc allowDataAttributes*(s: Sanitizer): bool =
  checkOpen(s)
  hsGetAllowDataAttributes(s.handle) != 0

# ---------------------------------------------------------------------------
# Policy lists
# ---------------------------------------------------------------------------
#
# Six parallel sets behind one `which` selector, exposed as a small set-like
# surface. `PolicyList` is a value holding the sanitizer plus the selector, so
# `s.allowedTags.add "x"` reads naturally without six near-identical families
# of procs.

type
  PolicyList* = object
    s: Sanitizer
    which: ListKind

proc list*(s: Sanitizer, which: ListKind): PolicyList = PolicyList(s: s, which: which)

proc allowedTags*(s: Sanitizer): PolicyList = s.list(lkTags)
proc allowedAttributes*(s: Sanitizer): PolicyList = s.list(lkAttributes)
proc allowedCssProperties*(s: Sanitizer): PolicyList = s.list(lkCssProperties)
proc allowedSchemes*(s: Sanitizer): PolicyList = s.list(lkSchemes)
proc allowedClasses*(s: Sanitizer): PolicyList = s.list(lkClasses)
proc uriAttributes*(s: Sanitizer): PolicyList = s.list(lkUriAttributes)

proc add*(l: PolicyList, item: string) =
  ## Allow `item`.
  checkOpen(l.s)
  checkNoNul(item)
  discard hsAllow(l.s.handle, cint(ord(l.which)), item.cstring)

proc add*(l: PolicyList, items: openArray[string]) =
  for it in items: l.add(it)

proc excl*(l: PolicyList, item: string) =
  ## Disallow `item` — the deny direction (e.g. drop `div` from the tags).
  checkOpen(l.s)
  checkNoNul(item)
  discard hsDisallow(l.s.handle, cint(ord(l.which)), item.cstring)

proc contains*(l: PolicyList, item: string): bool =
  ## Enables `"http" in s.allowedSchemes`.
  checkOpen(l.s)
  checkNoNul(item)
  hsIsAllowed(l.s.handle, cint(ord(l.which)), item.cstring) != 0

proc clear*(l: PolicyList) =
  ## Empty the list — the "start from nothing" move for a strict allow-list.
  checkOpen(l.s)
  discard hsClear(l.s.handle, cint(ord(l.which)))

proc len*(l: PolicyList): int =
  checkOpen(l.s)
  int(hsCount(l.s.handle, cint(ord(l.which))))

proc `[]`*(l: PolicyList, index: int): string =
  ## The item at `index` in the sanitizer core's own order; `""` when out of range.
  checkOpen(l.s)
  takeString(hsItemAt(l.s.handle, cint(ord(l.which)), cint(index)))

proc items*(l: PolicyList): seq[string] =
  ## Enumerate in the sanitizer core's own order — unspecified, but stable between
  ## mutations, so each item appears exactly once.
  ##
  ## Note this is O(n^2): the ABI snapshots the whole set per `item_at`. That
  ## is a deliberate ABI trade (no iterator handles to lifetime-manage) and
  ## these are configuration-time policy lists of at most a few hundred
  ## entries, not a hot path.
  let n = l.len
  result = newSeqOfCap[string](n)
  for i in 0 ..< n:
    result.add l[i]

proc sorted*(l: PolicyList): seq[string] =
  ## The deterministic version of `items`.
  result = l.items
  result.sort()

iterator pairsOf*(l: PolicyList): string =
  for it in l.items: yield it

# ---------------------------------------------------------------------------
# Hook registration
# ---------------------------------------------------------------------------
#
# Store the handler on the (pinned) Sanitizer, then register the trampoline
# with `s` itself as `user_data`. Passing `nil` for the handler clears the hook
# on both sides — we hand the sanitizer core a null fn, which is its documented
# "no callback" state.
#
# Each returns the Sanitizer so registrations chain.

proc onRemovingTag*(s: Sanitizer, h: RemovingTagHandler): Sanitizer {.discardable.} =
  ## Called before a disallowed tag is removed. **Return true to CANCEL the
  ## removal** and keep the tag.
  checkOpen(s)
  s.onRemovingTagCb = h
  if h.isNil:
    hsOnRemovingTag(s.handle, nil, nil)
  else:
    hsOnRemovingTag(s.handle, cast[pointer](trampRemovingTag), cast[pointer](s))
  s

proc onRemovingAttribute*(s: Sanitizer,
                          h: RemovingAttributeHandler): Sanitizer {.discardable.} =
  ## Return true to CANCEL the attribute's removal.
  checkOpen(s)
  s.onRemovingAttributeCb = h
  if h.isNil:
    hsOnRemovingAttribute(s.handle, nil, nil)
  else:
    hsOnRemovingAttribute(s.handle, cast[pointer](trampRemovingAttribute),
                          cast[pointer](s))
  s

proc onRemovingStyle*(s: Sanitizer, h: RemovingStyleHandler): Sanitizer {.discardable.} =
  ## The four-argument hook: element, property name, property value, reason.
  ## Return true to CANCEL the property's removal.
  checkOpen(s)
  s.onRemovingStyleCb = h
  if h.isNil:
    hsOnRemovingStyle(s.handle, nil, nil)
  else:
    hsOnRemovingStyle(s.handle, cast[pointer](trampRemovingStyle), cast[pointer](s))
  s

proc onRemovingComment*(s: Sanitizer,
                        h: RemovingCommentHandler): Sanitizer {.discardable.} =
  ## Return true to CANCEL the comment's removal (i.e. keep the comment).
  checkOpen(s)
  s.onRemovingCommentCb = h
  if h.isNil:
    hsOnRemovingComment(s.handle, nil, nil)
  else:
    hsOnRemovingComment(s.handle, cast[pointer](trampRemovingComment), cast[pointer](s))
  s

proc onPostProcessNode*(s: Sanitizer, h: PostProcessHandler): Sanitizer {.discardable.} =
  ## Called once per surviving node after filtering.
  checkOpen(s)
  s.onPostProcessNodeCb = h
  if h.isNil:
    hsOnPostProcessNode(s.handle, nil, nil)
  else:
    hsOnPostProcessNode(s.handle, cast[pointer](trampPostProcessNode), cast[pointer](s))
  s

proc onPostProcessDom*(s: Sanitizer, h: PostProcessHandler): Sanitizer {.discardable.} =
  ## Called once with the whole document node after filtering.
  checkOpen(s)
  s.onPostProcessDomCb = h
  if h.isNil:
    hsOnPostProcessDom(s.handle, nil, nil)
  else:
    hsOnPostProcessDom(s.handle, cast[pointer](trampPostProcessDom), cast[pointer](s))
  s

proc onFilterUrl*(s: Sanitizer, h: FilterUrlHandler): Sanitizer {.discardable.} =
  ## Called for every URI attribute. Return the URL to use — the `resolved`
  ## argument unchanged for "no rewrite", or `""` to drop the attribute. You do
  ## not manage the returned string's memory; the binding copies it into a
  ## buffer the sanitizer core takes ownership of.
  checkOpen(s)
  s.onFilterUrlCb = h
  if h.isNil:
    hsOnFilterUrl(s.handle, nil, nil)
  else:
    hsOnFilterUrl(s.handle, cast[pointer](trampFilterUrl), cast[pointer](s))
  s
