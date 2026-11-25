#!/usr/bin/env bash
set -Eeuo pipefail

# Copy fixture variables and mocks, but give the assertion a fresh Bash execution
# context: an outer `if` must not disable errexit inside the function under test.
run_in_bash() {
  {
    declare -p | sed -E '/^declare -[^ ]* (BASH[^ =]*|EUID|UID|PPID|SHELLOPTS|GROUPS|DIRSTACK|FUNCNAME|LINENO|RANDOM|SRANDOM|SECONDS|PIPESTATUS|_)=/d'
    declare -f
    printf '\n%s\n' "$1"
  } | bash -Eeuo pipefail -s
}
export -f run_in_bash

expect_bash_failure() {
  local failure_output
  if failure_output=$(run_in_bash "$2" 2>&1); then
    printf 'FAIL: expected failure: %s\n' "$2" >&2
    return 1
  fi
  if ! grep -Fq -- "$1" <<<"$failure_output"; then
    printf 'FAIL: missing diagnostic [%s]:\n%s\n' "$1" "$failure_output" >&2
    return 1
  fi
}
export -f expect_bash_failure
