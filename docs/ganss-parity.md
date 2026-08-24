# Parity with the C# HtmlSanitizer test suite

This engine is a port of Michael Ganss's C#
[HtmlSanitizer](https://github.com/mganss/HtmlSanitizer). That project's test
suite encodes a decade of XSS bypass reports, which makes it the most valuable
thing we can borrow — far more so than its source.

`core_tests/test_ganss_parity.ae` is that suite, machine-translated into
`std.spec` by `tools/port_ganss_tests.py`. **Do not hand-edit the `.ae`** —
regenerate it:

```sh
python3 tools/port_ganss_tests.py          # expects ../HtmlSanitizer
GANSS_SRC=/path/to/Tests.cs python3 tools/port_ganss_tests.py
```

## The score

| | count |
|---|---|
| upstream `[Fact]`s | 252 |
| upstream `[Theory]` rows ported | 25 |
| **ported and running** | **189** |
| skipped by the porter | 99 |
| **passing** | **153** |
| **failing** | **36** |

`core_tests/.ganss.ae` runs the suite on every build. It does **not** demand
green — it fails only if the failure count exceeds the recorded baseline, so a
regression is loud while the known gap stays visible. Lower `BASELINE_FAILING`
as gaps close.

## Why generated, and why conservative

Hand-copying 185 adversarial HTML strings invites transcription errors in
exactly the place where one wrong byte silently weakens a security test. The
porter therefore emits a test **only** when its input, configuration and
expectation are all resolvable to literals, and skips everything else *with a
reason*. It can under-claim coverage; it cannot over-claim it.

Skips, by cause:

| count | reason |
|---|---|
| 31 | event wiring — needs the C ABI callback layer to be driven from Aether |
| 3 | multiple `Sanitize` calls that are not a resolvable sequence |
| 7 | options-object construction not modelled |
| 7 | argument is not a resolvable string literal |
| 5 | substring/predicate assertions (`Assert.Contains` etc.) |
| 5 | loop in the test body |
| 5 | AngleSharp DOM API not portable |
| 19 | assorted (see the porter's stderr manifest) |

## The 36 failures — all triaged, none a security hole

**All 101** were re-run and classified by whether an **executable sink**
survives: a live scheme in a URL attribute, an `on*` handler, or a
`<script>`/`<iframe>`/`<object>`/`<embed>` element. Not a sample — the triage
script regenerates a probe covering every failing case.

**98 are inert output-shape differences**, and they cluster tightly. Every
failing case now prints `expected` vs `got`, so the shape is measured rather
than guessed:

| count | pattern |
|---|---|
| ~62 | **we escape a malformed/obfuscated value and keep the attribute; C# drops it.** `<img src="`javascript:...">`, `&amp;#x6a...` (we double-escape the entity instead of decoding it, recognising `javascript:`, and dropping), `style="background-color: expression(&lt;script..."` |
| 25 | **over-escaping quotes** in attribute values (`&#x27;`, `&quot;` where C# keeps the literal) |
| 7 | **trailing `;`** in a serialized `style` attribute |
| 4 | C# strips everything, we keep some |
| 3 | we strip everything, C# keeps some |

The first two are one root cause: when a URL or CSS value is malformed or
entity-obfuscated, **C# drops the attribute and we escape it**. Escaping is
what makes our output inert — the value no longer starts with a scheme, so a
browser's URL parser will not execute it — but dropping is strictly stronger,
and fixing it would move the majority of the 101 at once.

**3 were flagged by the classifier and cleared on inspection:**

- `NoScriptTest`, `Bypass3Test` — the payload is HTML-escaped (`&amp;lt;`,
  `&lt;`). The classifier matched `onerror=` *inside escaped text*. Inert.
- `StyleByPassTest` — the one worth stating plainly. The output keeps
  `\3c /style>\3c img src onerror=alert(1)>` raw inside `<style>`; a browser
  decodes those CSS hex escapes to `</style>` and breaks out. **However:**
  C# produces materially the same output (its expectation in `Tests.cs`
  retains the same escape sequence; the diff is only CSS re-formatting, since
  it parses the stylesheet and we do not), *and* `style` is not in our default
  allow-list. Under default policy our output for that input is `aaabc` —
  fully stripped. It is reachable only if a caller explicitly opts into
  `<style>`, and it is not a regression against upstream.

The XSS-specific gate remains `core_tests/.xss.ae` (47 evasion techniques,
independent of this suite).

## A correction worth recording

An earlier version of this doc (and the root README) said
`DisallowCssPropertyValue` was "declared but never wired up". **That was
wrong.** The engine wires it fully — `sanitize_css_style_attribute` consults
`disallow_css_property_value_regex` and drops matching declarations. Verified:
with `^rgba\(0.*` set, `color: rgba(0, 0, 0, 1)` is removed and
`background-color: rgba(255, 255, 255, 1)` is kept, exactly as C# does.

What is actually missing is a **C ABI setter** — there is no way to hand a
compiled `std.regex` across the FFI, so the feature is reachable from Aether
but not from any of the 23 bindings. That is a binding-surface gap, not an
engine gap, and the distinction matters: the sanitizing logic is correct and
tested, it just cannot be configured from outside.

The one ported test for it (`DisallowCssPropertyValueTest`) now runs, and
fails only on a trailing semicolon in our CSS serialization
(`background-color: rgba(255, 255, 255, 1);` vs C#'s no-semicolon form).

## What would move the number most

1. **Drop malformed URL attributes instead of escaping them** — the single
   biggest cluster of the 101 — roughly 87 of them between the two.
2. **`<style>` CSS parsing** — unlocks `FilterCssRule` / `RemovingAtRule` and
   would let us re-format rather than pass through.
3. **Drive the callbacks from Aether tests** — recovers 31 skips; the C ABI
   already supports them (`core_tests/abi_smoke.c` exercises all six shapes),
   they just are not reachable from a pure-Aether spec today.

## Licence

The test vectors are upstream's: portions copyright (c) 2013-2016 Michael
Ganss and the original C# HtmlSanitizer contributors, MIT. See `LICENSE`.
