#!/usr/bin/env bash
# Deterministic self-test for deploy/validate_manifest.sh. Exercises the
# success path and each rejection case (bad schema, out-of-bounds delay/
# cooldown/threshold, invalid service address, mainnet default identity)
# against fixture manifests. Makes no network calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../deploy/validate_manifest.sh
source "$REPO_ROOT/deploy/validate_manifest.sh"

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

VALID_ADMIN="operator"
VALID_SERVICE="GBZXN7PIRZGNMHGA7MUUUF4GWPJUEIYSAAWJKGH3PXWXOG7BXUZW7UMB"

write_manifest() {
  cat >"$TMP_DIR/manifest.json" <<EOF
{
  "testnet": { "upgrade_delay_secs": $1, "cooldown_secs": $2, "risk_threshold": $3, "schema_version": $4 },
  "mainnet": { "upgrade_delay_secs": $1, "cooldown_secs": $2, "risk_threshold": $3, "schema_version": $4 }
}
EOF
}

pass=0
fail=0

expect_ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "ok   - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL - $desc (expected success, got failure)"
    fail=$((fail + 1))
  fi
}

expect_fail() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "FAIL - $desc (expected failure, got success)"
    fail=$((fail + 1))
  else
    echo "ok   - $desc"
    pass=$((pass + 1))
  fi
}

# Valid manifest, valid inputs.
write_manifest 172800 3600 75 4
expect_ok "valid manifest passes for testnet" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"
expect_ok "valid manifest passes for mainnet with non-default identity" \
  validate_manifest mainnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

# Schema mismatch.
write_manifest 172800 3600 75 99
expect_fail "stale schema_version is rejected" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

# Upgrade delay below the on-chain minimum.
write_manifest 60 3600 75 4
expect_fail "upgrade_delay_secs below minimum is rejected" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

# Cooldown above the on-chain maximum.
write_manifest 172800 999999 75 4
expect_fail "cooldown_secs above maximum is rejected" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

# Risk threshold out of range.
write_manifest 172800 3600 150 4
expect_fail "risk_threshold above 100 is rejected" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

# Invalid service address format.
write_manifest 172800 3600 75 4
expect_fail "malformed service address is rejected" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "not-a-stellar-address"

# Mainnet refuses the default 'deployer' identity.
expect_fail "mainnet rejects the default 'deployer' admin identity" \
  validate_manifest mainnet "$TMP_DIR/manifest.json" "deployer" "$VALID_SERVICE"

# Missing network entry.
expect_fail "missing network entry in manifest is rejected" \
  validate_manifest devnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

# ── Live-consistency layer (stubbed CLI, no network) ──────────────────────
STUB_CLI="$TMP_DIR/stub-cli"
cat >"$STUB_CLI" <<'STUB'
#!/usr/bin/env bash
[ "${STUB_MODE:-}" = "down" ] && { echo "connection refused" >&2; exit 1; }
[ "${STUB_MODE:-}" = "hang" ] && exec sleep 30
case "${*: -1}" in
  get_version) echo "4" ;;
  get_admin) echo '"GADMINLIVE"' ;;
  get_service) echo "GSERVICELIVE" ;;
esac
STUB
chmod +x "$STUB_CLI"
export MANIFEST_LIVE_CLI="$STUB_CLI" MANIFEST_LIVE_TIMEOUT_SECS=1

# write_live <deployed_version claim> <expected_admin claim> <network claim>
write_live() {
  cat >"$TMP_DIR/live.json" <<LIVE
{ "testnet": { "network": "$3", "deployed_version": $1, "expected_admin": "$2", "expected_service": "GSERVICELIVE" },
  "mainnet": { "deployed_version": $1 } }
LIVE
}
live() { validate_manifest_live "$1" "$TMP_DIR/live.json" CONTRACT1 operator; }

write_live 4 GADMINLIVE testnet
expect_ok "live: consistent manifest passes" live testnet
write_live 3 GADMINLIVE testnet
expect_fail "live: schema-valid manifest with wrong deployed_version is rejected" live testnet
mismatch_msg=$(live testnet 2>&1 || true)
case "$mismatch_msg" in
  *"claims get_version=3"*"reports 4"*) echo "ok   - live: mismatch message is specific"; pass=$((pass + 1)) ;;
  *) echo "FAIL - live: mismatch message not specific: $mismatch_msg"; fail=$((fail + 1)) ;;
esac
write_live 4 GOTHERADMIN testnet
expect_fail "live: wrong expected_admin is rejected" live testnet
write_live 4 GADMINLIVE mainnet
expect_fail "live: manifest section naming the wrong network is rejected" live testnet
write_live 4 GADMINLIVE testnet
STUB_MODE=down expect_fail "live: unreachable target fails closed" live testnet
STUB_MODE=hang expect_fail "live: hanging target fails closed" live testnet
expect_fail "live: mainnet without contract id is rejected (mandatory)" \
  validate_manifest_live mainnet "$TMP_DIR/live.json" "" operator
expect_ok "live: testnet without contract id is skipped" \
  validate_manifest_live testnet "$TMP_DIR/live.json" "" operator
write_manifest 172800 3600 75 4
expect_ok "schema-only validation unchanged for consistent manifest" \
  validate_manifest testnet "$TMP_DIR/manifest.json" "$VALID_ADMIN" "$VALID_SERVICE"

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
