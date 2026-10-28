# Prompts shared by the omarchy-user-* commands, which hand what they collect
# to omarchy-user-helper on stdin. Sourcing performs no setup.

USER_MIN_PASSWORD=6

# Asks for a new password twice and prints it. The helper checks it again,
# along with whether anyone else already has it.
user_prompt_new_password() {
  local header=$1 password confirmation
  while true; do
    password=$(gum input --password --header "$header") || return 1
    if (( ${#password} < USER_MIN_PASSWORD )); then
      echo "$(omarchy-i18n users.tooShort "$USER_MIN_PASSWORD")" >&2
      continue
    fi
    confirmation=$(gum input --password --header "$(omarchy-i18n users.confirmPassword)") || return 1
    if [[ $password != "$confirmation" ]]; then
      echo "$(omarchy-i18n users.mismatch)" >&2
      continue
    fi
    printf '%s' "$password"
    return 0
  done
}

# Asks for the caller's own password once and hands it to sudo too, so neither
# asks twice. Prints the password.
user_prompt_own_password() {
  local header=$1 password
  password=$(gum input --password --header "$header") || return 1
  if ! printf '%s\n' "$password" | sudo -S -p '' -v 2>/dev/null; then
    echo "$(omarchy-i18n users.wrongPassword)" >&2
    return 1
  fi
  printf '%s' "$password"
}

user_refuse_root() {
  if (( EUID == 0 )); then
    echo "Run this as yourself; it asks for sudo itself." >&2
    exit 1
  fi
}
