#!/usr/bin/env bash
# Read-only health check for a deployed ledgerlens-score contract instance.
#
# Runs only view calls (get_admin, get_service, is_paused, get_version,
# is_service_alive, get_pending_upgrade) — no state-changing invocation is
# ever issued, so this is safe to run against production at any time.
#
# Usage:
#   ./scripts/health_check.sh <network> <contract-id> [source-identity]
#
# Exit codes:
#   0  all checks passed
#   1  one or more checks failed (contract likely unhealthy or unreachable)
#   2  one or more calls timed out (state unknown — neither a pass nor a clean fail)
#
# Environment:
#   HC_CALL_TIMEOUT_SECS  per-call timeout (default 10); worst-case runtime is
#                         6 * (timeout + 1s kill grace) = 66s at the default.

set -euo pipefail

NETWORK="${1:?ERROR: network argument is required (e.g. testnet, mainnet)}"
CONTRACT_ID="${2:?ERROR: contract-id argument is required}"
SOURCE_IDENTITY="${3:-health-check}"

# shellcheck source=scripts/lib/preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/preflight.sh"
preflight_require timeout soroban || exit 1

FAILURES=0
TIMEOUTS=0
CALL_TIMEOUT_SECS="${HC_CALL_TIMEOUT_SECS:-10}"
readonly KILL_GRACE_SECS=1
readonly CALL_COUNT=6
# Hard upper bound on total runtime: every call is killed after its timeout
# plus the kill grace period. Documented in docs/ops-runbook.md.
MAX_RUNTIME_SECS=$((CALL_COUNT * (CALL_TIMEOUT_SECS + KILL_GRACE_SECS)))

# Output goes to a file, not a pipe, so an orphaned grandchild that keeps the
# stream open cannot outlive the timeout. Exit 124/137 means the call timed out.
invoke() {
  local out rc=0
  out=$(mktemp)
  timeout -k "$KILL_GRACE_SECS" "$CALL_TIMEOUT_SECS" soroban contract invoke \
    --id "$CONTRACT_ID" \
    --source "$SOURCE_IDENTITY" \
    --network "$NETWORK" \
    -- \
    "$@" >"$out" 2>&1 || rc=$?
  cat "$out"
  rm -f "$out"
  return "$rc"
}

check() {
  local label="$1"
  shift
  local output
  local rc=0
  output=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "TIMEOUT  $label: no response within ${CALL_TIMEOUT_SECS}s"
    TIMEOUTS=$((TIMEOUTS + 1))
  elif [ "$rc" -ne 0 ]; then
    echo "FAIL  $label: $output"
    case "$output" in
      *[Aa]rchived*|*ExpiredEntry*)
        echo "HINT  entries are archived: restore them (scripts/rollback.sh does this automatically; or 'soroban contract restore --id $CONTRACT_ID')" ;;
    esac
    FAILURES=$((FAILURES + 1))
  elif [ -n "${EXPECT:-}" ] && ! [[ "$output" =~ $EXPECT ]]; then
    echo "FAIL  $label: unexpected response '$output'"
    FAILURES=$((FAILURES + 1))
  else
    echo "PASS  $label: $output"
  fi
}

echo "== ledgerlens-score health check: $CONTRACT_ID on $NETWORK =="

check "admin address"    invoke get_admin
check "service address"  invoke get_service
EXPECT='^"?(true|false)"?$' check "pause state"      invoke is_paused
EXPECT='^"?[0-9]+"?$'        check "schema version"   invoke get_version
EXPECT='^"?true"?$'          check "service liveness" invoke is_service_alive

# A pending upgrade proposal is optional state: its absence (Error::NoPendingUpgrade,
# discriminant #13) is healthy, not a failure — only a genuine RPC/contract error is.
UPGRADE_RC=0
UPGRADE_OUTPUT=$(invoke get_pending_upgrade 2>&1) || UPGRADE_RC=$?
if [ "$UPGRADE_RC" -eq 0 ]; then
  echo "INFO  pending upgrade: $UPGRADE_OUTPUT"
elif [ "$UPGRADE_RC" -eq 124 ] || [ "$UPGRADE_RC" -eq 137 ]; then
  echo "TIMEOUT  pending upgrade: no response within ${CALL_TIMEOUT_SECS}s"
  TIMEOUTS=$((TIMEOUTS + 1))
else
  case "$UPGRADE_OUTPUT" in
    *NoPendingUpgrade*|*'#13'*)
      echo "PASS  pending upgrade: none"
      ;;
    *)
      echo "FAIL  pending upgrade: $UPGRADE_OUTPUT"
      FAILURES=$((FAILURES + 1))
      ;;
  esac
fi

echo "== $FAILURES check(s) failed, $TIMEOUTS timed out (max runtime ${MAX_RUNTIME_SECS}s) =="
[ "$TIMEOUTS" -eq 0 ] || exit 2
[ "$FAILURES" -eq 0 ]
