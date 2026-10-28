# A child's first login opens on the first kids theme installed, from the list
# their theme picker is limited to.
[[ " $(id -nG) " == *" omarchy-child "* ]] || exit 0

while read -r theme; do
  [[ -z $theme || $theme == \#* ]] && continue
  if [[ -d $OMARCHY_PATH/themes/$theme ]]; then
    omarchy-theme-set "$theme"
    exit
  fi
done <"$OMARCHY_PATH/default/omarchy/child-themes"
