#!/bin/sh
# Zig runs a test only when an import chain from a module root reaches its file.
# No two modules share a file, so the declared and executed test counts must match.
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
    printf 'A test file is not reachable from its module root.\n' >&2
    exit 1
fi

printf 'test-audit: all %s declared tests ran.\n' "$declared"
