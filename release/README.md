# release — cross-built sanitizer core artifacts

The sanitizer core (`libhtmlsanitizer`) is pure Aether, so it **cross-compiles
for the whole platform matrix from one Linux host** — no per-OS runner. This
directory builds those artifacts, checksums them, and cuts a GitHub release that
the FFI bindings fetch by hash.

Unlike a networked engine, the sanitizer core is a pure string→string transform
(no network, no filesystem, no OS access — see [`../core/.build.ae`](../core/.build.ae)),
so every cross-built artifact is fully functional on its target with **no
platform caveats** — nothing to attest beyond "the conformance suite passes on
this OS/arch."

## Build

```sh
release/build.sh                        # core matrix: linux + macos, x86_64 + arm64
RELEASE_TAG=v1.2.3 release/build.sh     # stamp a tag into the artifact names
RELEASE_EXTRA_TARGETS=1 release/build.sh  # + windows (slow) + freebsd (needs AETHER_SYSROOT)
TARGETS="aarch64-macos" release/build.sh  # just one
```

Needs `ae` + `zig` on PATH (run `./bootstrap.sh` first) and `sha256sum`.
Outputs into `release/dist/` (gitignored):

- `libhtmlsanitizer-<tag>-<os>-<arch>.{so,dylib,dll}` — the artifact
- `<artifact>.sha256` — its checksum (sidecar)
- `SHA256SUMS.txt` — all artifacts in one manifest

Each is stripped (`--size`). `so`=linux ELF, `dylib`=macOS Mach-O, `dll`=Windows PE.

The tag comes from `RELEASE_TAG`, else the repo-root
[`HTMLSANITIZER_VERSION`](../HTMLSANITIZER_VERSION) file, else `git describe`.
`HTMLSANITIZER_VERSION` is the single source of truth a fetch node would read, so
there is no per-binding tag literal to drift.

**Windows / FreeBSD** are opt-in (`RELEASE_EXTRA_TARGETS=1`). Windows cross-builds
to real PE DLLs (plus a `<dll>.lib` import library, shipped + checksummed for
build-time linkers; our FFI bindings `dlopen` at runtime and don't need it).
FreeBSD needs `AETHER_SYSROOT` and skips loudly without it.

## Cut a GitHub release (manual, no repo settings needed)

```sh
release/publish.sh v1.2.3            # build the matrix + create the release, assets attached
release/publish.sh v1.2.3 --draft    # create as a draft to review first
release/publish.sh v1.2.3 --no-build # attach whatever is already in release/dist
```

`publish.sh` builds (unless `--no-build`), then `gh release create <tag>` with
every artifact, its `.sha256`, and `SHA256SUMS.txt`. It uses your existing `gh`
auth — **nothing in GitHub Settings, no Actions, no secrets.** It refuses to
build from a dirty *tracked* tree, so the tagged source and the built binaries
are the same code.

(Registry publishing — PyPI/npm/Maven/… — is deliberately out of scope; that
needs per-registry secrets. This ships the sanitizer core artifact — the one
thing that's hard for a user to produce — first.)

## Why build-here / run-elsewhere

The build is deterministic and platform-agnostic (zig cross-compiles the exact
bytes every time), so building on Linux and running on the target are testing
*identical bytes* — no "works on my machine" gap. A Linux host can't *run* an
arm64-macOS binary, so on-target verification (running a binding's conformance
suite on real hardware) is done out of band and, if you want a durable record,
noted in [`ATTESTATIONS.md`](ATTESTATIONS.md) keyed by SHA256.

Because the sanitizer core does no I/O, "passed" here means the full conformance
suite passed against that exact hash on that OS/arch — there are no partial
coverage tiers (no TLS, no drivers, nothing environment-dependent).

## Consuming a release (future)

Once releases exist, a binding's package can be built against the *fetched*
prebuilt lib instead of compiling the core from source, via aeb's `--overrideDep`
and a `core/.getFromGitHubReleases.ae` fetch node (the pattern in the sibling
`selenium` repo's `docs/Prebuilt-Engine-Packaging.md`). That node is **not built
yet** — it is the next step once the first release is cut. A green build under
`--overrideDep` does not by itself prove the override took (a fetch-cache
fallback can satisfy it); the real proof is the shipped `.so`'s checksum matching
the release.

## Not here yet

- **A fetch node** (`core/.getFromGitHubReleases.ae`) — follow-up, once a release
  with these assets exists to fetch.
- **Binding packages** (wheel/gem/jar/nupkg/…) as release assets — the
  `.package.ae` nodes build these with the `.so` bundled; staging them as release
  assets is a later step.
- **Registry publish** (PyPI/Maven/npm/…) — a separate credentialed step.
