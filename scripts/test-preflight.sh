#!/usr/bin/env bash
# Hermetic tests for scripts/lib/preflight.sh and its use in the shell tooling:
# a missing, relative-path, world-writable-dir, hash-mismatched or too-old
# binary must fail early with a clear PREFLIGHT ERROR.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BASH_BIN=$(type -P bash)

mkdir -p "$TMP/safe" "$TMP/open" "$TMP/empty"; chmod 755 "$TMP" "$TMP/empty"
chmod 755 "$TMP/safe"
chmod 777 "$TMP/open"
for d in safe open; do
  printf '#!/usr/bin/env bash\necho "fakecli 1.2.3"\n' >"$TMP/$d/fakecli"
  chmod +x "$TMP/$d/fakecli"
done
for tool in bash dirname mktemp cat rm date sha256sum awk jq stat sort head grep tr; do
  ln -s "$(type -P "$tool")" "$TMP/empty/$tool"
done

pass=0
fail=0
expect() { # <desc> <want-exit> <want-substring> <cmd...>
  local desc="$1" want="$2" msg="$3" out rc=0
  shift 3
  out=$("$@" 2>&1) || rc=$?
  if [ "$rc" -eq "$want" ] && [[ "$out" == *"$msg"* ]]; then
    echo "ok   - $desc"
    pass=$((pass + 1))
  else
    echo "FAIL - $desc (exit $rc, want $want; output: $out)"
    fail=$((fail + 1))
  fi
}

pf() { env PATH="$1" "$BASH_BIN" -c "source '$SCRIPT_DIR/lib/preflight.sh'; preflight_require \"\$@\"" _ "${@:2}"; }

expect "binary in a safe directory passes" 0 "" pf "$TMP/safe:$TMP/empty" 'fakecli>=1.0.0'
expect "missing binary is reported by name" 1 "'nosuchtool' was not found" pf "$TMP/safe" nosuchtool
expect "binary too old is rejected" 1 "older than the required 9.0.0" pf "$TMP/safe:$TMP/empty" 'fakecli>=9.0.0'
expect "binary in a world-writable dir is rejected" 1 "possible PATH hijack" pf "$TMP/open:$TMP/empty" fakecli
expect "relative PATH entry is rejected" 1 "relative path" \
  env PATH="safe:$TMP/empty" "$BASH_BIN" -c "cd '$TMP'; source '$SCRIPT_DIR/lib/preflight.sh'; preflight_require fakecli"
expect "pinned SHA-256 mismatch is rejected" 1 "expected deadbeef" \
  env PREFLIGHT_FAKECLI_SHA256=deadbeef PATH="$TMP/safe:$TMP/empty" "$BASH_BIN" -c "source '$SCRIPT_DIR/lib/preflight.sh'; preflight_require fakecli"
expect "pinned SHA-256 match passes" 0 "" \
  env PREFLIGHT_FAKECLI_SHA256="$(sha256sum "$TMP/safe/fakecli" | awk '{print $1}')" PATH="$TMP/safe:$TMP/empty" "$BASH_BIN" -c "source '$SCRIPT_DIR/lib/preflight.sh'; preflight_require fakecli"
expect "alternatives: first present wins" 0 "" pf "$TMP/safe:$TMP/empty" 'nosuch|fakecli'

# Scripts fail early (before any other work) when the CLI is absent.
expect "rollback.sh fails early without soroban" 1 "PREFLIGHT ERROR" \
  env PATH="$TMP/empty" "$BASH_BIN" "$SCRIPT_DIR/rollback.sh" testnet admin CONTRACT /nonexistent.wasm
expect "rotate-keys-rehearsal.sh fails early without soroban" 1 "PREFLIGHT ERROR" \
  env PATH="$TMP/empty" "$BASH_BIN" "$SCRIPT_DIR/rotate-keys-rehearsal.sh"
expect "health_check.sh fails early without soroban" 1 "PREFLIGHT ERROR" \
  env PATH="$TMP/empty" "$BASH_BIN" "$SCRIPT_DIR/health_check.sh" testnet CONTRACT

echo ""
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
