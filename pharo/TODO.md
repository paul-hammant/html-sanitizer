# Pharo layer — TODO

## Migrate `run-tests.sh` → `pharo.sunit` (LANDED in aeb)

**Status:** aeb's `pharo` SDK gained `sunit` (committed + pushed). The old
`lib/pharo` default literally shelled out to `./run-tests.sh`; that's replaced.
Rewrite `.tests.ae` and delete the script after the parity check.

### What the SDK now does

`pharo.sunit(b)` is the SDK-native form of `run-tests.sh`:

- **VM discovery** — `pharo` on PATH, else the usual layout under `$PHARO_DIR`
  (default `~/.local/pharo`). Image = the first `*.image` there or in the
  source dir. SKIP (green) when no VM or no image — nothing is ever downloaded
  (a runner that installs a VM behind your back is worse than a clear skip).
- **Works on a COPY** of the image (+ its `.changes`/`.sources`): loading code
  mutates a Pharo image permanently, so the developer's own image is never
  touched. The throwaway lives under `target/`, and Pharo's `PharoDebug.log` /
  `*.fuel` litter lands there, not in `pharo/`.
- **Loads the Tonel package straight from the working tree** via Metacello
  (`repository: tonel://<dir>`), then runs `test --junit-xml-output`.
- Pharo is a real uFFI, **not a JVM** — no Java classpath, only the sanitizer core
  `.so` via `env(...)`.

### Rewrite `pharo/.tests.ae`

```
import build
import pharo
import pharo (baseline, tonel_dir, suite)
import build (env)

aeb(cap) {
    b = build.start()
    lib = build.dep_artifact(b, "core/.build.ae", "shared_lib")
    pharo.sunit(b) {
        baseline("HtmlSanitizer")       // your BaselineOfHtmlSanitizer
        tonel_dir("src")                // Tonel sources (default "src")
        suite("HtmlSanitizer")          // SUnit category (default = baseline)
        env("HTMLSANITIZER_LIB", lib)   // the sanitizer core .so the uFFI binds
    }
}
```

### Parity to confirm before deleting the script

1. **`HTMLSANITIZER_LIB`** — the uFFI binding needs the sanitizer core `.so`; thread it
   via `env(...)`.
2. **The baseline name** — the SDK loads `BaselineOf<baseline>`; confirm your
   `src/BaselineOfHtmlSanitizer/` matches `baseline("HtmlSanitizer")`.
3. **The `--junit-xml-output` suite name** — defaults to the baseline; the
   script passed `HtmlSanitizer`. The SDK keys pass/fail off `test`'s exit code
   (non-zero = failures), same as the script.

### Cross-refs

- aeb `lib/pharo`: `sunit`, `baseline`/`tonel_dir`/`suite`, `_pharo_bin`/
  `_pharo_image` (discovery).
- aeb `lib/build`: `_record_skip`, `_env_export_prefix`.
