<?php

/**
 * The 12-check binding conformance suite (docs/conformance.md).
 *
 * Proves the PHP binding marshals every value shape across the FFI. It is NOT
 * a sanitizer test suite — the behavioural cases live in the engine's own
 * tests and run once, in Aether.
 *
 * ## Why a plain runner and not PHPUnit
 *
 * PHPUnit arrives via Composer, so `vendor/bin/phpunit` needs a `composer
 * install` — a network round trip, or a pre-warmed cache — before a single
 * assertion executes. The rest of this monorepo's bindings test with whatever
 * is already on the box, so this one does too: `php tests/conformance.php`,
 * no dependencies, and the process exit code is the result.
 *
 * The trade is real and small: no test discovery, no data providers, no
 * `--filter`. For twenty-odd marshalling assertions that costs nothing, and it
 * keeps the binding testable on an air-gapped machine. Swapping in PHPUnit
 * later is mechanical — each check(...) below is one `public function test*`.
 *
 *     HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
 *         php -d ffi.enable=1 tests/conformance.php
 */

declare(strict_types=1);

// Composer's autoloader when the package has been installed; otherwise a
// four-line PSR-4 stand-in, so the suite runs from a bare checkout with no
// `composer install` (and therefore no network).
if (is_file(__DIR__ . '/../vendor/autoload.php')) {
    require __DIR__ . '/../vendor/autoload.php';
} else {
    spl_autoload_register(static function (string $class): void {
        $prefix = 'HtmlSanitization\\';
        if (!str_starts_with($class, $prefix)) {
            return;
        }
        $file = __DIR__ . '/../src/' . substr($class, strlen($prefix)) . '.php';
        if (is_file($file)) {
            require $file;
        }
    });
}

use HtmlSanitization\HtmlSanitizer;
use HtmlSanitization\Native;
use HtmlSanitization\Node;

$passed = 0;
/** @var list<string> $failures */
$failures = [];

/**
 * Run one check. The sanitizer is created and closed around $body, so each
 * check starts from the engine's defaults.
 */
function check(string $name, callable $body): void
{
    global $passed, $failures;
    $s = null;
    try {
        $s = new HtmlSanitizer();
        $body($s);
        $passed++;
        echo "  PASS {$name}\n";
    } catch (\Throwable $e) {
        $failures[] = "{$name}: {$e->getMessage()}";
        echo "  FAIL {$name}\n";
        echo "       {$e->getMessage()}\n";
    } finally {
        if ($s !== null) {
            $s->close();
        }
    }
}

function eqStr(string $got, string $want, string $what = 'value'): void
{
    if ($got !== $want) {
        throw new \Exception(sprintf("%s:\n         got  \"%s\"\n         want \"%s\"", $what, $got, $want));
    }
}

function eqInt(int $got, int $want, string $what = 'value'): void
{
    if ($got !== $want) {
        throw new \Exception("{$what}: got {$got}, want {$want}");
    }
}

function isTrue(bool $got, string $what): void
{
    if (!$got) {
        throw new \Exception("{$what}: expected true");
    }
}

function isFalse(bool $got, string $what): void
{
    if ($got) {
        throw new \Exception("{$what}: expected false");
    }
}

/** @param array<int, mixed> $haystack */
function contains(array $haystack, mixed $needle, string $what): void
{
    if (!in_array($needle, $haystack, true)) {
        throw new \Exception(sprintf(
            '%s: %s not found in [%s]',
            $what,
            var_export($needle, true),
            implode(', ', array_map(static fn ($v) => (string) $v, $haystack))
        ));
    }
}

echo "=== htmlsanitizer PHP binding conformance ===\n";
if (!extension_loaded('ffi')) {
    fwrite(STDERR, "php: ext-ffi is not loaded\n");
    exit(2);
}
$probe = new HtmlSanitizer();
printf("engine: %s (ABI v%d)\n", $probe->nativeLibraryPath() ?? '(unknown)', $probe->abiVersion());
$probe->close();

// ---- the twelve ----

check('01 script removed', function (HtmlSanitizer $s): void {
    eqStr($s->sanitize('<div>Hello <script>alert(1)</script> world!</div>'), '<div>Hello  world!</div>');
});

check('02 onclick removed', function (HtmlSanitizer $s): void {
    eqStr($s->sanitize('<div onclick="alert(1)">Hello</div>'), '<div>Hello</div>');
});

check('03 empty string', function (HtmlSanitizer $s): void {
    eqStr($s->sanitize(''), '');
});

check('04 utf-8 round trip', function (HtmlSanitizer $s): void {
    // PHP strings are byte strings; this proves the bytes survive intact.
    eqStr($s->sanitize('<div>café ☕</div>'), '<div>café ☕</div>');
});

check('05 allow custom tag', function (HtmlSanitizer $s): void {
    eqStr($s->sanitize('<my-widget>x</my-widget>'), '');
    $s->allowedTags->add('my-widget');
    eqStr($s->sanitize('<my-widget>x</my-widget>'), '<my-widget>x</my-widget>');
});

check('06 disallow tag', function (HtmlSanitizer $s): void {
    eqStr($s->sanitize('<div>x</div>'), '<div>x</div>');
    $s->allowedTags->remove('div');
    eqStr($s->sanitize('<div>x</div>'), '');
});

check('07 membership and count', function (HtmlSanitizer $s): void {
    isTrue($s->allowedSchemes->contains('http'), 'http allowed');
    isFalse($s->allowedSchemes->contains('gopher'), 'gopher allowed');
    eqInt($s->allowedSchemes->count(), 2, 'scheme count');
    eqInt(count($s->allowedSchemes), 2, 'scheme count via count()');
});

check('08 enumeration', function (HtmlSanitizer $s): void {
    $got = $s->allowedSchemes->toSortedArray();
    eqInt(count($got), 2, 'enumerated count');
    eqStr($got[0], 'http');
    eqStr($got[1], 'https');

    // and via the Traversable surface
    $viaForeach = [];
    foreach ($s->allowedSchemes as $scheme) {
        $viaForeach[] = $scheme;
    }
    sort($viaForeach, SORT_STRING);
    eqStr(implode(',', $viaForeach), 'http,https', 'foreach enumeration');
});

check('09 keep child nodes', function (HtmlSanitizer $s): void {
    eqStr($s->sanitize('<div><nope>Hello <span>world</span></nope></div>'), '<div></div>');
    $s->setKeepChildNodes(true);
    isTrue($s->getKeepChildNodes(), 'keepChildNodes');
    eqStr(
        $s->sanitize('<div><nope>Hello <span>world</span></nope></div>'),
        '<div>Hello <span>world</span></div>'
    );
});

check('10 onRemovingTag cancels', function (HtmlSanitizer $s): void {
    $names = [];
    $reasons = [];
    $s->onRemovingTag(function (Node $node, int $reason) use (&$names, &$reasons): bool {
        $names[] = $node->name();
        $reasons[] = $reason;
        return $node->name() === 'keep-me';
    });
    eqStr(
        $s->sanitize('<div><keep-me>a</keep-me><drop-me>b</drop-me></div>'),
        '<div><keep-me>a</keep-me></div>'
    );
    contains($names, 'keep-me', 'hook saw keep-me');
    contains($names, 'drop-me', 'hook saw drop-me');
    // An int/long width mismatch shows up here as a garbage reason.
    contains($reasons, Native::REASON_NOT_ALLOWED_TAG, 'reason is a real int');
});

check('11 onFilterUrl rewrites', function (HtmlSanitizer $s): void {
    $s->onFilterUrl(static function (Node $elem, string $raw, string $resolved): string {
        return $resolved === 'https://example.com/logo.png'
            ? 'https://cdn.example.net/logo.png'
            : $resolved;
    });
    eqStr(
        $s->sanitize('<img src="logo.png">', 'https://example.com'),
        '<img src="https://cdn.example.net/logo.png">'
    );
});

check('12 handles are independent', function (): void {
    $a = new HtmlSanitizer();
    $b = new HtmlSanitizer();
    try {
        $a->allowedTags->add('only-in-a');
        isTrue($a->allowedTags->contains('only-in-a'), 'a knows the tag');
        isFalse($b->allowedTags->contains('only-in-a'), 'b does not');
    } finally {
        $a->close();
        $b->close();
    }
});

// ---- a few extras that exercise the remaining callback shapes ----

check('onRemovingAttribute sees the attribute', function (HtmlSanitizer $s): void {
    $seen = [];
    $s->onRemovingAttribute(function (Node $elem, $attr, int $reason) use (&$seen): bool {
        $seen[] = $elem->name() . '/' . $attr->name() . '/' . $attr->value();
        return false;
    });
    eqStr($s->sanitize('<div onclick="alert(1)">x</div>'), '<div>x</div>');
    contains($seen, 'div/onclick/alert(1)', 'attribute hook');
});

check('onRemovingComment cancels', function (HtmlSanitizer $s): void {
    $s->onRemovingComment(static fn (Node $node): bool => true);
    eqStr($s->sanitize('<div>a<!-- keep -->b</div>'), '<div>a<!-- keep -->b</div>');
});

check('onRemovingStyle is four-arg', function (HtmlSanitizer $s): void {
    $seen = [];
    $s->onRemovingStyle(function (Node $elem, string $name, string $value, int $reason) use (&$seen): bool {
        $seen[] = "{$name}={$value}";
        return $name === '-custom-thing';
    });
    $out = $s->sanitize('<div style="-custom-thing: 3; color: red">x</div>');
    isTrue(str_contains($out, '-custom-thing'), 'custom property kept');
    contains($seen, '-custom-thing=3', 'style hook args');
});

check('onPostProcessNode visits', function (HtmlSanitizer $s): void {
    $kinds = [];
    $s->onPostProcessNode(function (Node $node) use (&$kinds): void {
        $kinds[] = $node->kind();
    });
    $s->sanitize('<div><span>a</span><span>b</span></div>');
    isTrue(count($kinds) > 0, 'onPostProcessNode fired');
});

check('node tree navigation', function (HtmlSanitizer $s): void {
    $kind = 0;
    $children = 0;
    $s->onPostProcessDom(function (Node $doc) use (&$kind, &$children): void {
        $kind = $doc->kind();
        $children = count($doc->children());
        if ($children > 0) {
            $first = $doc->childAt(0);
            isTrue($first !== null, 'childAt(0)');
            isTrue($first?->parent() !== null, "child's parent is set");
        }
    });
    $s->sanitize('<div>a</div><p>b</p>');
    eqInt($kind, Native::NODE_DOCUMENT, 'document kind');
    isTrue($children >= 2, 'document has >= 2 children');
});

check('setValue rewrites an attribute in place', function (HtmlSanitizer $s): void {
    $s->onRemovingAttribute(static function (Node $elem, $attr, int $reason): bool {
        if ($attr->name() === 'onclick') {
            $attr->setValue('sanitised');
            eqStr($attr->value(), 'sanitised', 'value after setValue');
        }
        return false;
    });
    eqStr($s->sanitize('<div onclick="alert(1)">x</div>'), '<div>x</div>');
});

check('attribute enumeration', function (HtmlSanitizer $s): void {
    $names = [];
    $s->onPostProcessNode(function (Node $node) use (&$names): void {
        if ($node->kind() === Native::NODE_ELEMENT && $node->name() === 'a') {
            foreach ($node->attributes() as $a) {
                $names[] = $a->name();
            }
        }
    });
    $s->sanitize('<a href="https://example.com/" title="t">x</a>');
    contains($names, 'href', 'href seen');
    contains($names, 'title', 'title seen');
});

check('clearing a hook restores default behaviour', function (HtmlSanitizer $s): void {
    $s->onRemovingTag(static fn (Node $node, int $r): bool => $node->name() === 'keep-me');
    eqStr($s->sanitize('<div><keep-me>a</keep-me></div>'), '<div><keep-me>a</keep-me></div>');
    $s->onRemovingTag(null);
    eqStr($s->sanitize('<div><keep-me>a</keep-me></div>'), '<div></div>');
});

check('sanitizeDocument is wired', function (HtmlSanitizer $s): void {
    eqStr($s->sanitizeDocument('<div>doc<script>x</script></div>'), '<html><head></head><body><div>doc</div></body></html>');
});

check('allowDataAttributes flag', function (HtmlSanitizer $s): void {
    isFalse($s->getAllowDataAttributes(), 'off by default');
    $s->setAllowDataAttributes(true);
    isTrue($s->getAllowDataAttributes(), 'on after set');
    eqStr($s->sanitize('<div data-x="1"></div>'), '<div data-x="1"></div>');
});

check('clear empties a policy list', function (HtmlSanitizer $s): void {
    $s->allowedSchemes->clear();
    eqInt($s->allowedSchemes->count(), 0, 'count after clear');
});

check('item at an out-of-range index is empty', function (HtmlSanitizer $s): void {
    eqStr($s->allowedSchemes->at(999), '', 'out of range');
    eqStr($s->allowedSchemes->at(-1), '', 'negative index');
});

check('ArrayAccess append adds to the set', function (HtmlSanitizer $s): void {
    $s->allowedTags[] = 'my-widget';
    isTrue($s->allowedTags->contains('my-widget'), 'appended tag');
    eqStr($s->sanitize('<my-widget>x</my-widget>'), '<my-widget>x</my-widget>');
});

check('ABI version', function (HtmlSanitizer $s): void {
    isTrue($s->abiVersion() >= 1, 'abiVersion >= 1');
});

check('closed sanitizer rejects use', function (): void {
    $s = new HtmlSanitizer();
    $s->close();
    try {
        $s->sanitize('<div>x</div>');
        throw new \Exception('expected a LogicException');
    } catch (\LogicException $e) {
        isTrue(str_contains($e->getMessage(), 'closed'), 'error mentions "closed"');
    }
    $s->close();   // idempotent
});

check('one-shot helpers', function (): void {
    eqStr(HtmlSanitizer::sanitizeOnce('<div>a<script>b</script></div>'), '<div>a</div>');
    eqStr(HtmlSanitizer::sanitizeDocumentOnce('<div>a<script>b</script></div>'), '<html><head></head><body><div>a</div></body></html>');
});

check('many sanitize calls do not leak or crash', function (HtmlSanitizer $s): void {
    // A returned char* that was never freed would show up here as steadily
    // growing RSS; a double free would crash. Cheap insurance over the
    // takeString contract.
    for ($i = 0; $i < 5000; $i++) {
        $s->sanitize('<div onclick="x">café ☕ <script>no</script></div>');
    }
    eqStr($s->sanitize('<div>ok</div>'), '<div>ok</div>');
});

// ---- result ----

printf("=== %d passed, %d failed ===\n", $passed, count($failures));
if ($failures !== []) {
    echo "failures:\n";
    foreach ($failures as $f) {
        echo "  - {$f}\n";
    }
    exit(1);
}
exit(0);
