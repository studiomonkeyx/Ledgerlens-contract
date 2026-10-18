#!/usr/bin/env bash
# Shared preflight for scripts that rely on external binaries.
#
# Convention: source this file, then call `preflight_require` as the first
# action after argument parsing, before any state-changing or key-handling
# step. See docs/script-preflight.md.
#
#   preflight_require jq sha256sum 'stellar|soroban' 'timeout'
#   preflight_require 'jq>=1.6'
#
# Each argument is "name[>=min_version]"; "a|b" accepts the first one found
# (the resolved name is exported as PREFLIGHT_RESOLVED_<spec>, and the CLI
# alternative as PREFLIGHT_CLI). A binary is rejected if it is missing, if it
# resolves to a relative path, or if its directory is world-writable
# without the sticky bit (a PATH-hijack vector). If PREFLIGHT_<NAME>_SHA256 is
# set (NAME upper-cased, non-alphanumerics as '_'), the resolved binary's
# SHA-256 must match it.

preflight_fail() {
  echo "PREFLIGHT ERROR: $*" >&2
  return 1
}

preflight__check_path() {
  local name="$1" path="$2" dir perms
  case "$path" in
    /*) ;;
    *) preflight_fail "'$name' resolves to a relative path '$path' (PATH contains a relative entry)"; return 1 ;;
  esac
  dir=$(dirname "$path")
  perms=$(stat -L -c '%A' "$dir" 2>/dev/null || true)
  if [ "${perms:8:1}" = "w" ] && [ "${perms:9:1}" != "t" ]; then
    preflight_fail "'$name' resolves to '$path' in a writable directory ($perms): possible PATH hijack"
    return 1
  fi
}

preflight__check_hash() {
  local name="$1" path="$2" var expected actual
  var="PREFLIGHT_$(printf '%s' "$name" | tr "[:lower:]" "[:upper:]" | tr -c "A-Z0-9\n" "_")_SHA256"
  expected="${!var:-}"
  [ -n "$expected" ] || return 0
  actual=$(sha256sum "$path" | awk '{print $1}')
  [ "$actual" = "$expected" ] || preflight_fail "'$name' at '$path' has SHA-256 $actual, expected $expected ($var)"
}

preflight__check_version() {
  local name="$1" path="$2" min="$3" actual
  actual=$("$path" --version 2>/dev/null | grep -Eo '[0-9]+(\.[0-9]+)+' | head -n 1 || true)
  if [ -z "$actual" ]; then
    preflight_fail "could not determine the version of '$name' (need >= $min)"
    return 1
  fi
  if [ "$(printf '%s\n%s\n' "$min" "$actual" | sort -V | head -n 1)" != "$min" ]; then
    preflight_fail "'$name' version $actual is older than the required $min"
    return 1
  fi
}

preflight_require() {
  local spec alt name min path found
  for spec in "$@"; do
    found=""
    local IFS='|'
    for alt in $spec; do
      IFS=$' \t\n'
      name="${alt%%>=*}"
      min=""
      case "$alt" in *'>='*) min="${alt#*>=}" ;; esac
      path=$(type -P "$name" 2>/dev/null || true)
      [ -n "$path" ] || continue
      preflight__check_path "$name" "$path" || return 1
      preflight__check_hash "$name" "$path" || return 1
      [ -z "$min" ] || preflight__check_version "$name" "$path" "$min" || return 1
      found="$name"
      break
    done
    IFS=$' \t\n'
    if [ -z "$found" ]; then
      preflight_fail "required binary '${spec//|/' or '}' was not found in PATH"
      return 1
    fi
    case "$found" in stellar|soroban) PREFLIGHT_CLI="$found"; export PREFLIGHT_CLI ;; esac
  done
}
