#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Adoption's owner check. omarchy device adopt hands omarchy-provision-owner
# --from-file the owner as JSON over SSH, and anything it cannot set up must be
# refused before the first change, leaving the machine waiting to be adopted.
# adopt_read runs as the script defines it, with the setup form's rules.

require_command jq
require_command ssh-keygen

tmp=$(cd -- "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT

ssh-keygen -q -t ed25519 -N "" -f "$tmp/key"
key=$(<"$tmp/key.pub")

{
  sed -n '/^OMARCHY_USERNAME_PATTERN=/p; /^OMARCHY_RESERVED_USERNAMES=/p; /^OMARCHY_HOSTNAME_PATTERN=/p' \
    "$ROOT/install/provisioning/setup-form.sh"
  sed -n '/^adopt_fail() {/,/^}/p; /^adopt_field() {/,/^}/p; /^adopt_read() {/,/^}/p' "$ROOT/bin/omarchy-provision-owner"
} >"$tmp/adopt.sh"
grep -q '^adopt_read() {' "$tmp/adopt.sh" || fail "omarchy-provision-owner defines adopt_read"

# adopt <json> [taken-user] [encrypted]: the outcome adopt_read reaches.
adopt() {
  bash -c '
    set -euo pipefail
    source "$1"
    PROVISIONING_DIR=$2 LOG_FILE=$2/log taken=$3 encrypted=$4
    log_step() { :; }
    omarchy_username_taken() { [[ $1 == "$taken" ]]; }
    encrypted_install() { [[ -n $encrypted ]]; }
    luks_rekey_pending() { false; }
    adopt_read "$5"
    echo "ok $username sudo=$adopt_sudo session=$adopt_session"
  ' adopt "$tmp/adopt.sh" "$tmp" "${2:-}" "${3:-}" "$1" 2>&1
}

owner() {
  jq -nc --arg key "$key" '{username: "ryan", password_hash: "$6$salt$hash", authorized_keys: [$key],
    hostname: "spark-7649", timezone: "UTC"} + $ARGS.named' "$@"
}

expect() {
  local label=$1 expected=$2 actual=$3
  if [[ $actual == *"$expected"* ]]; then
    pass "$label"
  else
    fail "$label: expected '$expected', got '$actual'"
  fi
}

expect "a complete owner is accepted, headless with sudo by password" \
  "ok ryan sudo=password session=headless" "$(adopt "$(owner)")"
expect "the choices on the adopting computer are kept" \
  "sudo=passwordless session=desktop" "$(adopt "$(owner --arg sudo passwordless --arg session desktop)")"

expect "not JSON" "is not a JSON object" "$(adopt "ryan")"
expect "an invalid username" "invalid username" "$(adopt "$(owner --arg username "Ryan Hughes")")"
expect "a reserved username" "is reserved" "$(adopt "$(owner --arg username root)")"
expect "a taken username" "is taken" "$(adopt "$(owner)" ryan)"
printf 'ryan\n' >"$tmp/setup-user"
expect "the username an earlier attempt pinned resumes" "ok ryan" "$(adopt "$(owner)" ryan)"
rm "$tmp/setup-user"
expect "a password instead of its hash" "crypt(3) hash" "$(adopt "$(owner --arg password_hash hunter2)")"
expect "a full name that would break passwd" "full_name cannot" "$(adopt "$(owner --arg full_name "Ryan:Hughes")")"
expect "an invalid hostname" "invalid hostname" "$(adopt "$(owner --arg hostname "spark_7649")")"
expect "an unknown timezone" "unknown timezone" "$(adopt "$(owner --arg timezone "Mars/Olympus")")"
expect "an unknown sudo policy" "sudo must be" "$(adopt "$(owner --arg sudo always)")"
expect "an unknown session" "session must be" "$(adopt "$(owner --arg session kiosk)")"
expect "no keys" "at least one key" "$(adopt "$(owner --argjson authorized_keys '[]')")"
expect "something that is not a key" "not an SSH public key" "$(adopt "$(owner --argjson authorized_keys '["hello"]')")"
expect "an encrypted machine" "set it up at its console" "$(adopt "$(owner)" "" encrypted)"
