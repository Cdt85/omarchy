#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# omarchy device: list reads waiting devices from avahi-browse's parsable
# output, and ssh-config turns the adopted ones into Host blocks ~/.ssh/config
# includes, so ssh <device> works.

require_command jq

tmp=$(cd -- "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/devices" "$tmp/ssh"
export PATH="$tmp/bin:$ROOT/bin:$PATH" OMARCHY_DEVICES_DIR=$tmp/devices OMARCHY_SSH_DIR=$tmp/ssh

# A Spark seen over IPv6 and IPv4, with the removal line avahi also prints.
cat >"$tmp/bin/avahi-browse" <<'SH'
#!/bin/bash
cat <<'OUT'
+;wlan0;IPv4;spark-7649;_omarchy-adopt._tcp;local
=;wlan0;IPv6;spark-7649;_omarchy-adopt._tcp;local;spark-7649.local;fe80::4ebb:47ff:feeb:7649;22;"version=4.5.0" "model=NVIDIA DGX Spark" "platform=aarch64-gb10"
=;wlan0;IPv4;spark-7649;_omarchy-adopt._tcp;local;spark-7649.local;192.168.0.226;22;"version=4.5.0" "model=NVIDIA DGX Spark" "platform=aarch64-gb10"
OUT
SH
chmod +x "$tmp/bin/avahi-browse"

listed=$(omarchy-device-list --json)
if [[ $(jq -c '.' <<<"$listed") == '[{"name":"spark-7649","host":"spark-7649.local","address":"192.168.0.226","state":"waiting","platform":"aarch64-gb10","model":"NVIDIA DGX Spark","version":"4.5.0"}]' ]]; then
  pass "a waiting device is listed once, at its IPv4 address, with its model"
else
  fail "waiting device parsed as $listed"
fi

printf '{"name":"spark-7649","host":"spark-7649.local","user":"ryan","key":"%s"}\n' "$tmp/ssh/omarchy-adopt" \
  >"$tmp/devices/spark-7649.json"
if [[ $(omarchy-device-list --json | jq -r '.[0].state') == "waiting" ]]; then
  pass "a reinstalled device shows as waiting, ready to adopt again"
else
  fail "a reinstalled device should show as waiting"
fi

printf 'Host work\n  User me\n' >"$tmp/ssh/config"
omarchy-device-ssh-config
omarchy-device-ssh-config

config=$tmp/ssh/config.d/omarchy-devices
if grep -qxF "Host spark-7649" "$config" && grep -qxF "  User ryan" "$config" &&
  grep -qxF "  HostKeyAlias spark-7649" "$config" && grep -qxF "  IdentitiesOnly yes" "$config"; then
  pass "an adopted device gets a Host block with its user, key and pinned host key"
else
  fail "unexpected Host block: $(cat "$config")"
fi

if [[ $(head -n1 "$tmp/ssh/config") == "Include $config" ]] &&
  (($(grep -c "^Include $config$" "$tmp/ssh/config") == 1)) && grep -qxF "Host work" "$tmp/ssh/config"; then
  pass "~/.ssh/config includes it once, ahead of the existing Host blocks"
else
  fail "unexpected ~/.ssh/config: $(cat "$tmp/ssh/config")"
fi
