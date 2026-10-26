---
name: zig-style
description:
  Zig code-style conventions for this environment. The rules cover names, modules, types, control
  flow, ownership, errors, and concurrency. Load before you write, edit, or review Zig so the code
  follows the shared conventions.
---

# Zig code style

- **Formatting**: `tab_size: 4`, `print_width: 100`.
- **Types**: `PascalCase`, acronyms as single words (`Json`, not `JSON`).
- **File names**: `PascalCase.zig` for a struct module, where the file is a struct through
  `@This()`. `snake_case.zig` for a namespace module. It holds functions and constants, and no
  struct field.
- **Functions**: `camelCase`.
- **Variables**: `snake_case`.
- **SIMD**: `@Vector` types for hardware-accelerated calculations.
- **No abbreviations**: full names (`distance`, not `dist`), except where the standard library sets
  the convention (`prng`, after `std.Random.DefaultPrng`).
- **Units and qualifiers last, most significant first**: put a unit or qualifier at the end of a
  name and order words by descending significance. Write `latency_ms_max`, not `max_latency_ms`, so
  `latency_ms_min` lines up and latency names group together.
- **Line names up**: give related names the same length so they align in source. Write
  `source`/`target`, not `src`/`dest`, so `source_offset`/`target_offset` match.
- **No redundant names in qualified paths**: you always read a declaration through its namespace, so
  do not repeat that namespace in the name. A struct file in `widget/` is `Button.zig`, used as
  `widget.Button`, never `WidgetButton`. A function in `parse.zig` is `parse.token`, not
  `parse.parseToken`.
- **No underscore prefixes**: never lead an identifier with `_` to mean "private" or "internal".
  Visibility is `pub` or its absence, and a bare `_` is only the discard binding.
- **No aliases**: use the qualified name (`foo.Bar`) directly, never `const FooBar = foo.Bar`.
- **No re-exports**: do not re-export imports (`pub const foo = @import("foo.zig")`). Only
  `root.zig` can, for the public API.
- **Subsystems are namespaces, not prefixes**: keep a family of related modules in a subdirectory
  and expose it as one namespace, so call sites read `widget.Button`. Never flatten them into the
  parent with a shared prefix (`WidgetButton`, `WidgetPanel`). `root.zig` owns the export that forms
  the namespace.
- **`root.zig` exports, never feeds**: `root.zig` imports its subsystem's modules to form the public
  namespace. No module ever imports its own subsystem's `root.zig`, because that inverts the
  dependency and cycles the imports. A module that needs a sibling imports that sibling directly.
- **Shared types nest in their owning module**: a union or enum that several modules of a subsystem
  share lives as a nested `pub` type. The struct module that owns that seam holds that type. The
  parser owns its token (`Parser.Token`), and the widget owns its style (`Button.Style`). It never
  lives in `root.zig` (exports only), and never in a file of its own. A file is always a struct, so
  a union-as-file is impossible. The rules above ban both workarounds: a stuttering `token.Token`
  path and a single-declaration alias.
- **Unused code**: delete code without a caller. Do not mark unused code `pub` to silence warnings.
  Remove tests that exist only to exercise it. A symbol that another module consumes is real API, so
  keep it and its symmetric constants. A test in _another_ module counts as a consumer. `Limit.min`
  is such a symbol, and `Limit.max` stays with it.
- **Const slices**: `[]const T` for a read-only slice parameter, `[]T` only for an output buffer.
- **Optional captures**: never accept a shadow-forced capture name (`if (buffer) |b|`). If the value
  is cheap, build it unconditionally and guard its _use_ with a boolean
  (`const buffer = ...; if (enabled) buffer.write(...)`). Otherwise name the optional `maybe_foo` so
  the capture stays clean (`if (maybe_buffer) |buffer|`).
- **Types state the rules**: build a value so that the compiler rejects a state that has no meaning.
  Use a tagged union for alternatives that carry different data. Do not use a struct whose fields
  apply only in some states. Give each union payload only the fields that it uses.
- **No sentinels**: use an optional for an absent value. Do not use an empty string, a zero, or a
  flag to mean "absent".
- **Exhaustive switches**: use an exhaustive switch for behavior that varies by enum tag. Handle
  each tag when you switch on an enum or a union that the project defines. Do not write `else`
  there. A new tag must stop the build until each switch handles it.
- **Impossible states**: do not read a union field because another value implies its tag. Carry the
  data in the value itself. Give a function a narrow enum, not a wide one with an `unreachable`
  branch. For a branch that no production path reaches and the types cannot exclude, use an
  assertion or `unreachable`. Put no text for the user in that branch.
- **No recursion**: no function calls itself at runtime, directly or through a cycle. Runtime
  recursion has no static depth bound and can overrun the stack. Iterate with a bounded loop, or
  unroll a fixed number of steps instead of a recursive solver. This rule targets a runtime call. A
  generic type that names itself in its own method signatures is a comptime type reference.
  `List(T)` whose methods take or return `List(T)` is such a type. The evaluation-branch quota
  bounds comptime recursion, so a runaway fails at compile time and never overruns the stack. This
  rule forbids neither the type reference nor the comptime recursion.
- **Bounded loops**: every loop must provably terminate. A `for` over a fixed range or a fixed-size
  array is fine. A loop whose count comes from runtime input must bound that input. Use a validated
  length, or an explicit iteration cap on a poll, a retry, or a spin. An idle or event spin
  (`while (true) {}`) is the only exception. It must read as deliberate.
- **Struct member order**: fields, then types, then methods.
- **Callbacks last**: a callback parameter goes at the end of the parameter list, which mirrors that
  it runs last.
- **Options struct for confusable arguments**: when a call site can swap two positional arguments by
  accident, pass a named-field `options` struct. A function that takes two `u64`s must. Name
  nullable arguments so the meaning of `null` is clear at the call site.
- **Lowest return dimensionality**: return the least complex type that works. Prefer `void` over
  `bool`, `bool` over `u64`, `u64` over `?u64`, `?u64` over `!u64`.
- **`*const` for large parameters**: pass a parameter as `*const T` when `T` exceeds 16 bytes and
  you do not intend a copy. An accidental stack copy then cannot hide.
- **Show rounding intent**: divide with `@divExact`, `@divFloor`, or `@divCeil`, and never with a
  bare `/`. The choice proves that you considered the rounding.
- **Explicit contracts**: a seam is a pointer with a vtable in the shape of `std.mem.Allocator`. Do
  not pass the implementation of a contract as `anytype`. Use a seam or a generic type to state the
  contract.
- **Explicit error sets**: a seam, a callback, and a function that runs under a timeout declare
  their error set. Do not widen an error set to `anyerror`.
- **Event ownership**: an event payload type owns its `dupe` and its `deinit`.
- **Allocation failures**: propagate `error.OutOfMemory` and release partial allocations. Never
  suppress an allocation failure, including during cancellation or cache operations. Convert
  failures from known allocating writers into `error.OutOfMemory`. Keep external write failures
  distinct from allocation failures.
- **Concurrency**: a cancel must end every wait. Run task work in a concurrent task, never inline in
  the caller. Report task creation failures.
