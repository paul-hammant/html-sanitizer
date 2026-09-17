#!/usr/bin/env python3
"""Port Michael Ganss's C# HtmlSanitizer xUnit tests to Aether std.spec.

Deliberately conservative: a test is emitted ONLY when its whole body is
understood. Anything with control flow, event wiring, AngleSharp document
manipulation, or an assertion shape we can't map is SKIPPED and reported, so
the output can never silently claim coverage it doesn't have.

Reads:  ../HtmlSanitizer/test/HtmlSanitizer.Tests/Tests.cs
Writes: core_tests/test_ganss_parity.ae  (+ a skip manifest on stderr)
"""
import re
import sys
import json

import os

# The upstream C# checkout. Override with GANSS_SRC when it lives elsewhere.
SRC = os.environ.get(
    "GANSS_SRC",
    os.path.join(os.path.dirname(os.path.abspath(__file__)),
                 "..", "..", "HtmlSanitizer",
                 "test", "HtmlSanitizer.Tests", "Tests.cs"))


def cs_string_to_aether(lit):
    """Convert a C# string literal (verbatim or regular) to an Aether literal.

    Returns None when the literal uses a C# feature we won't guess at
    (interpolation, char escapes we don't model).
    """
    lit = lit.strip()
    if lit.startswith('@"'):
        # verbatim: only "" is an escape, everything else is literal
        body = lit[2:-1]
        body = body.replace('""', '"')
        raw = body
    elif lit.startswith('"'):
        body = lit[1:-1]
        # unescape the C# escapes we understand
        out, i = [], 0
        while i < len(body):
            c = body[i]
            if c == '\\' and i + 1 < len(body):
                n = body[i + 1]
                mapping = {'"': '"', '\\': '\\', 'n': '\n', 'r': '\r',
                           't': '\t', '0': '\0', "'": "'"}
                if n in mapping:
                    out.append(mapping[n])
                    i += 2
                    continue
                if n == 'u' and i + 5 < len(body):
                    out.append(chr(int(body[i + 2:i + 6], 16)))
                    i += 6
                    continue
                return None          # unknown escape — don't guess
            out.append(c)
            i += 1
        raw = ''.join(out)
    else:
        return None

    # Aether literal: escape backslash and quote; reject embedded control
    # characters we can't express inline (NUL especially — it breaks the lexer,
    # learned the hard way porting the XSS vectors).
    if '\0' in raw:
        return None
    esc = raw.replace('\\', '\\\\').replace('"', '\\"')
    esc = esc.replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')
    # ${...} is Aether string interpolation — neutralise it
    if '${' in esc:
        return None
    return '"' + esc + '"'


# --- config setters we can express on our sanitizer core -------------------------
# C# property -> (kind, aether statement template)
SET_BOOL = {
    'KeepChildNodes': 's.keep_child_nodes = {v}',
    'AllowDataAttributes': 's.allow_data_attributes = {v}',
}
SET_ADD = {
    'AllowedTags': 'set.add(s.allowed_tags, {v})',
    'AllowedAttributes': 'set.add(s.allowed_attributes, {v})',
    'AllowedCssProperties': 'set.add(s.allowed_css_properties, {v})',
    'AllowedSchemes': 'set.add(s.allowed_schemes, {v})',
    'AllowedClasses': 'set.add(s.allowed_classes, {v})',
    'UriAttributes': 'set.add(s.uri_attributes, {v})',
}
SET_REMOVE = {
    'AllowedTags': 'set.remove(s.allowed_tags, {v})',
    'AllowedAttributes': 'set.remove(s.allowed_attributes, {v})',
    'AllowedCssProperties': 'set.remove(s.allowed_css_properties, {v})',
    'AllowedSchemes': 'set.remove(s.allowed_schemes, {v})',
    'AllowedClasses': 'set.remove(s.allowed_classes, {v})',
    'UriAttributes': 'set.remove(s.uri_attributes, {v})',
}
SET_CLEAR = {
    'AllowedTags': 'set.clear(s.allowed_tags)',
    'AllowedAttributes': 'set.clear(s.allowed_attributes)',
    'AllowedCssProperties': 'set.clear(s.allowed_css_properties)',
    'AllowedSchemes': 'set.clear(s.allowed_schemes)',
    'AllowedClasses': 'set.clear(s.allowed_classes)',
    'UriAttributes': 'set.clear(s.uri_attributes)',
}

# Anything mentioning these means the test exercises a feature we do not have
# or a shape we don't model. Skip with the reason, don't fudge.
UNSUPPORTED = {
    'UriListAttributes': 'UriListAttributes not implemented (comma-separated URL lists)',
    'SanitizeFragment': 'SanitizeFragment(context) not implemented',
    'SanitizeDom': 'SanitizeDom over an AngleSharp document not portable',
    'PostProcessDom': 'event wiring — needs the C ABI callback layer',
    'PostProcessNode': 'event wiring — needs the C ABI callback layer',
    'RemovingTag': 'event wiring — needs the C ABI callback layer',
    'RemovingAttribute': 'event wiring — needs the C ABI callback layer',
    'RemovingStyle': 'event wiring — needs the C ABI callback layer',
    'RemovingAtRule': 'RemovingAtRule / CSS at-rules not implemented',
    'RemovingComment': 'event wiring — needs the C ABI callback layer',
    'RemovingCssClass': 'on_removing_css_class is declared but never fired',
    'FilterUrl': 'event wiring — needs the C ABI callback layer',
    'FilterCssRule': 'FilterCssRule / <style> CSS parsing not implemented',
    'outputFormatter': 'pluggable output formatter not implemented',
    'IMarkupFormatter': 'pluggable output formatter not implemented',
    'HtmlSanitizerOptions': 'options-object construction not modelled',
    'StyleSheet': '<style> CSS parsing not implemented',
    'AngleSharp': 'AngleSharp DOM API not portable',
    'Assert.Throws': 'exception assertion has no analogue',
    'Assert.Contains': 'substring assertion — port separately if wanted',
    'Assert.DoesNotContain': 'substring assertion — port separately if wanted',
    'Assert.True': 'predicate assertion — port separately if wanted',
    'Assert.False': 'predicate assertion — port separately if wanted',
    'Assert.Null': 'null assertion has no analogue here',
    'Assert.NotNull': 'null assertion has no analogue here',
    'Assert.Empty': 'emptiness assertion — port separately if wanted',
    'foreach': 'loop in test body — not a single input/expected pair',
    'for (': 'loop in test body — not a single input/expected pair',
    'while (': 'loop in test body — not a single input/expected pair',
    # NB: bare `new HtmlSanitizer()` is fine — that is our default sanitizer.
    # Only a constructor with ARGUMENTS carries config we do not model; that
    # is matched separately below, not by this substring table.
}


def parse_sequential(body, theory_param=None):
    """Walk a test body statement-by-statement, tracking string variables, and
    emit (call, expected, ignore_case) for each Assert.Equal encountered.

    Models the upstream idiom of reassigning `html` / `actual` / `expected`
    between assertions. Returns [] when anything in the body is not one of the
    handful of statement shapes we model — never a partial result, because a
    half-walked body would silently drop vectors.
    """
    env = {}
    pending_call = None
    out = []

    stmt_re = re.compile(r'([^;{}]+);')
    for raw in stmt_re.findall(body):
        st = raw.strip()
        if not st or st.startswith('//'):
            continue

        # var x = "literal"  /  x = "literal"
        m = re.match(r'(?:string|var)?\s*(\w+)\s*=\s*(@?"(?:[^"\\]|\\.|"")*")$', st)
        if m:
            lit = cs_string_to_aether(m.group(2))
            if lit is None:
                return []
            env[m.group(1)] = lit
            continue

        # var actual = sanitizer.Sanitize(html[, base])
        m = re.match(r'(?:string|var)?\s*(\w+)\s*=\s*\w+\.(Sanitize|SanitizeDocument)'
                     r'\(\s*(\w+|@?"(?:[^"\\]|\\.|"")*")'
                     r'(?:\s*,\s*(\w+|@?"(?:[^"\\]|\\.|"")*"))?\s*\)$', st)
        if m:
            def rz(tok):
                if tok is None:
                    return '""'
                tok = tok.strip()
                if tok.startswith('"') or tok.startswith('@"'):
                    return cs_string_to_aether(tok)
                return env.get(tok)
            h, b2 = rz(m.group(3)), rz(m.group(4))
            if h is None or b2 is None:
                return []
            pending_call = (m.group(2), h, b2)
            env[m.group(1)] = None           # holds a sanitize result
            continue

        # var sanitizer = Sanitizer  (the xUnit fixture) — ignore
        if re.match(r'(?:var|HtmlSanitizer)\s+\w+\s*=\s*(Sanitizer|new HtmlSanitizer\(\))$', st):
            continue

        # Assert.Equal(expected, actual[, ignoreCase: true])
        m = re.match(r'Assert\.Equal\(\s*(\w+|@?"(?:[^"\\]|\\.|"")*")\s*,\s*(.+?)'
                     r'(?:,\s*ignoreCase:\s*(true|false))?\s*\)$', st, re.S)
        if m:
            exp_tok, actual_tok, ic = m.group(1), m.group(2).strip(), m.group(3) == 'true'
            exp = (cs_string_to_aether(exp_tok)
                   if exp_tok.startswith('"') or exp_tok.startswith('@"')
                   else env.get(exp_tok))
            if exp is None:
                return []
            # actual may be a variable holding a prior result, or an inline call
            call = pending_call
            im = re.match(r'\w+\.(Sanitize|SanitizeDocument)\(\s*(\w+|@?"(?:[^"\\]|\\.|"")*")'
                          r'(?:\s*,\s*(\w+|@?"(?:[^"\\]|\\.|"")*"))?\s*\)$', actual_tok)
            if im:
                def rz2(tok):
                    if tok is None:
                        return '""'
                    tok = tok.strip()
                    if tok.startswith('"') or tok.startswith('@"'):
                        return cs_string_to_aether(tok)
                    return env.get(tok)
                h, b2 = rz2(im.group(2)), rz2(im.group(3))
                if h is None or b2 is None:
                    return []
                call = (im.group(1), h, b2)
            if call is None:
                return []
            out.append((call, exp, ic))
            continue

        return []      # an unmodelled statement — bail rather than half-walk

    return out


def parse_body(name, body, theory_param=None):
    """Return (setup, call, expected, ignore_case) or ('skip', reason).

    `theory_param` names the [Theory] method's single parameter; a Sanitize
    argument matching it resolves to the sentinel '@ROW@', which the caller
    substitutes per [InlineData] row.
    """
    for marker, reason in UNSUPPORTED.items():
        if marker in body:
            return ('skip', reason)

    # `new HtmlSanitizer { AllowDataAttributes = true }` (possibly multi-line,
    # possibly alongside other settings we handle). Lift the boolean out into
    # setup and neutralise the initialiser so the constructor check below sees
    # a bare `new HtmlSanitizer()`.
    dat = re.search(r'new HtmlSanitizer\s*\(?\s*\)?\s*\{\s*'
                    r'AllowDataAttributes\s*=\s*(true|false)\s*,?\s*\}', body, re.S)
    if dat:
        setup_pre_dat = ['s.allow_data_attributes = %s' % dat.group(1)]
        body = body[:dat.start()] + 'new HtmlSanitizer()' + body[dat.end():]
    else:
        setup_pre_dat = []

    # `new HtmlSanitizer { AllowCssCustomProperties = true }` — equivalent to
    # our default. We allow `--custom` properties unconditionally, so a test
    # that turns the flag ON matches our behaviour exactly. (Every upstream
    # test sets it true; none sets it false. If one ever does, it will fall
    # through to the configured-constructor skip below rather than be
    # mis-ported, because this only strips the `= true` form.)
    body = re.sub(r'new HtmlSanitizer\s*\{\s*AllowCssCustomProperties\s*=\s*true\s*\}',
                  'new HtmlSanitizer()', body)

    # `new HtmlSanitizer { DisallowCssPropertyValue = new Regex(@"...") }` —
    # an object initialiser we CAN model: the sanitizer core's
    # disallow_css_property_value_regex is fully wired (setting it drops
    # matching declarations), it is just not reachable over the C ABI.
    dis = re.search(
        r'new HtmlSanitizer\s*\{\s*DisallowCssPropertyValue\s*=\s*'
        r'new Regex\(\s*(@?"(?:[^"\\]|\\.|"")*")\s*\)\s*\}', body)
    if dis:
        pat_lit = cs_string_to_aether(dis.group(1))
        if pat_lit is None:
            return ('skip', 'unconvertible DisallowCssPropertyValue pattern')
        setup_pre = ['rx, _rxe = regex.compile(%s)' % pat_lit,
                     's.disallow_css_property_value_regex = rx']
        body = body[:dis.start()] + 'new HtmlSanitizer()' + body[dis.end():]
    else:
        setup_pre = []

    # A constructor with arguments configures the sanitizer in ways we do not
    # model; a bare `new HtmlSanitizer()` is exactly our default.
    if re.search(r'new HtmlSanitizer\(\s*[^)\s]', body):
        return ('skip', 'constructs a CONFIGURED sanitizer — config not modelled')

    setup = list(setup_pre) + list(setup_pre_dat)

    # CreateUriListSanitizer("srcset") is a test helper that news a default
    # sanitizer and adds ONE attribute to AllowedAttributes. Model it directly
    # rather than skipping every uri-list test.
    for m in re.finditer(r'CreateUriListSanitizer\(\s*(@?"(?:[^"\\]|\\.|"")*")\s*\)', body):
        lit = cs_string_to_aether(m.group(1))
        if lit is None:
            return ('skip', 'unconvertible CreateUriListSanitizer argument')
        setup.append('set.add(s.allowed_attributes, %s)' % lit)
    # sanitizer.AllowedTags.Add("x") / .Remove("x") / .Clear() / .UnionWith(...)
    for prop, tmpl in SET_ADD.items():
        for m in re.finditer(r'\.%s\.Add\((@?"(?:[^"\\]|\\.|"")*")\)' % prop, body):
            lit = cs_string_to_aether(m.group(1))
            if lit is None:
                return ('skip', 'unconvertible string in %s.Add' % prop)
            setup.append(tmpl.format(v=lit))
    for prop, tmpl in SET_REMOVE.items():
        for m in re.finditer(r'\.%s\.Remove\((@?"(?:[^"\\]|\\.|"")*")\)' % prop, body):
            lit = cs_string_to_aether(m.group(1))
            if lit is None:
                return ('skip', 'unconvertible string in %s.Remove' % prop)
            setup.append(tmpl.format(v=lit))
    for prop, tmpl in SET_CLEAR.items():
        if re.search(r'\.%s\.Clear\(\)' % prop, body):
            setup.append(tmpl)
    for prop, tmpl in SET_BOOL.items():
        m = re.search(r'\.%s\s*=\s*(true|false)' % prop, body)
        if m:
            setup.append(tmpl.format(v=m.group(1)))

    # Reject any config assignment we didn't recognise, rather than silently
    # running the test under default config (which could make a real failure
    # look like a pass, or vice versa).
    for m in re.finditer(r'sanitizer\.(\w+)\s*(=|\.)', body):
        prop = m.group(1)
        known = set(SET_ADD) | set(SET_BOOL) | {'Sanitize', 'SanitizeDocument'}
        if prop not in known:
            return ('skip', 'unmodelled config: sanitizer.%s' % prop)

    # Local string bindings: `string htmlFragment = "..."` / `var x = @"..."`.
    # Most tests bind the input (and often the expectation) to a local first
    # and pass the NAME to Sanitize, so resolve those before matching calls.
    locals_ = {}
    for m in re.finditer(
            r'(?:string|var)\s+(\w+)\s*=\s*(@?"(?:[^"\\]|\\.|"")*")\s*;', body):
        lit = cs_string_to_aether(m.group(2))
        if lit is not None:
            locals_[m.group(1)] = lit

    def resolve(tok):
        """A literal, or a local bound to one. None if neither."""
        if tok is None:
            return '""'
        tok = tok.strip()
        if tok.startswith('"') or tok.startswith('@"'):
            return cs_string_to_aether(tok)
        if theory_param is not None and tok == theory_param:
            return '@ROW@'
        return locals_.get(tok)

    # the Sanitize call(s)
    calls = []
    # Accept a literal OR an identifier for each argument.
    ARG = r'(@?"(?:[^"\\]|\\.|"")*"|\w+)'
    pat = re.compile(r'\.(Sanitize|SanitizeDocument)\(\s*' + ARG +
                     r'(?:\s*,\s*' + ARG + r')?\s*\)')
    for m in pat.finditer(body):
        html = resolve(m.group(2))
        base = resolve(m.group(3))
        if html is None or base is None:
            return ('skip', 'Sanitize argument is not a resolvable string literal')
        calls.append((m.group(1), html, base))

    if len(calls) > 1:
        # Several independent input->expected pairs in one method body (the
        # upstream style for grouped vectors: MiscTest alone has 18). Not a
        # reason to drop them — walk the body in order, rebinding `html` /
        # `expected` as the C# does, and emit one case per assertion.
        seq = parse_sequential(body, theory_param)
        if seq:
            return ('multi', seq, setup)
        return ('skip', 'multiple Sanitize calls, not a resolvable sequence')
    if len(calls) != 1:
        return ('skip', 'expected exactly one Sanitize call, found %d' % len(calls))

    # the expected value: Assert.Equal(expected, actual) — expected is a literal
    # The actual may be a bare identifier OR an inline call, e.g.
    #   Assert.Equal(@"<div></div>", sanitizer.Sanitize(html), ignoreCase: true)
    # so match the expected literal and the trailing ignoreCase, and let the
    # middle be anything balanced-ish up to the optional ignoreCase/close.
    eq = re.search(
        r'Assert\.Equal\(\s*(@?"(?:[^"\\]|\\.|"")*"|\w+)\s*,'
        r'[^;]*?(?:,\s*ignoreCase:\s*(true|false))?\s*\)\s*;', body)
    if not eq:
        # sometimes: Assert.Equal(expected, actual) with expected declared above
        var = re.search(r'(?:string|var)\s+expected\s*=\s*(@?"(?:[^"\\]|\\.|"")*")\s*;', body)
        chk = re.search(r'Assert\.Equal\(\s*expected\s*,', body)
        if var and chk:
            expected = resolve(var.group(1))
            ignore_case = 'ignoreCase: true' in body
        else:
            return ('skip', 'no literal Assert.Equal(expected, actual)')
    else:
        expected = resolve(eq.group(1))
        ignore_case = eq.group(2) == 'true'

    if expected is None:
        return ('skip', 'unconvertible expected string')
    return (setup, calls[0], expected, ignore_case)


def parse_theories(src):
    """[InlineData(...)]* [Theory] public void Name(params) { body }

    Each InlineData row becomes one test. Only single-argument rows are taken
    (the html), with the expectation coming from the body's literal — a
    two-argument row means the expectation varies per row, which the body
    then references by parameter name and we cannot resolve.
    """
    out, skipped = [], []
    pat = re.compile(
        r'\[Theory\]\s*public void (\w+)\(([^)]*)\)\s*\{(.*?)\n    \}', re.S)
    for m in pat.finditer(src):
        name, params, body = m.groups()
        # Walk backwards from [Theory] collecting the contiguous run of
        # InlineData attributes, skipping // comments and blank lines between
        # them (the upstream file annotates individual vectors that way).
        head = src[:m.start()]
        lines, rows_lines = head.split('\n'), []
        for ln in reversed(lines):
            t = ln.strip()
            if t.startswith('[InlineData('):
                rows_lines.append(ln)
            elif t == '' or t.startswith('//'):
                continue
            else:
                break
        rows_blob = '\n'.join(reversed(rows_lines))
        nparams = len([x for x in params.split(',') if x.strip()])
        if nparams != 1:
            skipped.append((name, 'Theory with %d parameters — expectation varies per row' % nparams))
            continue
        param = params.strip().split()[-1]
        r = parse_body(name, body, theory_param=param)
        if r[0] == 'skip':
            skipped.append((name, r[1]))
            continue
        setup, call, expected, ignore_case = r
        if call[1] != '@ROW@':
            skipped.append((name, 'Theory body does not sanitize its row parameter'))
            continue
        rows = re.findall(r'\[InlineData\(\s*(@?"(?:[^"\\]|\\.|"")*")\s*\)\]', rows_blob)
        if not rows:
            skipped.append((name, 'InlineData rows not single string literals'))
            continue
        for i, row in enumerate(rows, 1):
            html = cs_string_to_aether(row)
            if html is None:
                skipped.append(('%s[%d]' % (name, i), 'unconvertible InlineData literal'))
                continue
            # substitute this row's html into the call
            out.append(('%s_%d' % (name, i), setup,
                        (call[0], html, call[2]), expected, ignore_case))
    return out, skipped


def main():
    src = open(SRC).read()
    bodies = re.findall(r'\[Fact\]\s*public void (\w+)\(\)\s*\{(.*?)\n    \}', src, re.S)

    ported, skipped = [], []
    for name, body in bodies:
        r = parse_body(name, body)
        if r[0] == 'skip':
            skipped.append((name, r[1]))
        elif r[0] == 'multi':
            _tag, seq, setup = r
            for i, (call, expected, ic) in enumerate(seq, 1):
                ported.append(('%s_%d' % (name, i), setup, call, expected, ic))
        else:
            setup, call, expected, ignore_case = r
            ported.append((name, setup, call, expected, ignore_case))

    tp, ts = parse_theories(src)
    ported.extend(tp)
    skipped.extend(ts)

    print(json.dumps({'ported': len(ported), 'skipped': len(skipped),
                      'facts': len(bodies), 'theory_rows': len(tp)}), file=sys.stderr)
    for n, why in skipped:
        print('SKIP %-46s %s' % (n, why), file=sys.stderr)

    emit(ported, skipped)
    return ported, skipped


HEADER = """// Parity suite: Michael Ganss's C# HtmlSanitizer tests, ported to std.spec.
//
// GENERATED — do not hand-edit. Regenerate with the porter in the repo's
// tooling (see docs/ganss-parity.md), which reads
// ../HtmlSanitizer/test/HtmlSanitizer.Tests/Tests.cs and translates every
// test whose whole body it understands.
//
// Why generate rather than hand-port: upstream has 252 [Fact]s + 18
// [Theory]s encoding a decade of XSS bypass reports. Hand-copying them
// invites transcription errors in exactly the strings where a wrong byte
// silently weakens a security test.
//
// The porter is deliberately CONSERVATIVE. A test is emitted only when its
// input, its configuration and its expectation are all resolvable to
// literals; anything else is skipped WITH A REASON rather than guessed at,
// so this file can never claim coverage it does not have. The skip manifest
// (count and reasons) is in docs/ganss-parity.md.
//
// Portions copyright (c) 2013-2016 Michael Ganss and the original C#
// HtmlSanitizer contributors (MIT) — these test vectors are theirs.

import core.htmlsanitizer
import core.htmlsanitizer (HtmlSanitizer)
import std.spec
import std.set
import std.string
import std.regex

// Case-insensitive compare, for the upstream asserts that pass
// `ignoreCase: true`. Those tests care about the sanitizing decision, not
// the emitter's tag/attribute casing.
fn eq_ci(actual: string, expected: string) -> bool {
    return string.to_lower(actual) == string.to_lower(expected)
}

main() {
    fw = spec.init()
"""

FOOTER = """
    spec.run_summary(fw)
}
"""


def emit(ported, skipped):
    out = [HEADER]
    out.append('    spec.describe(fw, "Ganss C# HtmlSanitizer parity") {\n')
    for name, setup, call, expected, ignore_case in ported:
        fn, html, base = call
        out.append('        spec.it("%s") callback {\n' % name)
        out.append('            s = htmlsanitizer.new()\n')
        for line in setup:
            out.append('            %s\n' % line)
        meth = 'sanitize_document' if fn == 'SanitizeDocument' else 'sanitize'
        out.append('            actual = htmlsanitizer.%s(s, %s, %s)\n'
                   % (meth, html, base))
        if ignore_case:
            out.append('            spec.assert_str_eq(string.to_lower(actual), '
                       'string.to_lower(%s),\n'
                       '                "%s (case-insensitive)")\n' % (expected, name))
        else:
            out.append('            spec.assert_str_eq(actual, %s, "%s")\n'
                       % (expected, name))
        out.append('            htmlsanitizer.free(s)\n')
        out.append('        }\n')
    out.append('    }\n')
    out.append(FOOTER)
    dest = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "core_tests", "test_ganss_parity.ae")
    open(dest, "w").write(''.join(out))
    print("wrote %s (%d tests)" % (dest, len(ported)), file=sys.stderr)


if __name__ == '__main__':
    main()
