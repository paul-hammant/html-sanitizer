<?php

/**
 * The idiomatic PHP surface over the HtmlSanitizer core.
 *
 * Carries no sanitizer logic — every method here marshals to an
 * `aether_hs_embed_*` call in {@see Native}.
 *
 * @package HtmlSanitization
 */

declare(strict_types=1);

namespace HtmlSanitization;

use FFI;
use LogicException;
use RuntimeException;

/**
 * Cleans HTML of constructs that can lead to Cross-Site Scripting (XSS).
 *
 *     $s = new HtmlSanitizer();
 *     $s->allowedTags->add('my-widget');
 *     $clean = $s->sanitize('<div onclick="evil()">hi</div>');
 *     $s->close();
 *
 * A sanitizer is **not** safe for concurrent use — the native handle carries
 * mutable policy and hook state.
 */
final class HtmlSanitizer
{
    private FFI $ffi;

    /** @var FFI\CData|null */
    private $handle;

    /**
     * Registered FFI closures must be kept alive for as long as the sanitizer core can
     * call them. A closure that went out of scope would be freed and the
     * process would segfault on the next callback. This array is the PHP
     * equivalent of ctypes' keepalive list, and is cleared only in close(),
     * after aether_hs_embed_free has run.
     *
     * @var array<int, mixed>
     */
    private array $keepAlive = [];

    public readonly AllowList $allowedTags;
    public readonly AllowList $allowedAttributes;
    public readonly AllowList $allowedCssProperties;
    public readonly AllowList $allowedSchemes;
    public readonly AllowList $allowedClasses;
    public readonly AllowList $uriAttributes;

    /**
     * Create a sanitizer with the sanitizer core's secure defaults populated.
     *
     * @param string|null $nativeLib An explicit sanitizer core path; otherwise
     *                               $HTMLSANITIZER_LIB, then native/, then
     *                               ../core/native/, then the OS loader.
     * @throws RuntimeException when the sanitizer core cannot be loaded or created.
     */
    public function __construct(?string $nativeLib = null)
    {
        $this->ffi = Native::load($nativeLib);
        $handle = $this->ffi->aether_hs_embed_new();
        if (FFI::isNull($handle)) {
            throw new RuntimeException('htmlsanitizer: failed to create the native sanitizer');
        }
        $this->handle = $handle;

        $this->allowedTags          = new AllowList($this, Native::TAGS);
        $this->allowedAttributes    = new AllowList($this, Native::ATTRIBUTES);
        $this->allowedCssProperties = new AllowList($this, Native::CSS_PROPERTIES);
        $this->allowedSchemes       = new AllowList($this, Native::SCHEMES);
        $this->allowedClasses       = new AllowList($this, Native::CLASSES);
        $this->uriAttributes        = new AllowList($this, Native::URI_ATTRIBUTES);
    }

    /** @internal */
    public function ffi(): FFI
    {
        return $this->ffi;
    }

    /**
     * @internal
     * @return FFI\CData
     */
    public function handle()
    {
        if ($this->handle === null) {
            throw new LogicException('htmlsanitizer: sanitizer is closed');
        }
        return $this->handle;
    }

    // ---- lifecycle ----

    /** Release the native handle and every callback closure. Idempotent. */
    public function close(): void
    {
        if ($this->handle === null) {
            return;
        }
        $h = $this->handle;
        $this->handle = null;
        $this->ffi->aether_hs_embed_free($h);
        // Only now is it certain the sanitizer core can no longer invoke a hook.
        $this->keepAlive = [];
    }

    /**
     * Backstop for a dropped sanitizer; close() is the deterministic way.
     *
     * Guarded with isset(): during PHP's final shutdown GC, object destruction
     * order is not defined, so the FFI object in $this->ffi may already have
     * been torn down when this runs. Calling into it then is a segfault, not
     * an exception. A sanitizer that reaches shutdown without close() leaks
     * one native handle — which the OS reclaims on exit anyway — and that is
     * strictly better than crashing the interpreter on the way out.
     */
    public function __destruct()
    {
        if (!isset($this->ffi)) {
            return;
        }
        $this->close();
    }

    /**
     * Run $body with a fresh sanitizer, closing it afterwards even on throw.
     *
     * (Named withSanitizer rather than use: `use` is a reserved word, and
     * although PHP 7+ permits it as a method name it confuses tooling and
     * readers alike.)
     *
     * @template T
     * @param callable(HtmlSanitizer): T $body
     * @return T
     */
    public static function withSanitizer(callable $body, ?string $nativeLib = null): mixed
    {
        $s = new self($nativeLib);
        try {
            return $body($s);
        } finally {
            $s->close();
        }
    }

    // ---- the main entry point ----

    /**
     * Sanitize an HTML fragment. $baseUrl resolves relative URLs; pass ""
     * (the default) for no resolution.
     */
    public function sanitize(string $html, string $baseUrl = ''): string
    {
        return Native::takeString(
            $this->ffi,
            $this->ffi->aether_hs_embed_sanitize($this->handle(), $html, $baseUrl)
        );
    }

    /** Sanitize a full HTML document. */
    public function sanitizeDocument(string $html, string $baseUrl = ''): string
    {
        return Native::takeString(
            $this->ffi,
            $this->ffi->aether_hs_embed_sanitize_document($this->handle(), $html, $baseUrl)
        );
    }

    // ---- flags ----

    /** Keep the children of a removed element instead of dropping the subtree. */
    public function setKeepChildNodes(bool $on): self
    {
        $this->ffi->aether_hs_embed_set_keep_child_nodes($this->handle(), $on ? 1 : 0);
        return $this;
    }

    public function getKeepChildNodes(): bool
    {
        return $this->ffi->aether_hs_embed_get_keep_child_nodes($this->handle()) !== 0;
    }

    /** Allow `data-*` attributes through without listing each one. */
    public function setAllowDataAttributes(bool $on): self
    {
        $this->ffi->aether_hs_embed_set_allow_data_attributes($this->handle(), $on ? 1 : 0);
        return $this;
    }

    public function getAllowDataAttributes(): bool
    {
        return $this->ffi->aether_hs_embed_get_allow_data_attributes($this->handle()) !== 0;
    }

    /** The sanitizer core's ABI revision. */
    public function abiVersion(): int
    {
        return $this->ffi->aether_hs_embed_abi_version();
    }

    /** Where the sanitizer core .so was actually loaded from. */
    public function nativeLibraryPath(): ?string
    {
        return Native::path();
    }

    // ---- callbacks ----
    //
    // Each on* takes a PHP callable (or null to clear the hook) and returns
    // $this, so they chain. For the removing* family, returning a truthy value
    // from your handler CANCELS the removal (keeps the node/attribute/
    // property).

    /**
     * Register a trampoline with one of the ABI's seven `on_*` setters.
     *
     * PHP's FFI turns a PHP Closure into a real C function pointer when it is
     * passed to a parameter declared as a function-pointer type — which is
     * exactly how the setters are declared in {@see Native}'s cdef. Passing
     * null clears the hook.
     *
     * The Closure is stored in $keepAlive BEFORE it is registered: PHP frees
     * the generated thunk when the Closure becomes unreachable, and the sanitizer core
     * would then call into freed memory.
     *
     * user_data is unused on the PHP side — the Closure already captures the
     * handler, so there is nothing to look up. The sanitizer core's trampoline still
     * round-trips it.
     */
    private function register(string $setter, ?\Closure $trampoline): self
    {
        $h = $this->handle();
        if ($trampoline === null) {
            $this->ffi->$setter($h, null, null);
            return $this;
        }

        $this->keepAlive[] = $trampoline;
        $this->ffi->$setter($h, $trampoline, null);
        return $this;
    }

    /** `fn(Node $node, int $reason): bool` — return true to KEEP the tag. */
    public function onRemovingTag(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_removing_tag',
            $handler === null ? null : static fn ($ud, $node, int $reason): int
                => $handler(new Node($ffi, $node), $reason) ? 1 : 0
        );
    }

    /** `fn(Node $elem, Attribute $attr, int $reason): bool` — true KEEPS it. */
    public function onRemovingAttribute(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_removing_attribute',
            $handler === null ? null : static fn ($ud, $elem, $attr, int $reason): int
                => $handler(new Node($ffi, $elem), new Attribute($ffi, $attr), $reason) ? 1 : 0
        );
    }

    /** `fn(Node $elem, string $name, string $value, int $reason): bool`. */
    public function onRemovingStyle(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_removing_style',
            $handler === null ? null : static fn ($ud, $elem, $name, $value, int $reason): int
                => $handler(
                    new Node($ffi, $elem),
                    Native::borrowString($name),
                    Native::borrowString($value),
                    $reason
                ) ? 1 : 0
        );
    }

    /** `fn(Node $node): bool` — return true to KEEP the comment. */
    public function onRemovingComment(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_removing_comment',
            $handler === null ? null : static fn ($ud, $node): int
                => $handler(new Node($ffi, $node)) ? 1 : 0
        );
    }

    /** `fn(Node $node): void` — called for each node after filtering. */
    public function onPostProcessNode(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_post_process_node',
            $handler === null ? null : static function ($ud, $node) use ($handler, $ffi): void {
                $handler(new Node($ffi, $node));
            }
        );
    }

    /** `fn(Node $doc): void` — called once with the whole document. */
    public function onPostProcessDom(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_post_process_dom',
            $handler === null ? null : static function ($ud, $doc) use ($handler, $ffi): void {
                $handler(new Node($ffi, $doc));
            }
        );
    }

    /**
     * `fn(Node $elem, string $raw, string $resolved): string`
     *
     * Return the URL to use — $resolved unchanged for no rewrite, "" to drop
     * the attribute. The string is strdup'd into a buffer the sanitizer core takes
     * ownership of; you do not free it.
     */
    public function onFilterUrl(?callable $handler): self
    {
        $ffi = $this->ffi;
        return $this->register(
            'aether_hs_embed_on_filter_url',
            $handler === null ? null : static function ($ud, $elem, $raw, $resolved) use ($handler, $ffi) {
                $out = (string) $handler(
                    new Node($ffi, $elem),
                    Native::borrowString($raw),
                    Native::borrowString($resolved)
                );
                // The sanitizer core frees this, so it must come from malloc — not
                // FFI::new, whose memory PHP owns and would free a second
                // time. hs_raw_dup is the sanitizer core's own malloc'd strdup, and
                // therefore the exact counterpart of the free() that will
                // release it.
                return $ffi->hs_raw_dup($out);
            }
        );
    }

    // ---- one-shots ----

    /** Sanitize $html with the sanitizer core's defaults. */
    public static function sanitizeOnce(string $html, string $baseUrl = ''): string
    {
        return self::withSanitizer(static fn (HtmlSanitizer $s): string => $s->sanitize($html, $baseUrl));
    }

    /** Sanitize a full document with the sanitizer core's defaults. */
    public static function sanitizeDocumentOnce(string $html, string $baseUrl = ''): string
    {
        return self::withSanitizer(static fn (HtmlSanitizer $s): string => $s->sanitizeDocument($html, $baseUrl));
    }
}
