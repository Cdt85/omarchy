echo "Let the login screen find the account by its password"

# The login screen now asks for a password alone and tries each account in
# turn. omarchy-login-match ends an attempt early when the password is another
# account's, so trying the wrong account first is neither slow nor counted as
# a failed login. pam_exec needs the literal /usr/bin path.

if [[ -f /etc/pam.d/sddm ]] && ! grep -q omarchy-login-match /etc/pam.d/sddm; then
  sudo sed -i '0,/^auth/s|^auth|auth        [success=die default=ignore] pam_exec.so quiet expose_authtok /usr/bin/omarchy-login-match\n&|' /etc/pam.d/sddm
fi
