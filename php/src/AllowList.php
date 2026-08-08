<?php

declare(strict_types=1);

namespace HtmlSanitization;

use ArrayAccess;
use Countable;
use IteratorAggregate;
use LogicException;
use Traversable;

/**
 * A set-like view over one of the engine's six policy lists.
 *
 * Every operation reads or writes the engine's own set — there is no PHP
 * mirror to fall out of sync.
 *
 * @implements IteratorAggregate<int, string>
 * @implements ArrayAccess<int, string>
 */
final class AllowList implements Countable, IteratorAggregate, ArrayAccess
{
    public function __construct(private HtmlSanitizer $owner, private int $which)
    {
    }

    /** Add one item, or every item of an array. Returns $this, so calls chain. */
    public function add(string|array $item): self
    {
        $ffi = $this->owner->ffi();
        foreach ((array) $item as $one) {
            $ffi->aether_hs_embed_allow($this->owner->handle(), $this->which, (string) $one);
        }
        return $this;
    }

    /** Remove one item — the "deny" direction. */
    public function remove(string $item): self
    {
        $this->owner->ffi()->aether_hs_embed_disallow($this->owner->handle(), $this->which, $item);
        return $this;
    }

    /** Empty the list — the "start from nothing" move for a strict policy. */
    public function clear(): self
    {
        $this->owner->ffi()->aether_hs_embed_clear($this->owner->handle(), $this->which);
        return $this;
    }

    public function contains(string $item): bool
    {
        return $this->owner->ffi()
            ->aether_hs_embed_is_allowed($this->owner->handle(), $this->which, $item) !== 0;
    }

    public function count(): int
    {
        return $this->owner->ffi()->aether_hs_embed_count($this->owner->handle(), $this->which);
    }

    /** The item at $index, or "" when out of range. */
    public function at(int $index): string
    {
        $ffi = $this->owner->ffi();
        return Native::takeString(
            $ffi,
            $ffi->aether_hs_embed_item_at($this->owner->handle(), $this->which, $index)
        );
    }

    /**
     * The items, in the engine's own (unspecified but stable) order.
     *
     * @return list<string>
     */
    public function toArray(): array
    {
        $out = [];
        $n = $this->count();
        for ($i = 0; $i < $n; $i++) {
            $out[] = $this->at($i);
        }
        return $out;
    }

    /**
     * The items, sorted — the deterministic version of {@see toArray()}.
     *
     * @return list<string>
     */
    public function toSortedArray(): array
    {
        $out = $this->toArray();
        sort($out, SORT_STRING);
        return $out;
    }

    public function getIterator(): Traversable
    {
        $n = $this->count();
        for ($i = 0; $i < $n; $i++) {
            yield $i => $this->at($i);
        }
    }

    public function offsetExists(mixed $offset): bool
    {
        return \is_int($offset) && $offset >= 0 && $offset < $this->count();
    }

    public function offsetGet(mixed $offset): string
    {
        return $this->at((int) $offset);
    }

    public function offsetSet(mixed $offset, mixed $value): void
    {
        // Only the append form makes sense for a set: $list[] = 'my-widget'.
        if ($offset !== null) {
            throw new LogicException('AllowList is a set; use $list[] = $item or ->add($item)');
        }
        $this->add((string) $value);
    }

    public function offsetUnset(mixed $offset): void
    {
        throw new LogicException('AllowList is a set; use ->remove($item)');
    }

    public function __toString(): string
    {
        return '{' . implode(', ', $this->toSortedArray()) . '}';
    }
}
