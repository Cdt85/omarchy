# Plan: Users — more than one person per machine, picked by password

Revision 2. Rev 2 incorporates adversarial review by codex (medium): the first change that adds a second disk key also retires the static owner autologin, the boot selection is a one-use authorisation consumed at each SDDM start, the initramfs wrapper runs `cryptsetup` once and never changes its exit status, the login screen selects an account instead of discovering it through failed logins, uniqueness is checked against the disk's slots as well as the login hashes, the slot map is bound to the volume, account changes are journaled under one root lock, a child's own password change goes through a narrow helper, and root's password has an owner.

## Problem

Omarchy is built for one person. On an encrypted install one password opens the disk, logs in, and is root's (`omarchy-provision-owner` sets both with `chpasswd`), and SDDM autologins the owner from a static `/etc/sddm.conf.d/autologin.conf`. There is no supported way to add a second person, and the requests that need one have each grown their own answer:

- #9750 and omarchy-iso#146 make a *child install*: one account, the kid's, with root's password as a "parent password" typed into the kid's session. The parent has no account, and the parent's secret is entered into a session the kid controls (a fake `sudo` on `PATH` or a modified shell can capture it, and it is root and a disk key at once).
- #16100 makes a general multi-user model, but splits the one password: a shared disk password everyone knows, a locked root, autologin off, and a username box on the login screen.
- #14366 adds `omarchy user` commands with no answer for the disk or the login screen.

This plan keeps Omarchy's "type your password and you're in" for every person on the machine, and makes a child an account the parent adds after setting up their own.

## The model

- **Every account's password is also its own LUKS key slot.** Typing your password at the disk prompt opens the disk *and* tells the machine who you are.
- **The slot that opened the disk picks the autologin, once.** The selection is consumed by the SDDM start it was made for; any later SDDM start in the same boot shows the login screen.
- **No username box anywhere.** The disk prompt and the lock screen take only a password; the login screen shows whose password it is asking for and switches between accounts with the arrow keys.
- **Adults are in `wheel`; children are not.** A child is a limited account in the `omarchy-child` group, which later features (screen time, an app list) key on. Admin work happens in an adult's own session, never by typing an adult's password into a child's.
- **One account behaves exactly as today.** Nothing changes until a second account is added, and deleting back down to one restores today's setup for whoever remains.

## Setup > Users

```
Setup > Users
  dhh (Adult)
    Change password
    Delete
  emma (Child)
    Change password
    Delete
  Add
    Adult / Child → name → password → confirm → your password
```

- **Add** creates the account (Adult: `wheel`; Child: `omarchy-child` and nothing else — not `input`, not `docker`, none of the owner's recorded groups), sets its password, adds a LUKS slot for it, and records the slot in the slot map. Adding a slot needs a key that already opens the disk, and sudo's authorisation is not one (a cached timestamp or a passwordless grant proves nothing about the disk), so the flow ends by asking the adult for their own password, which must open their own mapped slot. The user's desktop is set up at first login by the existing `omarchy-provision-user` path.
- **Change password** changes the login password and the slot together, keeping the old slot until the new one is proven. For yourself, the old password authorises re-keying your slot. For someone else (a child who forgot theirs), it asks for your own password, as Add does.
- **Delete** ends the user's sessions, removes their slot, their map entry, any sudoers grant naming them (including `omarchy-sudo-passwordless`'s username-scoped `NOPASSWD: ALL` rule, which would otherwise pass to a later account of the same name), then the account, and asks whether to keep their home. It is not offered for the last adult (someone must be able to administer the machine) or for the account you are signed in as.
- **Adults see every user; a child sees only their own entry, with only Change password.**

The menu is a front end to `omarchy user list|add|delete|password`. Menu visibility is not the boundary: the privileged work happens in one root helper, `omarchy-user-helper`, which authorises each request itself:

- an adult (in `wheel`, through `sudo`) may add, delete and set any password;
- a child may only change their own password, through a `NOPASSWD` sudoers grant for `%omarchy-child` to that one helper subcommand, and the helper requires their current password before anything changes;
- nobody gets `cryptsetup`, `chpasswd` or a shell through it.

### Passwords

- **At least 6 characters**, enforced by the helper and by the shared setup form (`install/provisioning/setup-form.sh`, which today accepts any nonempty match), so the installer's owner prompt follows the same rule. Existing passwords are kept; the rule applies when one is set. Six is a floor against a child's first password, not a strong disk key: offline guessing is limited only by LUKS's key derivation, and the disk is as strong as its weakest password, so the prompt asks for something longer.
- **Unique across accounts and across the disk.** A candidate is refused if it matches another account's shadow hash *or* opens any existing LUKS slot other than the one being replaced (tested with tokens disabled, as `luks_key_slot` and `omarchy-drive-password` already do). Shadow alone is not enough: an old password left in a slot after a `passwd` change no longer matches any hash but still opens that slot. Root's hash is skipped when it is deliberately the same password as its holder's (see *Root*).
- The refusal says only that the password is taken. It does reveal that a guess is somebody's password, but so does the disk prompt at every boot, without limit; the helper adds a delay and a lockout after repeated refusals so it is no cheaper than that.
- _Update > Password > User_ (plain `passwd`) and _Update > Password > Drive Encryption_ go away in favour of _Setup > Users > (you) > Change password_.

### Drift

Removing menu entries does not stop anyone running `passwd`. So the map records, for each account, a fingerprint of its shadow entry at the moment its slot was last synchronised. If an account's shadow entry has changed since, its slot no longer selects an autologin: boot falls through to the login screen, and _Setup > Users_ marks the account "password out of sync" and offers Change password to put the slot back in step. Drift costs the convenience, never the boundary.

## Boot: the slot picks the user

On x86 the root disk is opened by mkinitcpio's busybox `encrypt` hook. With Plymouth running, it calls `plymouth ask-for-password --command="cryptsetup open --type luks --key-file=- <device> <name> …"`; Plymouth splits that command into arguments itself and `execvp`s it with the password on stdin, so `cryptsetup` is resolved through the initramfs `PATH`, and shell syntax in the command is passed as literal arguments (the hook's `${CSQUIET}` becomes a literal `>/dev/null` argument under `quiet`, which the wrapper forwards untouched).

- **`omarchy-luks-slot`**, a mkinitcpio hook shipped as `etc/initcpio/install/omarchy-luks-slot` (mkinitcpio searches `/etc/initcpio/install` before `/usr/lib/initcpio/install`, and `etc/**` already ships in `omarchy-settings`). Ordered after `encrypt` in the `00-omarchy-hooks.conf` baseline, it adds the real binary as `/usr/bin/cryptsetup.real` and puts a busybox `sh` wrapper at `/usr/bin/cryptsetup` (`add_file` overwrites).
  - Every call other than `open … --key-file=-` is `exec`ed unchanged.
  - That one call runs `cryptsetup.real --verbose` with the original arguments and stdin, exactly once, captures its output to a file in `/run`, and exits with the real command's status. The password is never read, copied or replayed by the wrapper.
  - Only after success, and only as best effort, it parses `Key slot N unlocked.` and writes `<LUKS UUID> <slot>` to `/run/omarchy/luks-slot`. A failure to parse or write is ignored and never changes the exit status: the worst a recording fault can do is lose the autologin.
  - A wrapper that is missing or does not parse would break the unlock itself, which no runtime care can contain. The hook therefore checks the wrapper with `sh -n` at build time and refuses to install it (leaving the real `cryptsetup` in place) if it fails, and phase 3 proves every unlock path on a worker before it ships: Plymouth, the tty fallback, a keyfile, a wrong password then a right one, and `quiet`.
  - `/run` is a tmpfs mounted by `init_functions`, and util-linux `switch_root` moves it into the real root, so the record is there for the boot that follows.
  - The tty fallback (`cryptsetup` prompting itself), keyfiles and tokens record nothing.
- **`omarchy-login-select`**, run as an `ExecStartPre=` of `display-manager.service` through a drop-in, so it runs at *every* SDDM start, not just at boot. Each run first removes the managed autologin drop-in, then:
  - with one account, writes autologin for that account on an encrypted install (today's behaviour, for whoever remains);
  - with more than one, consumes `/run/omarchy/luks-slot` (renaming it so no later start can reuse it), and writes autologin only if the UUID is the root volume's, the slot is mapped, the account exists, and its shadow fingerprint matches; otherwise it leaves the drop-in removed and SDDM shows the login screen.
  - It never falls back to the owner, writes `Relogin=false`, and is prefixed `-` so a failure still starts SDDM — after the removal, so a failure fails closed.
  - `omarchy-login-select` owns `/etc/sddm.conf.d/autologin.conf` from the first `omarchy user add`; `omarchy doctor`-style checks flag any other `User=` under `[Autologin]` in `/etc/sddm.conf` or another drop-in, which would outrank it.
- **The slot map**, `/etc/omarchy/users/slots`, root-owned `0600`, one line per account: `<LUKS UUID> <slot> <uid> <user> <shadow fingerprint>`. Written only by the helper, atomically, under its lock. Duplicate slots, duplicate users, a UUID that is not the root volume's, or a journal left mid-change make the whole map untrusted, and boot shows the login screen. It holds slot numbers and names, never key material.

Hibernation resume never reaches SDDM and is unaffected. Apple Silicon boots a systemd initramfs, where `systemd-cryptsetup` caches the passphrase in the kernel keyring instead; reading it there (and testing it with `luks_key_slot`) is a second source for the same selector and lands after x86 is proven. Until then those machines show the login screen when there is more than one account.

## The login screen

The Omarchy SDDM theme is a single password field that logs in as `userModel.lastUser`. It stays a single password field, with the selected account's name shown above it. Left and Right (and Tab) cycle through `userModel`, starting at the last user; Return logs in as the name shown. There is nothing to type but the password, and only the account shown is ever tried, so one person's typo is never charged to another person's `faillock` tally.

Matching the password against every account was considered and rejected: SDDM's greeter can only call `sddm.login(user, password, session)`, so discovering the account means a failed PAM login against each wrong one. A correct password for B would first count a failure against A, every mistyped attempt would count against every account (`deny=10`, `unlock_time=120` in `system-auth`), and SDDM drops a second `login` sent before the first helper has exited, so the chain would also race.

Unencrypted installs use the same screen. The lock screen is unchanged: it belongs to one session and knows its user.

## Changes are journaled

Account, shadow, root's shadow, LUKS metadata and the map cannot change atomically together. The helper serialises every change under one root lock (`/run/omarchy-users.lock`) and records each in a root-owned journal (`/var/lib/omarchy/users/journal`), holding the operation, the account, the UUID, slot numbers and the phase, never key material. Each operation keeps old access until its replacement is verified:

- **Add:** create the account locked → set its password → add its slot (authorised by the adult's slot) → verify the new password opens the new slot → publish the map entry → unlock the account. Interrupted before publishing, the next run removes the unmapped slot and the half-made account.
- **Change password:** add the new slot → verify → set the shadow password (and root's, for root's holder) → publish the map entry with the new slot and fingerprint → kill the old slot. Interrupted before publishing, the next run kills the new slot and the old password still works everywhere.
- **Delete:** end sessions → remove the map entry → kill the slot → remove grants → remove the account. Interrupted after the map entry is gone, the account can no longer be selected at boot, and the next run finishes.

While the journal holds an unfinished change, boot shows the login screen and the helper refuses new changes until it has finished the old one.

## Root

Root's password is the installer owner's today. The helper records root's holder in `/etc/omarchy/users/root` (the installer owner, on the first `omarchy user add`). Change password for the holder updates root's password in the same journaled step. Deleting the holder transfers root to the adult doing the deleting, whose password the flow already asks for, so root never keeps a deleted person's password. With only children left this cannot happen: the last adult cannot be deleted.

## What else multiple logins need

From #16100, without its disk and login-screen model:

- **The `%wheel` grant.** `omarchy-provision-owner` writes `%wheel ALL=(ALL:ALL) ALL`; an ISO install grants the owner by name, so the first `omarchy user add` writes the same `00-omarchy-wheel` drop-in if it is missing.
- **A per-user update log** (#15683), so a second account can update after the first has.
- **Children are told, not prompted.** Install, remove and update entries decline in a child's session with "Ask a grown-up to do this from their account", via an `omarchy-sudo-allowed`-style predicate, before `sudo` asks for a password it would refuse. Polkit's admin identities are `wheel`, so actions that would ask for an adult's password inside a child's session are listed and either declined the same way or left to the actions' own `allow_active` policy (NetworkManager's Wi-Fi toggle, for one).
- **Migrations in a limited account** run their sudo steps only after an adult's run, as #16100 does.

## Costs, stated plainly

- **Every account's password opens the whole disk.** With a disk key and a live USB, a child can read everything, and can also *change* anything offline: plant a program that runs in an adult's session, or edit the boot entry to start another init. That is true of any design where a child can start the machine alone (a shared disk password is the same). The restrictions here hold while the installed system runs as installed; against a child willing to alter the boot environment they need a firmware password, external boot off, and a boot chain that cannot be edited, which is a separate project (TPM unlock with a measured boot).
- **The disk is as strong as the weakest password on it**, hence the minimum and the prompt's advice.
- **Each slot adds a key-derivation pass to a wrong password** at the disk prompt (and a correct one pays for every slot ahead of it), roughly a second each. Households are a handful of accounts; this is not built for dozens.
- **Omarchy-only boot code.** The wrapper is small and checked at build time, but it is in the initramfs, the worst place to break; phase 3 does not ship until every unlock path is proven on a worker.

## Phases

1. **Accounts and the login screen, together.** `omarchy-user-helper` with its journal, lock and authorisation; `omarchy user list|add|delete|password`; the slot map with fingerprints; password rules in the helper and the setup form; the `%wheel` drop-in; root's holder; _Setup > Users_; retiring _Update > Password_'s two entries; the theme's account switching; and `omarchy-login-select` in its one-account and login-screen modes. This phase must ship whole: from the moment a second person has a disk key, the static owner autologin is gone and every boot with more than one account shows the login screen.
2. **Boot selection.** The `omarchy-luks-slot` hook, proven on a worker built from the ISO across every unlock path, then `omarchy-login-select` consuming its record.
3. **Children.** The child predicate, declined admin entries and polkit coverage, then screen time (#11196 rebased onto `omarchy-child`, with parent settings authorised by an adult account instead of a PIN) and the Apple Silicon keyring source.

## What happens to the open pull requests

- **#9750, omarchy-iso#146:** superseded. Their prompt wording and the `omarchy-parent <feature>` idea feed phase 3; the child install and the parent password typed into the kid's session do not carry over.
- **#11196:** rebased onto `omarchy-child` in phase 3.
- **#16100:** the pieces under *What else multiple logins need* are taken from it; its shared disk password, locked root and username box are not.
- **#14366:** superseded by phase 1.
- **#12488, omarchy-site#180/#181:** themes, independent of all of this.
