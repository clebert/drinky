#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

zig build
zig fmt --check build.zig build.zig.zon src lib scripts
zig run scripts/comment_scan.zig -- build.zig build.zig.zon src lib scripts
zig run scripts/width_scan.zig -- build.zig build.zig.zon src lib scripts

for file in $(grep -rl 'checkAllAllocationFailures(' src lib scripts --include='*.zig'); do
    if tr -d ' \n' <"$file" | grep -oE 'checkAllAllocationFailures\([^,]*,' |
        grep -qv 'no_resize_allocator,$'; then
        printf 'check: %s runs checkAllAllocationFailures on an allocator that can resize.\n' \
            "$file" >&2
        printf 'Its allocation count can change between runs. Use core.testing.no_resize_allocator.\n' >&2
        exit 1
    fi
done

npx --yes prettier@3 --check --log-level warn '**/*.md'

summary=$(zig build test --summary all 2>&1) || {
    printf '%s\n' "$summary"
    exit 1
}
printf '%s\n' "$summary"

ran=$(printf '%s\n' "$summary" | grep -oE '/[0-9]+ tests passed' | grep -oE '[0-9]+')
declared=$(grep -rhE '^test ' src lib scripts --include='*.zig' | wc -l | tr -d ' ')

if [ "${ran:-0}" != "$declared" ]; then
    printf 'check: %s tests declared in source but only %s ran.\n' "$declared" "${ran:-0}" >&2
    printf 'A test file is not reachable from its module root.\n' >&2
    exit 1
fi

printf 'check: all %s declared tests ran.\n' "$declared"
