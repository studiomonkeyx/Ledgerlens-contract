#!/usr/bin/env bash
# Regression test: scripts/rollback.sh must restore archived storage entries
# and retry, instead of failing with a raw archived-entry error mid-rollback.
# A stub `soroban` reports entries as archived until `contract restore` runs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"; chmod 755 "$TMP" "$TMP/bin"
echo "wasm" >"$TMP/prev.wasm"

cat >"$TMP/bin/soroban" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$*" in
  *"contract restore"*) touch "$STUB_STATE/restored"; echo "restored"; exit 0 ;;
  *"keys address"*) echo "GADMIN"; exit 0 ;;
esac
if [ "${ARCHIVED:-1}" = "1" ] && [ ! -f "$STUB_STATE/restored" ]; then
  echo "error: HostError: entry is archived, restore the footprint first" >&2
  exit 1
fi
echo "ok"
STUB
chmod +x "$TMP/bin/soroban"

run_rollback() {
  env PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" STUB_STATE="$TMP" ARCHIVED="$1" \
    bash "$SCRIPT_DIR/rollback.sh" --non-interactive testnet admin CONTRACT "$TMP/prev.wasm"
}

fail=0
rm -f "$TMP/restored" "$TMP/log"
if run_rollback 1 >"$TMP/out" 2>&1 && grep -q "contract restore" "$TMP/log" && grep -q "Rollback complete" "$TMP/out"; then
  echo "ok   - archived entries are restored and the rollback completes"
else
  echo "FAIL - archived scenario"; cat "$TMP/out"; fail=1
fi

rm -f "$TMP/restored" "$TMP/log"
if run_rollback 0 >"$TMP/out" 2>&1 && ! grep -q "contract restore" "$TMP/log"; then
  echo "ok   - no restore issued when nothing is archived"
else
  echo "FAIL - healthy scenario"; cat "$TMP/out"; fail=1
fi
exit "$fail"
