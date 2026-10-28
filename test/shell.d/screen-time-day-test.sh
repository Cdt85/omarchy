#!/bin/bash
#
# The screen time day arithmetic, run against the shared library with a temp
# root and no real machine: the config sanitizer holds the line whatever is on
# disk, and the day counts and blocks the way the daemon reads it.

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

require_command jq

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

export OMARCHY_SCREEN_TIME_ETC="$tmp_dir/etc"
export OMARCHY_SCREEN_TIME_STATE="$tmp_dir/state"
export OMARCHY_SCREEN_TIME_RUN="$tmp_dir/run"
mkdir -p "$OMARCHY_SCREEN_TIME_ETC" "$OMARCHY_SCREEN_TIME_STATE" "$OMARCHY_SCREEN_TIME_RUN"

PATH="$ROOT/bin:$PATH"
source omarchy-screen-time-lib

# The command is documented like the rest of bin/.
grep -q '^# omarchy:summary=' "$ROOT/bin/omarchy-screen-timed" || fail "the daemon carries command metadata"
grep -q '^# omarchy:summary=' "$ROOT/bin/omarchy-screen-time" || fail "the client carries command metadata"
pass "the screen time binaries are documented"

# The sanitizer clamps every value that reaches it, because a daemon that
# crashes on a bad config is unlimited screen time.
garbage='{"active_profile":"nope","profiles":{"kids":{"budget_minutes":{"mon":"90","tue":-5,"sat":9999},"warn_minutes":[5,"x",15,5],"on_empty":"bogus","philosophy":"weird","blocked_periods":[{"label":"  Dinner ","enabled":true,"start":"18:0","end":"19:00"},{"start":"9:00","end":"9:00"}]}},"users":{"sien":{"profile":"kids"},"bad name":{}},"retired":{"hash":"plaintext"}}'
clean=$(st_jq -n --argjson raw "$garbage" '$raw | sanitize_config')
[[ $(jq -r .active_profile <<<"$clean") == kids ]] || fail "an unknown active profile falls back to one that exists"
[[ $(jq -r '.profiles.kids.budget_minutes.mon' <<<"$clean") == 90 ]] || fail "a numeric string budget is read as a number"
[[ $(jq -r '.profiles.kids.budget_minutes.tue' <<<"$clean") == 0 ]] || fail "a negative budget is clamped to zero"
[[ $(jq -r '.profiles.kids.budget_minutes.sat' <<<"$clean") == 1440 ]] || fail "a budget over a day is clamped to a day"
[[ $(jq -c '.profiles.kids.warn_minutes' <<<"$clean") == '[15,5]' ]] || fail "warnings drop the non-numbers and duplicates, high to low"
[[ $(jq -r '.profiles.kids.on_empty' <<<"$clean") == lock ]] || fail "an unknown on_empty falls back to lock"
[[ $(jq -r '.profiles.kids.philosophy' <<<"$clean") == limits ]] || fail "an unknown philosophy falls back to limits"
[[ $(jq -r '.profiles.kids.blocked_periods[0].label' <<<"$clean") == Dinner ]] || fail "a period label is trimmed"
[[ $(jq '.profiles.kids.blocked_periods | length' <<<"$clean") == 1 ]] || fail "a period that starts where it ends is dropped"
[[ $(jq -r '.users | keys | join(",")' <<<"$clean") == sien ]] || fail "a roster entry with an invalid account name is dropped"
[[ $(jq 'has("retired")' <<<"$clean") == false ]] || fail "a field the config no longer has is dropped, as an older config's would be"
pass "sanitize_config clamps budgets, warnings, periods and the roster, and drops what it does not know"

# A day the daemon can read: budget in, spend against it, and what is left.
day=$(st_load_day 4242 "$(st_day_key)" 3600 kids)
[[ $(jq -r .budget_seconds <<<"$day") == 3600 ]] || fail "a fresh day takes the budget it is given"
[[ $(st_jq 'day_remaining' <<<"$day") == 3600 ]] || fail "a fresh day has the whole budget left"
spent=$(jq -c '.spent_seconds = 1500 | .granted_seconds = 900' <<<"$day")
[[ $(st_jq 'day_remaining' <<<"$spent") == 3000 ]] || fail "remaining counts the grant and subtracts what is spent"
pass "the day carries its budget, grant and spend"

# The status the widget reads: the phase and the block reason a profile and a
# day produce. A bedtime that wraps past midnight blocks in the small hours.
profile=$(st_jq -n 'default_profile | .blocked_periods[0].enabled = true')
running=$(TZ=UTC st_status_json 4242 kid 1000000000 kids "$profile" "$spent" "$st_runtime_default")
# 1000000000 is 01:46 UTC next to a 20:00-07:00 bedtime, so the block is on.
# The moment is read in the runner's timezone, so fix one: in Denver the same
# epoch is 19:46, before the window.
[[ $(jq -r .phase <<<"$running") == bedtime ]] || fail "an enabled overnight period blocks in the small hours"
[[ $(jq -r .blocked_label <<<"$running") == Bedtime ]] || fail "the status names the period that is blocking"
empty_day=$(jq -c '.spent_seconds = 3600' <<<"$day")
noon=$(TZ=UTC st_status_json 4242 kid 1000030000 kids "$(st_jq -n 'default_profile')" "$empty_day" "$st_runtime_default")
[[ $(jq -r .phase <<<"$noon") == empty ]] || fail "a spent budget outside a block reads as empty"
pass "the status reports bedtime and empty from the profile and the day"

# The clock reads minutes and hours the way the pill does.
[[ $(st_human_time 5400) == 1h30 ]] || fail "5400s reads as 1h30"
[[ $(st_human_time 3600) == 1h ]] || fail "a whole hour reads as 1h"
[[ $(st_human_time 900) == 15m ]] || fail "900s reads as 15m"
pass "st_human_time formats the way the bar shows it"

# An unlock at zero earns the grace to hand out minutes only when a grown-up's
# password opened the lock; the child's own earns only the quick relock.
lock_delay_def=$(sed -n '/^def lock_delay:/,/end;$/p' "$ROOT/bin/omarchy-screen-timed")
delay_after_unlock() {
  jq -nc --argjson now 1000 --argjson adult_unlock "$1" \
    --argjson profile '{"grace_seconds": 60, "relock_seconds": 30, "unlock_grace_seconds": 120}' \
    "$lock_delay_def {rt: {lock_count: 1, last_lock_ok: true}} | lock_delay"
}
[[ $(delay_after_unlock 0) == '{"delay":30,"kind":"child_unlock"}' ]] || fail "a child's own unlock at zero gets only the quick relock" "$(delay_after_unlock 0)"
[[ $(delay_after_unlock 950) == '{"delay":120,"kind":"after_unlock"}' ]] || fail "a grown-up's unlock at zero gets the grace" "$(delay_after_unlock 950)"
[[ $(delay_after_unlock 500) == '{"delay":30,"kind":"child_unlock"}' ]] || fail "a grown-up's unlock long ago earns nothing now" "$(delay_after_unlock 500)"
pass "only a grown-up's unlock at zero earns the grace; the child's own relocks quickly"
