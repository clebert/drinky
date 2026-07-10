#!/bin/sh
# Run the test suite and fail if any test declared in source did not actually
# run. Zig only compiles tests in files reachable from a module's root via a
# used declaration, so a test in an unwired file passes silently (see the Layout
# note in AGENTS.md). Modules never share files, so the number of `test` blocks
# in source must equal the number the runner reports; a mismatch means a test
# went dark.
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
    printf 'A test file is not reachable from its module root (see AGENTS.md Layout).\n' >&2
    exit 1
fi

printf 'test-audit: all %s declared tests ran.\n' "$declared"
