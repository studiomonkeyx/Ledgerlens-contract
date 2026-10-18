# Script preflight convention

Shell tooling must verify its external binaries before doing any real work.
Source `scripts/lib/preflight.sh` and call `preflight_require` right after
argument parsing:

```bash
source "$(dirname "${BASH_SOURCE[0]}")/lib/preflight.sh"
preflight_require jq sha256sum 'stellar|soroban' 'timeout'   # 'a|b' = first found
preflight_require 'jq>=1.6'                                  # minimum version
```

A binary is rejected (with a `PREFLIGHT ERROR:` message, exit 1) when it is
missing, resolves to a relative path, lives in a world-writable directory
without the sticky bit (PATH-hijack vector), fails an opt-in hash pin, or is
older than the stated minimum.

## Coverage

| Script | Required binaries |
| --- | --- |
| `scripts/health_check.sh` | `timeout`, `soroban` |
| `scripts/rollback.sh` | `sha256sum`, `awk`, `soroban` (not in `--dry-run`) |
| `scripts/staging-upgrade.sh` | `sha256sum`, `stellar` or `soroban` (not in `--dry-run`) |
| `scripts/rotate-keys-rehearsal.sh` | `jq`; `soroban`, `cargo` (not in `--dry-run`) |

Tests: `scripts/test-preflight.sh`.

## Hardening decision for signing / key-material scripts

`rollback.sh`, `staging-upgrade.sh` and `rotate-keys-rehearsal.sh` invoke the
CLI with an admin identity. Decision: **resolve-and-verify by default, hash
pinning opt-in.** Absolute-path pinning is not adopted as a default because
operators install the CLI via cargo, Nix or distro packages in different
places. Instead the preflight rejects relative and world-writable resolutions,
and high-assurance environments (mainnet operators) should set
`PREFLIGHT_SOROBAN_SHA256` / `PREFLIGHT_STELLAR_SHA256` to the reviewed
binary's SHA-256 (see `toolchain-versions.json`), which the preflight then
enforces. Residual risk when no pin is set: a malicious binary in a
non-world-writable directory earlier on `PATH` owned by the same user is not
detected; that requires an already-compromised account.
