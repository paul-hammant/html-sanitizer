# Attestations — on-target conformance runs, keyed by SHA256

The release artifacts are cross-built on Linux (deterministic bytes), so a Linux
host cannot *run* the macOS/Windows/arm64 ones. On-target verification —
building a binding and running its conformance suite on real hardware — is done
out of band and recorded here, one line per (artifact, target, run), keyed by
the artifact's SHA256 so the claim is about exact bytes a user can re-hash.

The sanitizer core does no I/O, so coverage is not tiered: an attestation is
simply "the conformance suite passed against this hash on this OS/arch."

## Format

```
sha256=<hex>  artifact=libhtmlsanitizer-<tag>-<os>-<arch>.<ext>
target=<os>-<arch>  host=<box>  date=<YYYY-MM-DD>
suite=<what ran, e.g. python conformance + go conformance>
result=PASS            # PASS | FAIL
notes=<free text>
```

A verifier re-hashes the artifact they hold, matches `sha256`, and trusts the
`result` for that `target`.

## Records

_(none yet — no release has been cut. The first `release/publish.sh <tag>` run
produces the artifacts; attest them here once run on target hardware.)_
