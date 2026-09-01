#!/bin/sh
# Run the test suite and fail if a test in the source did not run. Zig
# compiles a test only when an import chain from the module root reaches its
# file, so a test in an unreachable file passes silently (see the Architecture
# section in AGENTS.md). No two modules share a file, so the number of `test`
# blocks in the source must equal the number that the runner reports. A
# mismatch means that a test went dark.
set -eu

summary=$(zig build test --summary all 2>&1) || {
    printf '%s\n' "$summary"
    exit 1
}
printf '%s\n' "$summary"

ran=$(printf '%s\n' "$summary" | grep -oE '[0-9]+/[0-9]+ tests passed' | grep -oE '^[0-9]+')
declared=$(grep -rhE '^test ' src lib --include='*.zig' | wc -l | tr -d ' ')

if [ "${ran:-0}" != "$declared" ]; then
    printf 'test-audit: %s tests declared in source but only %s ran.\n' "$declared" "${ran:-0}" >&2
    printf 'A test file is not reachable from its module root (see AGENTS.md Architecture).\n' >&2
    exit 1
fi

printf 'test-audit: all %s declared tests ran.\n' "$declared"
