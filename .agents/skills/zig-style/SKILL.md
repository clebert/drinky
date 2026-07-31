---
name: zig-style
description:
  Zig code-style conventions for this environment. The rules cover naming, file/module structure,
  control flow, slices, optional captures, and visibility. Load before you write, edit, or review
  Zig so the code matches the documented rules rather than personal taste.
---

# Zig Code Style

- **Formatting**: `tab_size: 4`, `print_width: 100`.
- **Types**: `PascalCase`, acronyms as single words (`Rgb`, not `RGB`)
- **File names**: `PascalCase.zig` for struct modules (file is a struct via `@This()`),
  `snake_case.zig` for namespace modules (functions/constants only, no struct fields)
- **Functions**: `camelCase`
- **Variables**: `snake_case`
- **SIMD**: `@Vector` types for hardware-accelerated calculations
- **No abbreviations**: full names (`distance`, not `dist`), except where the standard library sets
  the convention (`prng`, after `std.Random.DefaultPrng`)
- **Units and qualifiers last, most significant first**: put a unit or qualifier at the end of a
  name and order words by descending significance. Write `latency_ms_max`, not `max_latency_ms`, so
  `latency_ms_min` lines up and latency names group together
- **Line names up**: give related names the same length so they align in source. Write
  `source`/`target`, not `src`/`dest`, so `source_offset`/`target_offset` match
- **No redundant names in qualified paths**: a declaration is always read through its namespace, so
  do not repeat that namespace in the name. A struct file in `widget/` is `Button.zig`, used as
  `widget.Button`, never `WidgetButton`. A function in `parse.zig` is `parse.token`, not
  `parse.parseToken`
- **No underscore prefixes**: never lead an identifier with `_` to mean "private" or "internal".
  Visibility is `pub` or its absence, and a bare `_` is only the discard binding
- **No aliases**: use the qualified name (`foo.Bar`) directly, never `const FooBar = foo.Bar`
- **No re-exports**: do not re-export imports (`pub const foo = @import("foo.zig")`). Only
  `root.zig` can, for the public API
- **Subsystems are namespaces, not prefixes**: keep a family of related modules in a subdirectory
  and expose it as one namespace, so call sites read `widget.Button`. Never flatten them into the
  parent with a shared prefix (`WidgetButton`, `WidgetPanel`). `root.zig` owns the export that
  forms the namespace
- **`root.zig` exports, never feeds**: `root.zig` imports its subsystem's modules to form the
  public namespace. No module ever imports its own subsystem's `root.zig`, because that inverts the
  dependency and cycles the imports. A module that needs a sibling imports that sibling directly
- **Shared types nest in their owning module**: a union or enum that several modules of a subsystem
  share lives as a nested `pub` type in the struct module that owns that seam. The parser owns its
  token (`Parser.Token`), and the widget owns its style (`Button.Style`). It never lives in
  `root.zig` (exports only), and never in a file of its own. A file is always a struct, so a
  union-as-file is impossible, and the workarounds (a stuttering `token.Token` path or a
  single-decl alias) are both banned above
- **No fake `pub`**: do not mark unused code `pub` to silence warnings. Remove it, along with any
  tests that exist only to exercise it. A symbol consumed elsewhere (including tests in _other_
  modules, e.g. `Srgb.white`) is real API, so keep it and its symmetric constants
- **Const slices**: `[]const T` for read-only slice parameters, `[]T` only for output buffers
- **Optional captures**: never accept a shadow-forced capture name (`if (grain) |g|`). If the value
  is cheap, build it unconditionally and guard its _use_ with a boolean
  (`const grain = ...; if (enabled) grain.apply(...)`). Otherwise name the optional `maybe_foo` so
  the capture stays clean (`if (maybe_grain) |grain|`)
- **No recursion**: no function calls itself at runtime, directly or through a cycle. Runtime
  recursion has no static depth bound and can overrun the stack. Iterate with a bounded loop, or
  unroll a fixed number of steps instead of a recursive solver. This targets runtime calls: a
  generic type that names itself in its own method signatures (`List(T)` whose methods take or
  return `List(T)`) is a comptime type reference. Comptime recursion is bounded by the
  evaluation-branch quota, so any runaway fails at compile time and never overruns the stack.
  Neither is what this rule forbids
- **Bounded loops**: every loop must provably terminate. A `for` over a fixed range or a fixed-size
  array is fine. A loop whose count comes from runtime input must bound that input: a validated
  length, or an explicit iteration cap on a poll/retry/spin. An intentionally endless loop — an
  idle or event spin (`while (true) {}`) — is the only exception and must be written to read as
  deliberate
- **Struct member order**: fields, then types, then methods
- **Callbacks last**: a callback parameter goes at the end of the parameter list, which mirrors
  that it runs last
- **Options struct for confusable arguments**: when positional arguments can be swapped, pass a
  named-field `options` struct. A function that takes two `u64`s must. Name nullable arguments so
  the meaning of `null` is clear at the call site
- **Lowest return dimensionality**: return the least complex type that works. Prefer `void` over
  `bool`, `bool` over `u64`, `u64` over `?u64`, `?u64` over `!u64`
- **`*const` for large parameters**: pass a parameter as `*const T` when `T` exceeds 16 bytes and
  you do not intend a copy, so an accidental stack copy cannot hide
- **Show rounding intent**: divide with `@divExact`, `@divFloor`, or `div_ceil`, never bare `/`, to
  prove the rounding was considered
