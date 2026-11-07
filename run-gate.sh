#!/usr/bin/env bash
# The gate for goose-process, for one Goose release.
#
#   TMPDIR=/some/dir bash run-gate.sh /path/to/goose-vX.Y.Z
#
# It checks the entry file, runs and builds the tests, then runs and builds
# each example. The package has a C sidecar, so "goose run" builds the C
# into a library that the in-process run loads.
set -uo pipefail

compiler_dir="${1:-}"
# Windows ships goose.exe.
goose="$compiler_dir/goose"
[[ -x "$goose" ]] || goose="$compiler_dir/goose.exe"
if [[ -z "$compiler_dir" || ! -x "$goose" ]]; then
    echo "usage: TMPDIR=dir bash run-gate.sh <goose-release-dir>" >&2
    exit 2
fi
if [[ -z "${TMPDIR:-}" || ! -d "$TMPDIR" ]]; then
    echo "run-gate.sh: set TMPDIR to an existing scratch directory" >&2
    exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d "$TMPDIR/proc-gate.XXXXXX")"
trap 'rm -rf "$work"' EXIT
cd "$here"

step() {
    local name="$1"
    shift
    if "$@" > "$work/log" 2>&1; then
        echo "ok $name"
    else
        echo "FAIL $name"
        tail -n 30 "$work/log"
        exit 1
    fi
}

echo "compiler: $("$goose" version 2>&1 | head -n 1)"
step "check process.goose" "$goose" check process.goose
step "run test/run.goose" "$goose" run test/run.goose
step "build test/run.goose" "$goose" build test/run.goose -o "$work/test-run"
step "run built test" bash -c "cd '$here' && '$work/test-run'"

shopt -s nullglob
for example in examples/*.goose; do
    name="$(basename "$example" .goose)"
    step "run $example" "$goose" run "$example"
    step "build $example" "$goose" build "$example" -o "$work/ex-$name"
    step "run built $example" bash -c "cd '$here' && '$work/ex-$name'"
done
echo "gate passed"
