# Prevent password-based SDDM logins from creating an encrypted login keyring
# that conflicts with Omarchy's passwordless default keyring behavior. The ISO
# owns autologin/session state because it knows whether the target is encrypted.
if [[ -f /etc/pam.d/sddm ]]; then
  sed -i '/-auth.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm
  sed -i '/-password.*pam_gnome_keyring\.so/d' /etc/pam.d/sddm
fi

# The login screen asks for a password alone and tries each account in turn;
# omarchy-login-match ends an attempt early when the password is another
# account's, so only a password that is nobody's counts as a failed login.
if [[ -f /etc/pam.d/sddm ]] && ! grep -q omarchy-login-match /etc/pam.d/sddm; then
  sed -i '0,/^auth/s|^auth|auth        [success=die default=ignore] pam_exec.so quiet expose_authtok /usr/bin/omarchy-login-match\n&|' /etc/pam.d/sddm
fi
