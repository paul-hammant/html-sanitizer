<?php

/**
 * A short tour of the PHP binding. Run it with the engine built:
 *
 *   cd core && ae build --emit=lib embed.ae --extra _embed_support.c \
 *       -o native/libhtmlsanitizer.so
 *   cd ../php && HTMLSANITIZER_LIB=../core/native/libhtmlsanitizer.so \
 *       php -d ffi.enable=1 example/main.php
 */

declare(strict_types=1);

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

use HtmlSanitization\HtmlSanitizer;
use HtmlSanitization\Node;

$s = new HtmlSanitizer();

printf("engine: %s (ABI v%d)\n", $s->nativeLibraryPath() ?? '(unknown)', $s->abiVersion());

// 1. the defaults
echo $s->sanitize('<div onclick="evil()">Hello <script>x</script></div>'), "\n";
// <div>Hello </div>

// 2. teach it a custom element
$s->allowedTags->add('my-widget');
echo $s->sanitize('<my-widget>ok</my-widget>'), "\n";
// <my-widget>ok</my-widget>

// 3. keep the children of anything it removes
$s->setKeepChildNodes(true);
echo $s->sanitize('<div><nope>Hello <span>world</span></nope></div>'), "\n";
// <div>Hello <span>world</span></div>

// 4. rewrite URLs as they are resolved
$s->onFilterUrl(static function (Node $elem, string $raw, string $resolved): string {
    return str_replace('https://example.com/', 'https://cdn.example.net/', $resolved);
});
echo $s->sanitize('<img src="logo.png">', 'https://example.com/'), "\n";
// <img src="https://cdn.example.net/logo.png">

// 5. veto a removal — a truthy return KEEPS the node
$s->onRemovingTag(static fn (Node $node, int $reason): bool => $node->name() === 'keep-me');
echo $s->sanitize('<div><keep-me>a</keep-me></div>'), "\n";
// <div><keep-me>a</keep-me></div>

// 6. inspect the policy
echo 'schemes: ', (string) $s->allowedSchemes, "\n";
echo 'tags: ', $s->allowedTags->count(), "\n";

$s->close();

// 7. one-shots, for when a handle is overkill
echo HtmlSanitizer::sanitizeOnce('<p>hi<script>no</script></p>'), "\n";
