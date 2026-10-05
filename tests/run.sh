#!/usr/bin/env bash
# np_flightradar test runner: `luac -p` on every Lua file (html/ excluded), then every tests/test_*.lua in
# its own Lua 5.4 process (client and server get separate states in FiveM too).
# Usage: tests/run.sh        (VERBOSE=1 shows the resource's own log lines)
set -u
cd "$(dirname "$0")/.."
LUA="${LUA:-lua}"
LUAC="${LUAC:-luac}"
fail=0

echo "== syntax (luac -p)"
count=0
while IFS= read -r -d '' f; do
  count=$((count + 1))
  if ! "$LUAC" -p "$f"; then fail=1; fi
done < <(find . -name '*.lua' -not -path './html/*' -not -path './.git/*' -print0)
echo "   $count files checked"

for t in tests/test_*.lua; do
  echo "== $t"
  "$LUA" "$t" || fail=1
done

if [ "$fail" -ne 0 ]; then
  echo "FAILED"
  exit 1
fi
echo "ALL PASSED"
