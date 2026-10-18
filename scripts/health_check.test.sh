#!/usr/bin/env bash
# Deterministic smoke tests for health_check.sh.
#
# Stubs the `soroban` CLI on PATH so these run without a live network, a
# deployed contract, or the soroban toolchain installed — fast and hermetic.
#
# Usage: ./scripts/health_check.test.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HEALTH_CHECK="$SCRIPT_DIR/health_check.sh"
STUB_DIR=$(mktemp -d)
OUT_FILE=$(mktemp)
trap 'rm -rf "$STUB_DIR" "$OUT_FILE"' EXIT

cat > "$STUB_DIR/soroban" <<'STUB'
#!/usr/bin/env bash
# Canned soroban CLI responses, keyed by $MODE, for health_check.test.sh.
fn=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "--" ]; then
    fn="$arg"
    break
  fi
  prev="$arg"
done

case "${MODE:-}" in
  hang) exec sleep 60 ;;
  slowloris) while :; do printf 'x'; sleep 1; done ;;
  contradictory)
    case "$fn" in
      is_paused) echo "maybe"; exit 0 ;;
      is_service_alive) echo "false"; exit 0 ;;
      get_version) echo "not-a-number"; exit 0 ;;
    esac
    ;;
esac

case "$fn" in
  get_admin)
    if [ "${MODE:-}" = "admin_unreachable" ]; then
      echo "error: connection refused" >&2
      exit 1
    fi
    echo "GADMIN..."
    ;;
  get_service) echo "GSERVICE..." ;;
  is_paused) echo "false" ;;
  get_version) echo "4" ;;
  is_service_alive) echo "true" ;;
  get_pending_upgrade)
    case "${MODE:-}" in
      upgrade_pending) echo '{"new_wasm_hash":"abc","executable_after":123}' ;;
      *)
        echo "error: HostError: Error(Contract, #13)" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "stub: unknown function '$fn'" >&2
    exit 1
    ;;
esac
STUB
chmod +x "$STUB_DIR/soroban"

pass=0
fail=0

assert_exit() {
  local desc="$1" expected="$2"
  shift 2
  local actual=0
  "$@" >"$OUT_FILE" 2>&1 || actual=$?
  if [ "$actual" -eq "$expected" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc (expected exit $expected, got $actual)"
    cat "$OUT_FILE"
  fi
}

# ── Boundary case: required arguments missing ──────────────────────────────
assert_exit "missing network/contract-id exits non-zero" 1 \
  bash -c "'$HEALTH_CHECK'"

# ── Success path: every check reports healthy ──────────────────────────────
assert_exit "healthy contract exits 0" 0 \
  env PATH="$STUB_DIR:$PATH" MODE=healthy "$HEALTH_CHECK" testnet CONTRACT123 health-check

# ── Boundary case: no pending upgrade is healthy, not a failure ────────────
assert_exit "absent pending upgrade still exits 0" 0 \
  env PATH="$STUB_DIR:$PATH" MODE=healthy "$HEALTH_CHECK" testnet CONTRACT123 health-check

# ── Boundary case: a pending upgrade is reported, still exits 0 ────────────
assert_exit "pending upgrade present exits 0" 0 \
  env PATH="$STUB_DIR:$PATH" MODE=upgrade_pending "$HEALTH_CHECK" testnet CONTRACT123 health-check

# ── Adversarial: RPC/node unreachable on a core call must be reported, not silently swallowed ──
assert_exit "unreachable admin call exits non-zero" 1 \
  env PATH="$STUB_DIR:$PATH" MODE=admin_unreachable "$HEALTH_CHECK" testnet CONTRACT123 health-check

# ── Pathological targets: bounded time, distinct TIMEOUT result (exit 2) ────
# 6 calls, each killed after HC_CALL_TIMEOUT_SECS (+1s grace): worst case 12s.
export HC_CALL_TIMEOUT_SECS=1
WORST_CASE_SECS=$((6 * (HC_CALL_TIMEOUT_SECS + 1)))

assert_bounded() {
  local desc="$1" expected="$2" mode="$3" start elapsed actual=0
  start=$(date +%s)
  env PATH="$STUB_DIR:$PATH" MODE="$mode" "$HEALTH_CHECK" testnet CONTRACT123 health-check >"$OUT_FILE" 2>&1 || actual=$?
  elapsed=$(( $(date +%s) - start ))
  if [ "$actual" -eq "$expected" ] && [ "$elapsed" -le "$WORST_CASE_SECS" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc (exit $actual, expected $expected; ${elapsed}s, bound ${WORST_CASE_SECS}s)"
    cat "$OUT_FILE"
  fi
}

assert_bounded "hanging target times out with exit 2" 2 hang
grep -q '^TIMEOUT ' "$OUT_FILE" || { fail=$((fail + 1)); echo "FAIL: hang not labeled TIMEOUT"; }
assert_bounded "slow-drip target times out with exit 2" 2 slowloris
grep -q '^TIMEOUT ' "$OUT_FILE" || { fail=$((fail + 1)); echo "FAIL: slowloris not labeled TIMEOUT"; }
assert_bounded "contradictory responses fail (exit 1), not pass or timeout" 1 contradictory
grep -q "unexpected response" "$OUT_FILE" || { fail=$((fail + 1)); echo "FAIL: contradictory response not flagged"; }
assert_bounded "clean pass stays exit 0 under the timeout wrapper" 0 healthy

# ── Missing required binary fails early with a clear message ───────────────
EMPTY_BIN=$(mktemp -d)
for tool in bash dirname mktemp cat rm date; do ln -s "$(type -P "$tool")" "$EMPTY_BIN/$tool"; done
assert_exit "missing soroban fails at preflight" 1 \
  env PATH="$EMPTY_BIN" "$(type -P bash)" "$HEALTH_CHECK" testnet CONTRACT123 health-check
grep -q "PREFLIGHT ERROR" "$OUT_FILE" || { fail=$((fail + 1)); echo "FAIL: no preflight message"; cat "$OUT_FILE"; }
rm -rf "$EMPTY_BIN"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
