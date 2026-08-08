<?php

declare(strict_types=1);

namespace HtmlSanitization;

use FFI;

/**
 * A DOM attribute, **borrowed** for the duration of a callback.
 *
 * Do not retain one past the callback that gave it to you — the DOM is freed
 * when {@see HtmlSanitizer::sanitize()} returns.
 */
final class Attribute
{
    /** @param FFI\CData $ptr */
    public function __construct(private FFI $ffi, private $ptr)
    {
    }

    public function name(): string
    {
        return Native::takeString($this->ffi, $this->ffi->aether_hs_embed_attr_name($this->ptr));
    }

    public function value(): string
    {
        return Native::takeString($this->ffi, $this->ffi->aether_hs_embed_attr_value($this->ptr));
    }

    /**
     * Rewrite the value in place (e.g. to canonicalise a URL rather than
     * remove the attribute). The engine copies the string, so PHP's transient
     * buffer is safe here.
     */
    public function setValue(string $value): void
    {
        $this->ffi->aether_hs_embed_attr_set_value($this->ptr, $value);
    }

    public function __toString(): string
    {
        return sprintf('Attribute(%s=%s)', $this->name(), $this->value());
    }
}
