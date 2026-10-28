#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# A child's account (omarchy-child) gets the kids themes: the theme switcher's
# rows hold only those installed, and first login sets the first of them.

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/omarchy/default/omarchy" "$tmp/home"
cp "$ROOT/default/omarchy/child-themes" "$tmp/omarchy/default/omarchy/"

cat >"$tmp/bin/id" <<'SH'
#!/bin/bash
echo "${TEST_GROUPS:-kid wheel}"
SH
# The rows are the previews in the directory it is handed, by name.
cat >"$tmp/bin/omarchy-menu-images" <<'SH'
#!/bin/bash
for f in "${!#}"/*; do basename "${f%.*}"; done | sort
SH
cat >"$tmp/bin/omarchy-theme-set" <<'SH'
#!/bin/bash
echo "$1" >>"$TEST_TMP/theme-set"
SH
chmod +x "$tmp/bin/"*
export PATH="$tmp/bin:$PATH" TEST_TMP=$tmp HOME=$tmp/home OMARCHY_PATH=$tmp/omarchy

install_theme() {
  mkdir -p "$tmp/omarchy/themes/$1"
  printf 'png' >"$tmp/omarchy/themes/$1/preview.png"
}

rows() {
  rm -rf "$tmp/home/.cache"
  "$ROOT/bin/omarchy-theme-switcher" --print-rows | paste -sd' ' -
}

install_theme tokyo-night
install_theme gruvbox

export TEST_GROUPS="kid omarchy-child"
[[ $(rows) == "gruvbox tokyo-night" ]] || fail "with no kids theme installed a child is offered every theme" "$(rows)"
pass "a child is offered every theme while no kids theme is installed"

install_theme dino-dawn
install_theme cozy-night
[[ $(rows) == "cozy-night dino-dawn" ]] || fail "a child is offered only the kids themes" "$(rows)"
export TEST_GROUPS="dhh wheel"
[[ $(rows) == "cozy-night dino-dawn gruvbox tokyo-night" ]] || fail "an adult is offered every theme" "$(rows)"
pass "a child's theme picker holds only the kids themes; an adult's holds them all"

TEST_GROUPS="kid omarchy-child" bash "$ROOT/install/user/first-run/child.sh"
[[ $(cat "$tmp/theme-set") == "cozy-night" ]] || fail "a child's first login sets the first kids theme installed"
rm -f "$tmp/theme-set"
TEST_GROUPS="dhh wheel" bash "$ROOT/install/user/first-run/child.sh"
[[ ! -e $tmp/theme-set ]] || fail "an adult's first login leaves the theme alone"
pass "a child's first login opens on the first kids theme installed, and an adult's is untouched"
