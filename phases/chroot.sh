#!/usr/bin/env bash
# Phase 2 — runs inside arch-chroot; "/" is the freshly installed system.

phase_chroot() {
  : "${HOST_NAME:?}" "${USER_NAME:?}"
  # One password, for both the user and root.
  local password
  IFS= read -r password < "$SETUP_DIR/creds"
  rm -f "$SETUP_DIR/creds"

  # The parts only speak up with a warning; the step's screen shows a fact.
  note "Setting up your language, account and startup..."
  configure_locale
  configure_accounts "$password"
  configure_boot_splash
  configure_hibernation
  configure_gaming_system
  # The initramfs again, with what the three above added: the splash's hook,
  # NVIDIA's modules and their options, the resume hook.
  run mkinitcpio -P
  install_bootloader
  hand_over_to_user
  run_desktop_phase
}

configure_locale() {
  # Settled by the install phase (resolve_timezone); never left at auto.
  [[ $TIMEZONE != auto && -f /usr/share/zoneinfo/$TIMEZONE ]] || TIMEZONE=UTC
  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  # (Through run: it can wait a second or two for the clock.) Next to
  # Windows, the clock keeps local time, as Windows does: in UTC, one of
  # them would be off by the timezone.
  if (( ${BESIDE_WINDOWS:-0} )); then run hwclock --systohc --localtime
  else run hwclock --systohc; fi
  # One language for everything (LOCALE), Plasma's too, which follows LANG;
  # dates and times the country's way (TIME_LOCALE, settled by the install
  # phase), when this glibc has that locale. Each enabled in locale.gen by
  # its exact line ("name charset"): a bare prefix would also catch other
  # charsets of it.
  [[ $TIME_LOCALE != auto ]] && grep -q "^#\?$TIME_LOCALE UTF-8 *\$" /etc/locale.gen || TIME_LOCALE=$LOCALE
  local name
  for name in "$LOCALE" "$TIME_LOCALE"; do
    sed -i "s/^#\($name UTF-8 *\)\$/\1/" /etc/locale.gen   # (its lines end in spaces)
  done
  run locale-gen
  printf 'LANG=%s\n' "$LOCALE" > /etc/locale.conf
  [[ $TIME_LOCALE == "$LOCALE" ]] || printf 'LC_TIME=%s\n' "$TIME_LOCALE" >> /etc/locale.conf
  echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
}

# $1 the password, for root and the user
configure_accounts() {
  echo "$HOST_NAME" > /etc/hostname
  printf '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 %s\n' "$HOST_NAME" > /etc/hosts

  useradd -m -G wheel -s /bin/bash "$USER_NAME"
  # chpasswd reads stdin, so the passwords never appear in argv or env.
  printf 'root:%s\n%s:%s\n' "$1" "$USER_NAME" "$1" | chpasswd

  write_sudoers /etc/sudoers.d/10-wheel '%wheel ALL=(ALL:ALL) ALL'

  enable_service NetworkManager
}

# Plymouth splash instead of scrolling boot messages (Esc still shows them),
# using the archman theme below. Before mkinitcpio -P (phase_chroot), which
# builds the hook in, and install_bootloader, which writes the kernel
# options into grub.cfg.
configure_boot_splash() {
  # Right after the systemd (or udev) hook, so it starts as early as it can.
  grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf \
    || sed -i -E 's/^(HOOKS=\(.*\b(systemd|udev))\b/\1 plymouth/' /etc/mkinitcpio.conf
  grep -q '^HOOKS=.*plymouth' /etc/mkinitcpio.conf || warn "Couldn't add the boot screen, startup will show text instead"

  # NVIDIA's driver has to be in the initramfs (early KMS), or the splash
  # only appears late or falls back to text. Intel/AMD get theirs from the
  # stock kms hook.
  if pacman -Q nvidia-utils &>/dev/null && ! grep -q '^MODULES=.*nvidia' /etc/mkinitcpio.conf; then
    sed -i -E -e 's/^MODULES=\((.*)\)/MODULES=(\1 nvidia nvidia_modeset nvidia_uvm nvidia_drm)/' \
      -e 's/^MODULES=\( /MODULES=(/' /etc/mkinitcpio.conf
  fi

  if install_splash_theme; then
    run plymouth-set-default-theme archman
  else
    note "The custom boot screen is missing from the installer, using the standard one"
    run plymouth-set-default-theme bgrt
  fi
  # vt.global_cursor_default=0: no blinking cursor on the text console, which
  # shows for a moment around the splash (between Plasma exiting and the
  # shutdown splash starting, say).
  local opt
  for opt in quiet splash vt.global_cursor_default=0; do
    add_kernel_option "$opt"
  done

  # loglevel=3 only covers boot: keep kernel messages below "error" off the
  # console for good, or warnings (clocksource, hardware quirks...) end up on
  # the text console and show at shutdown, around the splash.
  echo 'kernel.printk = 3 3 3 3' > /etc/sysctl.d/20-quiet-printk.conf
}

# The archman theme (assets/plymouth): Arch's logo where firmware logos sit
# and a spinner, both scaled to the screen height by archman.script, so they
# keep their size relative to the screen at any resolution.
install_splash_theme() {
  local src=$SETUP_DIR/assets/plymouth dir=/usr/share/plymouth/themes/archman f
  for f in archman.plymouth archman.script logo.png spinner.png; do
    [[ -f $src/$f ]] || return 1
  done
  rm -rf "$dir"
  install -Dm644 -t "$dir" "$src"/{archman.plymouth,archman.script,logo.png,spinner.png}
}

# A RAM-sized swap partition alone doesn't enable hibernation: the initramfs
# needs the resume hook and the kernel needs to be told where the image is.
configure_hibernation() {
  # The install phase's own swap partition (SWAP_PART): looked up by its
  # label instead, a second disk with an older install could answer first.
  local swap_uuid=''
  [[ -z ${SWAP_PART:-} ]] || swap_uuid=$(blkid -o value -s UUID "$SWAP_PART") || true
  [[ -n $swap_uuid ]] || { warn "No swap space found, hibernation won't be available"; return; }

  # The systemd initramfs hook resumes on its own; the udev-based default
  # needs the resume hook, ordered before filesystems.
  if ! grep -q '^HOOKS=.*systemd' /etc/mkinitcpio.conf; then
    grep -q '^HOOKS=.*resume' /etc/mkinitcpio.conf \
      || sed -i 's/^\(HOOKS=(.*\)filesystems/\1resume filesystems/' /etc/mkinitcpio.conf
  fi
  add_kernel_option "resume=UUID=$swap_uuid"
}

# add_kernel_option OPTION — appends OPTION to the kernel command line in
# /etc/default/grub, unless it's there already; install_bootloader writes it
# into grub.cfg.
add_kernel_option() {
  grep -qE "^GRUB_CMDLINE_LINUX_DEFAULT=\".*\b$1\b" /etc/default/grub \
    || sed -i "s|^\(GRUB_CMDLINE_LINUX_DEFAULT=\".*\)\"|\1 $1\"|" /etc/default/grub
}

# GRUB as the firmware's boot entry (GRUB, first in its order), and a copy
# at the drive's fallback path (EFI/BOOT/BOOTX64.EFI, --removable: the
# firmware's list untouched), which firmware boots from any drive whose
# entries it doesn't take. Some do that to a new one on the next start
# (seen: an AMI board, its old GRUB entries left, went to its EFI shell).
# Its menu hidden. Next to Windows (BESIDE_WINDOWS), on Windows' EFI
# partition (/efi), as ARCHMAN, so it takes no other system's GRUB entry
# there; without the copy, which would take the place of Windows' own
# fallback; and with the menu (configure_grub_menu).
install_bootloader() {
  if (( ${BESIDE_WINDOWS:-0} )); then
    configure_grub_menu
    run grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=ARCHMAN
  else
    set_grub_option GRUB_TIMEOUT 0
    set_grub_option GRUB_TIMEOUT_STYLE hidden
    run grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    run grub-install --target=x86_64-efi --efi-directory=/boot --removable
  fi
  regenerate_grub
}

# GRUB's menu next to Windows: ARCHMAN first (GRUB_DISTRIBUTOR names it
# "ARCHMAN Linux"), started after GRUB_MENU_TIMEOUT seconds, then Windows,
# from its boot manager on the EFI partition, by /etc/grub.d/15_windows (so
# grub-mkconfig keeps it; after 10_linux's entries), with that partition's
# UUID; os-prober would find only this same Windows, mounting every
# partition there is to look. In the ARCHMAN theme (install_grub_theme),
# at GRUB_MENU_GFXMODE.
configure_grub_menu() {
  set_grub_option GRUB_TIMEOUT "$GRUB_MENU_TIMEOUT"
  set_grub_option GRUB_TIMEOUT_STYLE menu
  set_grub_option GRUB_DISTRIBUTOR '"ARCHMAN"'
  set_grub_option GRUB_GFXMODE "$GRUB_MENU_GFXMODE"
  if install_grub_theme; then
    set_grub_option GRUB_THEME "$GRUB_THEME_DIR/theme.txt"
  else
    note "The boot menu's theme is missing from the installer, using GRUB's own look"
  fi
  local uuid
  uuid=$(blkid -o value -s UUID "$WINDOWS_ESP") || die "Couldn't find Windows' boot partition for the boot menu."
  write_file /etc/grub.d/15_windows 755 <<EOF
#!/bin/sh
# Windows, started by its own boot manager on the EFI partition it shares
# with ARCHMAN (by the ARCHMAN installer).
cat << 'MENU'
menuentry 'Windows' --class windows --id windows {
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root $uuid
	chainloader /EFI/Microsoft/Boot/bootmgfw.efi
}
MENU
EOF
}

# The archman GRUB theme (assets/grub/archman, tools/make-grub-theme.py):
# the logo, the tagline and the menu in the installer's font and colours.
GRUB_THEME_DIR=/boot/grub/themes/archman
install_grub_theme() {
  local src=$SETUP_DIR/assets/grub/archman
  [[ -f $src/theme.txt ]] || return 1
  rm -rf "$GRUB_THEME_DIR"
  install -Dm644 -t "$GRUB_THEME_DIR" "$src"/*
}

# set_grub_option NAME VALUE — NAME=VALUE in /etc/default/grub, in place of
# its line (commented out or not), or added.
set_grub_option() {
  if grep -q "^#\?$1=" /etc/default/grub; then
    sed -i "s|^#\?$1=.*|$1=$2|" /etc/default/grub
  else
    echo "$1=$2" >> /etc/default/grub
  fi
}

# Moves this installer into the new user's home, for the desktop phase and the
# Plasma first-login step. The log moves with it, and what this phase logs
# afterwards follows it there.
hand_over_to_user() {
  local dest=/home/$USER_NAME/$USER_SETUP_DIR
  rm -rf "$dest"
  mv "$SETUP_DIR" "$dest"
  chown -R "$USER_NAME:$USER_NAME" "$dest"
  LOG_FILE=$dest/setup.log
}

# The desktop setup (phases/desktop.sh), run here as the new user rather than on
# a first boot: all of it works in the chroot, on the live system's network,
# so the machine reboots once, straight into SDDM. A temporary sudo rule
# stands in for the password the phase would otherwise ask for, and the
# progress bar carries on from the install phase's (lib/ui.sh's screen_env).
run_desktop_phase() {
  local rule=/etc/sudoers.d/90-arch-setup-install
  write_sudoers "$rule" "$USER_NAME ALL=(ALL:ALL) NOPASSWD: ALL"
  trap 'rm -f '"$rule" EXIT
  screen_env
  runuser -u "$USER_NAME" -- env TERM="$TERM" \
    X11_LAYOUT="$X11_LAYOUT" X11_VARIANT="$X11_VARIANT" X11_OPTIONS="$X11_OPTIONS" \
    FAN_MODULES="$FAN_MODULES" FAN_PACKAGES="$FAN_PACKAGES" "${SCREEN_ENV[@]}" \
    bash "/home/$USER_NAME/$USER_SETUP_DIR/setup.sh" desktop
  rm -f "$rule"
}
