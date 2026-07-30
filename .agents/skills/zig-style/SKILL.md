---
name: zig-style
description:
  Zig code-style conventions for this environment — naming, file/module structure, control flow,
  slices, optional captures, and visibility. Load before writing, editing, or reviewing Zig so code
  matches the documented rules rather than personal taste.
---

# Zig Code Style

- **Formatting**: `tab_size: 4`, `print_width: 100`.
- **Types**: `PascalCase`, acronyms as single words (`Rgb`, not `RGB`)
- **File names**: `PascalCase.zig` for struct modules (file is a struct via `@This()`),
  `snake_case.zig` for namespace modules (functions/constants only, no struct fields)
- **Functions**: `camelCase`
- **Variables**: `snake_case`
- **SIMD**: `@Vector` types for hardware-accelerated calculations
- **No abbreviations**: full names (`distance`, not `dist`) — except where the standard library sets
  the convention (`prng`, after `std.Random.DefaultPrng`)
- **Units and qualifiers last, most significant first**: put a unit or qualifier at the end of a
  name and order words by descending significance — `latency_ms_max`, not `max_latency_ms`, so
  `latency_ms_min` lines up and latency names group together
- **Line names up**: give related names the same length so they align in source — `source`/`target`,
  not `src`/`dest`, so `source_offset`/`target_offset` match
- **No redundant names in qualified paths**: a declaration is always read through its namespace, so
  don't repeat that namespace in the name — a struct file in `widget/` is `Button.zig`, used as
  `widget.Button`, never `WidgetButton`; a function in `parse.zig` is `parse.token`, not
  `parse.parseToken`
- **No underscore prefixes**: never lead an identifier with `_` to mean "private" or "internal" —
  visibility is `pub` or its absence, and a bare `_` is only the discard binding
- **No aliases**: use the qualified name (`foo.Bar`) directly, never `const FooBar = foo.Bar`
- **No re-exports**: don't re-export imports (`pub const foo = @import("foo.zig")`); only `root.zig`
  may, for the public API
- **Subsystems are namespaces, not prefixes**: keep a family of related modules in a subdirectory
  and expose it as one namespace, so call sites read `widget.Button` — never flatten them into the
  parent with a shared prefix (`WidgetButton`, `WidgetPanel`); `root.zig` owns the export that forms
  the namespace
- **`root.zig` exports, never feeds**: `root.zig` imports its subsystem's modules to form the public
  namespace; no module ever imports its own subsystem's `root.zig` — that inverts the dependency and
  cycles the imports. A module that needs a sibling imports that sibling directly
- **Shared types nest in their owning module**: a union or enum that several modules of a subsystem
  share lives as a nested `pub` type in the struct module that owns that seam — the parser owns its
  token (`Parser.Token`), the widget owns its style (`Button.Style`) — never in `root.zig` (exports
  only), and never in a file of its own: a file is always a struct, so a union-as-file is impossible
  and the workarounds (a stuttering `token.Token` path or a single-decl alias) are both banned above
- **No fake `pub`**: don't mark unused code `pub` to silence warnings — remove it, along with any
  tests that exist only to exercise it; a symbol consumed elsewhere (including tests in _other_
  modules, e.g. `Srgb.white`) is real API, so keep it and its symmetric constants
- **Const slices**: `[]const T` for read-only slice parameters, `[]T` only for output buffers
- **Optional captures**: never accept a shadow-forced capture name (`if (grain) |g|`) — if the value
  is cheap, build it unconditionally and guard its _use_ with a boolean
  (`const grain = ...; if (enabled) grain.apply(...)`), otherwise name the optional `maybe_foo` so
  the capture stays clean (`if (maybe_grain) |grain|`)
- **No recursion**: no function calls itself at runtime, directly or through a cycle — runtime
  recursion has no static depth bound and can overrun the stack. Iterate with a bounded loop, or
  unroll a fixed number of steps instead of writing a recursive solver. This targets runtime calls:
  a generic type naming itself in its own method signatures (`List(T)` whose methods take or return
  `List(T)`) is a comptime type reference, and comptime recursion is bounded by the
  evaluation-branch quota — any runaway fails at compile time rather than overrunning the stack — so
  neither is what this rule forbids
- **Bounded loops**: every loop must provably terminate. A `for` over a fixed range or a fixed-size
  array is fine; a loop whose count comes from runtime input must bound that input — a validated
  length, or an explicit iteration cap on a poll/retry/spin. An intentionally endless loop — an idle
  or event spin (`while (true) {}`) — is the only exception and must be written to read as
  deliberate
- **Struct member order**: fields, then types, then methods
- **Callbacks last**: a callback parameter goes at the end of the parameter list, mirroring that it
  runs last
- **Options struct for confusable arguments**: when positional arguments could be swapped, pass a
  named-field `options` struct — a function taking two `u64`s must; name nullable arguments so the
  meaning of `null` is clear at the call site
- **Lowest return dimensionality**: return the least complex type that works — `void` over `bool`,
  `bool` over `u64`, `u64` over `?u64`, `?u64` over `!u64`
- **`*const` for large parameters**: pass a parameter as `*const T` when `T` exceeds 16 bytes and
  you don't intend a copy, so an accidental stack copy can't hide
- **Show rounding intent**: divide with `@divExact`, `@divFloor`, or `div_ceil`, never bare `/`, to
  prove the rounding was considered
