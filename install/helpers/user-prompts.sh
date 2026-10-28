# Prompts shared by the omarchy-user-* commands, asked in the shell's menu,
# which hand what they collect to omarchy-user-helper on stdin. There is no
# terminal behind them, so what goes wrong is said in a notification. Sourcing
# performs no setup.

USER_MIN_PASSWORD=6
USER_MENU_WIDTH=440

user_say() {
  omarchy-notification-send -g 󰀄 "$@"
}

user_problem() {
  omarchy-notification-send -u critical -g 󰀄 "$@"
}

# Prints the label picked, or fails when the menu is dismissed.
user_choose() {
  local prompt=$1
  shift
  omarchy-menu-select "$prompt" "$@" -- --width "$USER_MENU_WIDTH"
}

# Prints the labels ticked, one per line. $1 is the prompt; the options follow
# up to a lone --, and the ones already ticked after it.
user_choose_many() {
  local prompt=$1 selected=() options=() picked
  shift
  while (( $# )) && [[ $1 != "--" ]]; do options+=("$1"); shift; done
  (( $# )) && shift
  for picked in "$@"; do selected+=(--selected "$picked"); done
  picked=$(omarchy-menu-select "$prompt" "${options[@]}" -- --multiple "${selected[@]}" --width "$USER_MENU_WIDTH") || return 1
  jq -r '.[]' <<<"$picked"
}

user_input() {
  omarchy-menu-input "$1" --width "$USER_MENU_WIDTH"
}

user_secret() {
  omarchy-menu-input "$1" --password --width "$USER_MENU_WIDTH"
}

# Asks for a new password twice and prints it. The helper checks it again,
# along with whether anyone else already has it.
user_prompt_new_password() {
  local prompt=$1 password confirmation
  while true; do
    password=$(user_secret "$prompt") || return 1
    if (( ${#password} < USER_MIN_PASSWORD )); then
      user_problem "$(omarchy-i18n users.tooShort "$USER_MIN_PASSWORD")"
      continue
    fi
    confirmation=$(user_secret "$(omarchy-i18n users.confirmPassword)") || return 1
    if [[ $password != "$confirmation" ]]; then
      user_problem "$(omarchy-i18n users.mismatch)"
      continue
    fi
    printf '%s' "$password"
    return 0
  done
}

# Asks for the caller's own password once and hands it to sudo too, so neither
# asks twice. Prints the password.
user_prompt_own_password() {
  local prompt=$1 password
  password=$(user_secret "$prompt") || return 1
  if ! printf '%s\n' "$password" | sudo -S -p '' -v 2>/dev/null; then
    user_problem "$(omarchy-i18n users.wrongPassword)"
    return 1
  fi
  printf '%s' "$password"
}

# Runs the helper on this stdin and says how it went: $1 when it worked, and
# what the helper said when it did not. The sudo prefix is the caller's.
user_helper() {
  local done=$1 output
  shift
  if output=$("$@" 2>&1); then
    user_say "$done"
  else
    user_problem "$(omarchy-i18n users.notChanged)" "$(tail -n 3 <<<"$output")"
    return 1
  fi
}

# Refuses root, and revokes the sudo timestamp the commands prime on the way
# out, so the password typed for one change authorises nothing after it.
user_start() {
  if (( EUID == 0 )); then
    echo "Run this as yourself; it asks for sudo itself." >&2
    exit 1
  fi
  source "$OMARCHY_PATH/bin/omarchy-security-functions"
  omarchy_security_install_sudo_cleanup_traps
}
