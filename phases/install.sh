#!/usr/bin/env bash
# Phase 1 — runs on the live ISO as root.

phase_install() {
  # Piped in via curl | bash, fd 0 is the script itself, not the keyboard.
  exec < /dev/tty

  # The USB's splash is on screen (tools/archauto.sh): the big logo, and
  # under it "Checking if this device is ready..."; or, after its Wi-Fi
  # screen, that screen's "Connected" line. The USB has checked the
  # network; it booted in UEFI mode, as root.

  # Where this machine is, while the splash is still up: its country, for
  # the mirrors, the keyboard and the date formats, and its timezone.
  geolocate
  resolve_timezone
  resolve_time_locale
  # And its motherboard's fan chip, for the bar's total below (lib/gaming.sh).
  detect_fan_drivers

  # The splash stays up at least 4 seconds in all (since SPLASH_SINCE);
  # only then the console's font and colours, which redraw the screen, and
  # the first question.
  local shown=$(( EPOCHSECONDS - ${SPLASH_SINCE:-$EPOCHSECONDS} ))
  (( shown >= 4 )) || sleep $(( 4 - shown ))
  setup_console
  # The progress bar covers the installing, not the questions before it: the
  # steps below from partitioning on, then the desktop phase's, which the chroot
  # phase runs and which carries the bar on. Weights: see lib/ui.sh's step
  # (step_weights reads them off the step lines here, as they're written).
  # The desktop phase's AUR step weighs by what this USB brought prebuilt;
  # its fan driver step is there only when this machine needs one built.
  PROGRESS_TOTAL=$(( $(step_weights "$SETUP_DIR/phases/install.sh") + $(step_weights "$SETUP_DIR/phases/desktop.sh")
                     + $(aur_weight "$ISO_PACKAGES") + (${#FAN_PACKAGES} ? FAN_DRIVER_WEIGHT : 0) ))

  ask_questions
  # Bash's own clock; it keeps running through arch-chroot and the desktop
  # phase.
  local started=$SECONDS

  step "Preparing the drive" 6
  partition_and_mount

  step "Installing Arch Linux" 58
  install_base

  step "Setting up your system" 13
  configure_new_system
  # The time it took, before the question below waits on you.
  local took=$(( SECONDS - started ))

  choose_look
  header "Applying the look"
  SPIN_CENTRED=1
  run arch-chroot /mnt env LOOK="$LOOK" bash "/home/$USER_NAME/$USER_SETUP_DIR/setup.sh" look

  close_new_system
  say_goodbye "$took"
  restart_now
}

# ask_questions — the questions, until they end in a yes: nothing is touched
# before. There's no way out of them but answering, or turning the device
# off: leaving would end the USB's start-up and leave the screen black. The
# keyboard first, unless the USB's Wi-Fi screen asked already; going back
# from the review starts again at the keyboard, on the layout picked; Esc
# on the drive list, at the account questions; Go back on the Windows
# screen, at the drive list. Every answer given comes back to keep or
# change.
ask_questions() {
  local ask_keyboard=0 picked windows rest
  local -a details
  read_keyboard_choice || choose_keyboard
  while :; do
    (( ! ask_keyboard )) || choose_keyboard
    ask_keyboard=1
    header "Set up your account"
    input HOST_NAME "Hostname" valid_hostname
    input USER_NAME "Username" valid_username
    # One password for both the user and root.
    password PASSWORD "Password"

    picked=0
    while select_drive; do
      if choose_install_space; then picked=1; break; fi
    done
    (( picked )) || { ask_keyboard=0; continue; }   # Esc: back to the account

    header "Review & confirm"
    details=(Hostname: "$HOST_NAME" Username: "$USER_NAME" Drive: "$DRIVE_LABEL")
    (( ! BESIDE_WINDOWS )) || details+=(Install: "next to Windows, in $(size_label "$FREE_BYTES") free")
    centred_details "${details[@]}" Timezone: "$TIMEZONE" Keyboard: "$KEYBOARD_LABEL"
    echo
    # Going back is the one picked to start with: the other erases the drive,
    # or its free space.
    if (( BESIDE_WINDOWS )); then
      if (( ${#OLD_PARTS[@]} )); then rest="The ARCHMAN installed next to it before is replaced."
      else rest="Nothing else on the drive is touched."; fi
      centred_message "$C_SOFT" "Windows and its files stay as they are. $rest"
      echo
      ! bitlocker_on "$DRIVE" \
        || warn "BitLocker is on: have Windows' recovery key at hand, it may ask for it the next time it starts."
      buttons '' 0 \
        "Go back" "Edit your answers. Your drive hasn't been touched yet." \
        "Yes, install" "Install ARCHMAN in the free space on $DRIVE_LABEL, next to Windows."
    else
      windows=''
      [[ -z $WINDOWS_ESP ]] || windows=', Windows included'
      (( ! STARTUP_FILES )) || windows=", Windows' start-up files included: Windows, on another drive, won't start any more"
      warn "Everything on $DRIVE_LABEL will be erased$windows. This can't be undone."
      buttons '' 0 \
        "Go back" "Edit your answers. Your drive hasn't been touched yet." \
        "Yes, install" "Erase $DRIVE_LABEL and install ARCHMAN on it."
    fi
    (( PICKED == 1 )) && return 0
  done
}

# close_new_system — the new system unmounted first, so nothing on it is
# lost if the stick is pulled; and the live ISO may be running from that
# stick, so `reboot` gets loaded into memory now while it can still be
# read. If it can't be run anyway, sysrq reboots directly — safe, as the
# target is unmounted.
close_new_system() {
  swapoff -a 2>/dev/null || true
  unmount_new_system || warn "Couldn't finish closing the new system. Leave the USB stick in until your device restarts."
  systemctl --version > /dev/null
}

# say_goodbye SECONDS — the last screen: how long it took, how to restart
# (unplugging the USB, or Enter), Tux; then waits for that.
say_goodbye() {
  finish "All done!"
  info "ARCHMAN installed in $(plural $(( $1 / 60 )) minute) and $(plural $(( $1 % 60 )) second)"
  local usb=''
  usb=$(live_usb_disk) || true
  restart_hint "$usb"
  show_tux
  wait_for_usb_removal "$usb"
}

# restart_now — the new system is unmounted and synced, and the live ISO's
# own files are in RAM, so nothing needs a shutdown: --force twice reboots
# at once, without stopping services ("Stopped ..." screens) or waiting on
# processes (iwd ignores SIGTERM, which held a single --force for 90 s).
# No kernel message on the screen after it, not even the reboot's own
# "reboot: Restarting system", an emergency one that dmesg -n 1 (its
# lowest) still lets through: the console's level at 0, so none at all.
# systemctl's own "Rebooting." goes nowhere.
restart_now() {
  info "Restarting..."
  sync
  { echo 0 > /proc/sys/kernel/printk || dmesg -n 1; } 2>/dev/null || true
  systemctl reboot --force --force &>/dev/null || echo b > /proc/sysrq-trigger
}

# choose_look — asks which look the desktop gets, into LOOK: plain (KDE as
# it comes) or archman (the installer's theming, the default).
choose_look() {
  buttons "Choose your desktop's look" 1 \
    VANILLA "KDE Plasma as it comes: KDE's own Breeze theme, login screen and wallpaper." \
    ARCHMAN "Dark theme, the ARCHMAN login screen, a cyberpunk wallpaper, monochrome icons, top panels and a clock widget."
  if (( PICKED == 0 )); then LOOK=plain; else LOOK=archman; fi
}

# Tux on his splat (lib/ui.sh's tux_lines) and his line, on the last
# screen, under the time it took and the restart line: a Linux system now,
# with its penguin. Left out on a screen too short for him and what's left
# to show under him (his line, the goodbye), which would scroll the logo
# away.
show_tux() {
  tux_lines
  (( TUX_WIDTH )) || return 0
  # From the row after the time line (the header's title and blanks under
  # the bar, then that line and its blank): the restart line and its blank,
  # Tux, a blank, his line, a blank, the goodbye (whose own blank, with the
  # restart a moment away, may scroll). 1920x1080's 49 rows fit.
  (( BAR_ROW > 0 && BAR_ROW + TITLE_ROW_OFFSET + 5 + ${#TUX_LINES[@]} + 6 <= ROWS )) || return 0
  local line
  for line in "${TUX_LINES[@]}"; do center "$line" "$TUX_WIDTH"; done
  echo
  centred_message "$C_SOFT" "Tux says hi. He lives here now."
  echo
}

# Unmounts the new system. Whatever the install left running with files
# open in it would keep it busy ("target is busy"): gpg's agents for
# pacman's keyring (started by pacstrap from here, and by pacman inside),
# anything else started inside arch-chroot. So they're stopped first; and
# if it's still busy, a lazy unmount, which finishes once they're gone.
# umount's own complaints go to the log, not the screen.
unmount_new_system() {
  gpgconf --homedir /mnt/etc/pacman.d/gnupg --kill all &>/dev/null || true
  # Only real mount points: fuser -m takes the whole filesystem a path is
  # on, which for an unmounted /mnt would be the live system, this
  # installer included.
  local mounts=() m users
  for m in /mnt /mnt/boot /mnt/efi; do mountpoint -q "$m" && mounts+=("$m"); done
  (( ${#mounts[@]} )) || return 0
  users=$(fuser -m "${mounts[@]}" 2>/dev/null | tr -s ' ') || true
  if [[ -n ${users// } ]]; then
    printf 'Still using the new system, stopped:%s\n' "$users" >> "$LOG_FILE"
    fuser -km "${mounts[@]}" &>/dev/null || true
    sleep 1
  fi
  umount -R /mnt 2>>"$LOG_FILE" || umount -R -l /mnt 2>>"$LOG_FILE"
}

# Left plugged in, the USB can win the boot order and start the installer
# all over again. So the restart waits for the stick (USB, live_usb_disk's)
# to be pulled out, or for Enter: for ISOs booted from a VM's virtual CD,
# where there's no USB to watch (USB empty), only Enter.
# restart_hint USB says which; wait_for_usb_removal USB waits. Not a typing
# prompt: a plain message, and no cursor while it waits (the key pressed
# isn't echoed).
restart_hint() {
  if [[ -n $1 ]]; then info "Unplug the USB stick to restart."; else info "Press Enter to restart."; fi
}
wait_for_usb_removal() {
  local usb=$1 key
  cursor off
  while :; do
    [[ -n $usb && ! -b $usb ]] && { info "See you on the other side!"; return; }
    read -rs -t 1 key && return
  done
}

# Arrow-key menu over the machine's disks, minus the live USB we booted from,
# each shown by name and size, "CT1000P310SSD8 (931.5G)": its model, or its
# device name when it reports none, and the device name too when two drives
# would read the same; one with Windows on it says so, with the free space
# next to it, "· Windows, 412G free". Windows' boot manager (windows_esp)
# can be on another drive than Windows: Windows Setup puts it on the first
# drive the firmware lists, Windows' or not. Windows then starts from that
# one, and a drive with only the boot manager on it says so too, "·
# Windows' start-up files": erased, Windows doesn't start any more. Sets
# DRIVE (/dev/...), DRIVE_LABEL (without the Windows part), WINDOWS_ESP
# (the boot manager's EFI partition, when Windows is on DRIVE; nothing
# otherwise), OWN_ESP (1 when that partition is on another drive: next to
# Windows, ARCHMAN then gets one of its own) and STARTUP_FILES (1 for a
# drive with the boot manager and no Windows).
select_drive() {
  local live_disk=''
  live_disk=$(live_usb_disk) || true

  local -a paths labels items esps boots
  local path size type model i j esp boot=''
  while read -r path size type model; do
    [[ $type == disk && $path != "$live_disk" ]] || continue
    model=${model%%+([[:space:]])}
    paths+=("$path") labels+=("${model:-${path#/dev/}} ($size)")
  done < <(lsblk -dpno PATH,SIZE,TYPE,MODEL)
  (( ${#paths[@]} )) || die "No drive found to install ARCHMAN on. Check it's connected."
  local -a plain=("${labels[@]}")
  for i in "${!plain[@]}"; do
    for j in "${!plain[@]}"; do
      if (( i != j )) && [[ ${plain[i]} == "${plain[j]}" ]]; then
        labels[i]="${plain[i]%)}, ${paths[i]#/dev/})"
        break
      fi
    done
  done
  # Each drive's boot manager, if it has one; boot, the first found, for a
  # Windows on a drive without its own.
  for i in "${!paths[@]}"; do
    esp=$(windows_esp "${paths[i]}") || esp=''
    boots+=("$esp")
    [[ -n $boot ]] || boot=$esp
  done
  for i in "${!paths[@]}"; do
    esp=''
    if [[ -n $boot ]] && windows_on "${paths[i]}" "${boots[i]}"; then esp=${boots[i]:-$boot}; fi
    esps+=("$esp") items+=("${labels[i]}")
    if [[ -n $esp ]]; then
      free_space "${paths[i]}"
      if (( FREE_BYTES >= 1 << 30 )); then items[i]+=" · Windows, $(size_label "$FREE_BYTES") free"
      else items[i]+=" · Windows, no free space"; fi
    elif [[ -n ${boots[i]} ]]; then
      items[i]+=" · Windows' start-up files"
    fi
  done

  # The review screen that follows is the drive's second look. Esc returns
  # 1: back to the account questions. Asked again, on the drive picked
  # before.
  MENU_BACK=1 MENU_START=${DRIVE_ITEM:-} menu "Choose the installation drive" "${items[@]}" || return 1
  for i in "${!items[@]}"; do
    if [[ ${items[i]} == "$MENU_CHOICE" ]]; then
      DRIVE=${paths[i]} DRIVE_LABEL=${labels[i]} DRIVE_ITEM=${items[i]} WINDOWS_ESP=${esps[i]}
      OWN_ESP=0 STARTUP_FILES=0
      [[ -z ${esps[i]} || -n ${boots[i]} ]] || OWN_ESP=1
      [[ -n ${esps[i]} || -z ${boots[i]} ]] || STARTUP_FILES=1
    fi
  done
  [[ -b $DRIVE ]] || die "$DRIVE_LABEL isn't there any more. Check it's connected."
}

# choose_install_space — for a drive with Windows on it (WINDOWS_ESP), the
# Windows screen: install next to it, in free_space's block, or erase the
# drive; BESIDE_WINDOWS 1 or 0 (always 0 on other drives). Next to Windows
# only when the block holds the swap (as big as the RAM), MIN_ROOT_SIZE of
# root, and an EFI partition (OWN_ESP); otherwise how to make room, and Go
# back, which returns 1: the drive list again. Asked again, it starts on
# the button picked before.
choose_install_space() {
  BESIDE_WINDOWS=0
  [[ -n $WINDOWS_ESP ]] || return 0
  free_space "$DRIVE"
  local swap=$(( $(ram_mib) << 20 )) free earlier='' efi=0 startup=''
  (( ! OWN_ESP )) || { efi=$(numfmt --from=iec "$EFI_SIZE"); startup=", $(size_label "$efi") to start it"; }
  local need=$(( swap + (MIN_ROOT_SIZE << 30) + efi ))
  free=$(size_label "$FREE_BYTES")
  (( ! ${#OLD_PARTS[@]} )) || earlier=", the ARCHMAN installed there before included"
  local erase="Erase all of $DRIVE_LABEL, Windows included, and install ARCHMAN on the whole drive."
  header "Windows is on this drive"
  if (( FREE_BYTES >= need )); then
    centred_message "$C_TEXT" "$DRIVE_LABEL has Windows and $free of free space next to it$earlier."
    echo
    buttons '' "${BESIDE_PICKED:-0}" \
      "Next to Windows" "Install ARCHMAN in the $free of free space. Windows and its files stay as they are; you choose between them when the computer starts." \
      "Erase the drive" "$erase"
    BESIDE_PICKED=$PICKED
    (( PICKED )) || BESIDE_WINDOWS=1
    return 0
  fi
  if (( FREE_BYTES >= 1 << 30 )); then free="only $free of free space"; else free="no free space"; fi
  centred_message "$C_TEXT" "$DRIVE_LABEL has Windows and $free next to it. ARCHMAN needs at least $(size_label "$need"): ${MIN_ROOT_SIZE}G for the system and your files$startup, and $(size_label "$swap") for hibernation (this computer's memory)."
  echo
  centred_message "$C_SOFT" "To make room, shrink Windows' drive in Windows' Disk Management (right-click C: and choose Shrink Volume), then start this installer again."
  echo
  buttons '' 0 "Go back" "Choose another drive." "Erase the drive" "$erase"
  (( PICKED ))
}

# windows_esp DRIVE — prints Windows' EFI partition on DRIVE: an EFI system
# partition with Windows' boot manager on it, looked at read-only, or where
# it's mounted already (on /mnt/efi, by an install that stopped: mounting
# it read-only too would fail, and the drive would show without Windows).
# Only on GPT drives: a Windows on an MBR drive starts the BIOS way, which
# GRUB, installed the UEFI way, can't start, and the partitioning here is
# GPT's.
windows_esp() {
  [[ $(lsblk -dno PTTYPE "$1") == gpt ]] || return 1
  local part type dir=/run/archman-esp look found
  mkdir -p "$dir"
  while read -r part type; do
    [[ $type == c12a7328-f81f-11d2-ba4b-00a0c93ec93b ]] || continue
    if ! look=$(findmnt -nfro TARGET -S "$part"); then
      mount -o ro "$part" "$dir" 2>/dev/null || continue
      look=$dir
    fi
    found=0
    [[ -f $look/EFI/Microsoft/Boot/bootmgfw.efi ]] && found=1   # (FAT: any case)
    [[ $look != "$dir" ]] || umount "$dir"
    (( found )) && { echo "$part"; return 0; }
  done < <(lsblk -rnpo PATH,PARTTYPE "$1")
  return 1
}

# windows_on DRIVE ESP — whether Windows is on DRIVE (a GPT one, as
# windows_esp's): its folder (Windows/System32) on one of the NTFS
# partitions, looked at read-only, as windows_esp does; or, with BitLocker
# hiding them, a BitLocker partition next to Windows' boot manager (ESP,
# DRIVE's windows_esp, or nothing) or its recovery partition, as Windows
# Setup leaves its drive. Not a drive with only the boot manager on it.
windows_on() {
  [[ $(lsblk -dno PTTYPE "$1") == gpt ]] || return 1
  local part type fstype look found locked=0 recovery=0 dir=/run/archman-windows
  mkdir -p "$dir"
  # (PARTTYPE before FSTYPE, which can be empty: read would shift it left.)
  while read -r part type fstype; do
    [[ $type != de94bba4-06d1-4d40-a16a-bfd50179d6ac ]] || recovery=1
    [[ $fstype != BitLocker ]] || locked=1
    [[ $fstype == ntfs ]] || continue
    if ! look=$(findmnt -nfro TARGET -S "$part"); then
      # A Windows that's hibernated, or shut down with Fast Startup, mounts
      # read-only only; ntfs-3g when the kernel's driver refuses it anyway.
      mount -o ro "$part" "$dir" 2>/dev/null || mount -t ntfs-3g -o ro "$part" "$dir" 2>/dev/null || continue
      look=$dir
    fi
    found=0
    [[ -d $look/Windows/System32 ]] && found=1
    [[ $look != "$dir" ]] || umount "$dir"
    (( found )) && return 0
  done < <(lsblk -rnpo PATH,PARTTYPE,FSTYPE "$1")
  (( locked && (recovery || ${#2}) ))
}

# Our partitions' names next to Windows: free_space counts them as free
# space, so installing again (after an install that stopped, or over an
# older ARCHMAN) takes their place rather than finding the free space gone.
# The EFI one only when Windows' boot manager is on another drive (OWN_ESP).
BESIDE_EFI_NAME='ARCHMAN EFI' BESIDE_SWAP_NAME='ARCHMAN Swap' BESIDE_ROOT_NAME='ARCHMAN Root'

# free_space DRIVE — the largest free block on a GPT drive, ARCHMAN's own
# partitions (above) counted as free: FREE_FIRST and FREE_LAST, its first
# and last sectors (the first on a MiB, as partitions start), FREE_BYTES,
# and SECTOR_SIZE; OLD_PARTS, those partitions' numbers, and USED_PARTS,
# every other's. From sfdisk's dump of the partition table.
free_space() {
  local line first=0 last=0 start size name number
  local -a spans=()
  SECTOR_SIZE=512 OLD_PARTS=() USED_PARTS=() FREE_FIRST=0 FREE_LAST=0 FREE_BYTES=0
  while IFS= read -r line; do
    case $line in
      first-lba:*)   first=${line##* } ;;
      last-lba:*)    last=${line##* } ;;
      sector-size:*) SECTOR_SIZE=${line##* } ;;
      /*' : '*)
        [[ $line =~ start=\ *([0-9]+) ]] && start=${BASH_REMATCH[1]}
        [[ $line =~ \ size=\ *([0-9]+) ]] && size=${BASH_REMATCH[1]}
        name=''
        [[ $line =~ name=\"([^\"]*)\" ]] && name=${BASH_REMATCH[1]}
        number=${line%% *} number=${number##*[!0-9]}
        if [[ $name == "$BESIDE_EFI_NAME" || $name == "$BESIDE_SWAP_NAME" || $name == "$BESIDE_ROOT_NAME" ]]; then
          OLD_PARTS+=("$number")
        else
          USED_PARTS+=("$number") spans+=("$start $(( start + size - 1 ))")
        fi ;;
    esac
  done < <(sfdisk -d "$1" 2>/dev/null)
  (( last )) || return 0
  # The gaps between the partitions, in the order they're on the drive.
  local from=$first end
  while read -r start end; do
    [[ -n $start ]] || continue
    free_gap "$from" $(( start - 1 ))
    (( end + 1 > from )) && from=$(( end + 1 ))
  done < <(printf '%s\n' "${spans[@]}" | sort -n)
  free_gap "$from" "$last"
}

# free_gap FIRST LAST — free_space's: the sectors from FIRST to LAST, as the
# FREE_ block when it's the largest yet.
free_gap() {
  local align=$(( (1 << 20) / SECTOR_SIZE ))
  local first=$(( ($1 + align - 1) / align * align ))
  local bytes=$(( ($2 - first + 1) * SECTOR_SIZE ))
  (( bytes > FREE_BYTES )) || return 0
  FREE_FIRST=$first FREE_LAST=$2 FREE_BYTES=$bytes
}

# True when a partition on DRIVE is encrypted with BitLocker.
# (Not lsblk | grep -q: grep stops at the first match, and with pipefail
# lsblk's broken pipe would make that a failure.)
bitlocker_on() { grep -qx BitLocker <<< "$(lsblk -rno FSTYPE "$1")"; }

# size_label BYTES — "412G", "9.5G", as lsblk shows sizes; rounded down, so
# free space is never more than it says.
size_label() { numfmt --to=iec --round=down "$1"; }

# This machine's memory, in MiB: the swap's size, for hibernation.
ram_mib() { echo $(( $(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024 )); }

# partition_and_mount — the drive's partitions, formatted and mounted on
# /mnt: the whole drive's (partition_drive), or the free space's next to
# Windows (partition_beside_windows), which leaves Windows' EFI partition as
# it is, mounted on /efi (or, on another drive, ARCHMAN's own, formatted
# here). Either sets EFI_PART, SWAP_PART and ROOT_PART;
# SWAP_PART is for hibernation too (the chroot phase): this partition, not
# one found by its label, which another disk's older install may carry too.
partition_and_mount() {
  # Undo a half-finished previous attempt so a re-run doesn't hit "busy".
  local part fstype
  while read -r part fstype; do
    [[ $fstype != swap ]] || swapoff "$part" 2>/dev/null || true
  done < <(lsblk -rnpo PATH,FSTYPE "$DRIVE")
  umount -R /mnt 2>/dev/null || true

  local ram_mib
  ram_mib=$(ram_mib)
  note "Creating space for the system, hibernation and your files"
  if (( BESIDE_WINDOWS )); then partition_beside_windows "$ram_mib"; else partition_drive "$ram_mib"; fi
  partprobe "$DRIVE" 2>/dev/null || true
  # partprobe only makes the kernel re-read the table; udev still has to
  # create the device nodes before the check below can pass.
  udevadm settle
  [[ -b $EFI_PART && -b $SWAP_PART && -b $ROOT_PART ]] || die "Couldn't prepare $DRIVE_LABEL for the installation."
  # What the space held before (an older install's file system) isn't left
  # for blkid to find under the new ones.
  run wipefs -a "$SWAP_PART" "$ROOT_PART"

  note "Setting up the file system..."
  (( BESIDE_WINDOWS && ! OWN_ESP )) || run mkfs.fat -F32 -n BOOT "$EFI_PART"
  run mkswap -L SWAP "$SWAP_PART"
  run mkfs.btrfs -f -L ROOT "$ROOT_PART"

  run mount "$ROOT_PART" /mnt
  run btrfs subvolume create /mnt/@ /mnt/@home
  run umount /mnt
  run mount -o "$BTRFS_MOUNT_OPTS,subvol=@" "$ROOT_PART" /mnt
  mkdir -p /mnt/{boot,home}
  run mount -o "$BTRFS_MOUNT_OPTS,subvol=@home" "$ROOT_PART" /mnt/home
  # Next to Windows, /boot (the kernels) stays on Btrfs: Windows' EFI
  # partition, often 100 MB, has no room for them.
  if (( BESIDE_WINDOWS )); then mkdir -p /mnt/efi; run mount "$EFI_PART" /mnt/efi
  else run mount "$EFI_PART" /mnt/boot; fi
  run swapon "$SWAP_PART"
}

# partition_drive RAM_MIB — the whole drive, erased: EFI, swap (RAM_MIB),
# root in the rest.
partition_drive() {
  EFI_PART=$(partition_path "$DRIVE" 1) SWAP_PART=$(partition_path "$DRIVE" 2) ROOT_PART=$(partition_path "$DRIVE" 3)
  printf 'Layout: %s EFI, %sM swap (= RAM, for hibernation), rest Btrfs\n' "$EFI_SIZE" "$1" >> "$LOG_FILE"
  run wipefs -af "$DRIVE"
  run sgdisk -Z \
    -n1:0:+"$EFI_SIZE"    -t1:ef00 -c1:EFI \
    -n2:0:+"${1}M"        -t2:8200 -c2:Swap \
    -n3:0:0               -t3:8300 -c3:Root "$DRIVE"
}

# partition_beside_windows RAM_MIB — swap (RAM_MIB) and root in free_space's
# block, by its exact sectors (sgdisk's defaults would take the first free
# space, which can be another, smaller one), with the lowest partition
# numbers no other partition has; an earlier ARCHMAN's partitions, part of
# that block, deleted first. With Windows' boot manager on another drive
# (OWN_ESP), an EFI partition of ARCHMAN's own first, so that drive isn't
# touched either; otherwise Windows' EFI partition is ARCHMAN's too.
# Nothing else on the drive is touched.
partition_beside_windows() {
  free_space "$DRIVE"
  local -a old=() numbers=() parts=()
  local n start=$FREE_FIRST end efi own=''
  for n in "${OLD_PARTS[@]}"; do old+=(-d "$n"); done
  for (( n = 1; n <= 128 && ${#numbers[@]} < 3; n++ )); do
    [[ " ${USED_PARTS[*]} " == *" $n "* ]] || numbers+=("$n")
  done
  EFI_PART=$WINDOWS_ESP
  if (( OWN_ESP )); then
    efi=$(numfmt --from=iec "$EFI_SIZE")
    end=$(( start + efi / SECTOR_SIZE - 1 ))
    parts+=(-n"${numbers[0]}:$start:$end" -t"${numbers[0]}":ef00 -c"${numbers[0]}:$BESIDE_EFI_NAME")
    EFI_PART=$(partition_path "$DRIVE" "${numbers[0]}")
    start=$(( end + 1 )) numbers=("${numbers[@]:1}") own="$EFI_SIZE EFI (Windows' is on another drive), "
  fi
  end=$(( start + ($1 << 20) / SECTOR_SIZE - 1 ))
  parts+=(-n"${numbers[0]}:$start:$end"               -t"${numbers[0]}":8200 -c"${numbers[0]}:$BESIDE_SWAP_NAME"
          -n"${numbers[1]}:$(( end + 1 )):$FREE_LAST" -t"${numbers[1]}":8300 -c"${numbers[1]}:$BESIDE_ROOT_NAME")
  printf 'Layout: next to Windows, in sectors %s-%s: %s%sM swap (= RAM, for hibernation), rest Btrfs; replaced: %s\n' \
    "$FREE_FIRST" "$FREE_LAST" "$own" "$1" "${OLD_PARTS[*]:-nothing}" >> "$LOG_FILE"
  (( ! ${#old[@]} )) || run sgdisk "${old[@]}" "$DRIVE"
  run sgdisk "${parts[@]}" "$DRIVE"
  SWAP_PART=$(partition_path "$DRIVE" "${numbers[0]}") ROOT_PART=$(partition_path "$DRIVE" "${numbers[1]}")
}

# Ranks the mirrors pacstrap downloads from: the fastest in our country;
# worldwide when it isn't known or has no HTTPS mirrors reflector can find
# (it then leaves no Server lines). Only mirrors that run at most 4 hours
# behind Arch (--delay; --age isn't enough, a mirror can sync often from a
# stale source): pacman takes the package lists from the first mirror alone,
# and a fast but stale one (glua.ua.pt, days behind) lists versions every
# current mirror has since deleted, so every download 404s.
rank_mirrors() {
  local countries mirrorlist=/etc/pacman.d/mirrorlist
  countries=$(mirror_countries)
  if [[ -n $countries ]]; then
    note "Finding the fastest download servers near you ($countries)..."
    run reflector --country "$countries" --delay 4 --latest 8 --protocol https \
      --sort rate --number 6 --save "$mirrorlist" || true
  fi
  if [[ -z $countries ]] || ! grep -q '^Server' "$mirrorlist"; then
    note "Finding the fastest download servers worldwide..."
    run reflector --delay 4 --latest 20 --protocol https --sort rate --number 6 --save "$mirrorlist" \
      || note "Couldn't rank download servers, using the default ones"
  fi
  # Last resort, for a file the mirrors above haven't synced yet: pacman
  # tries the servers in order for each package. Arch's own servers, among
  # the first to sync. It goes into the new system's mirrorlist too; the
  # mirrors are logged, for when a download fails.
  echo 'Server = https://geo.mirror.pkgbuild.com/$repo/os/$arch' >> "$mirrorlist"
  { echo 'Mirrors:'; grep '^Server' "$mirrorlist"; } >> "$LOG_FILE"
}

install_base() {
  share 0 50    # reflector, timing the mirrors: a few seconds
  rank_mirrors

  # Microcode and GPU drivers go in with the base system, so the initramfs
  # the chroot phase builds already includes them: NVIDIA machines boot on
  # nvidia-open from the very first boot instead of nouveau.
  local -a packages=("${BASE_PACKAGES[@]}") gpu vendors
  case $(cpu_vendor) in
    intel) packages+=(intel-ucode) ;;
    amd)   packages+=(amd-ucode) ;;
    *)     note "Unknown CPU vendor, skipping microcode" ;;
  esac
  mapfile -t vendors < <(gpu_vendors)
  if (( ${#vendors[@]} )); then
    local names='' vendor
    for vendor in "${vendors[@]}"; do
      case $vendor in intel) vendor=Intel ;; amd) vendor=AMD ;; nvidia) vendor=NVIDIA ;; esac
      names+=${names:+ and }$vendor
    done
    note "Found $names graphics, adding the drivers"
  else
    warn "No Intel, AMD or NVIDIA graphics found, using basic graphics drivers"
  fi
  mapfile -t gpu < <(gpu_packages)
  packages+=("${gpu[@]}")

  # pacstrap reads the ISO's pacman.conf, and -P copies it into the new
  # system, so changes here cover both. The drivers' 32-bit halves (for
  # Steam) live in multilib. And PARALLEL_DOWNLOADS files at once (config.sh)
  # rather than pacman's 5: hundreds of small packages, each with a round
  # trip to the mirror before its bytes.
  sed -i '/^#\[multilib\]/,/^#Include/ s/^#//' /etc/pacman.conf
  sed -i -E "s/^#?ParallelDownloads.*/ParallelDownloads = $PARALLEL_DOWNLOADS/" /etc/pacman.conf
  # And CachyOS's repositories, above Arch's (lib/gaming.sh).
  share 50 100
  add_cachyos_repos

  share 100 1000
  note "Downloading and installing the core system. This takes a few minutes."
  # pacstrap downloads into the new system's cache (see lib/ui.sh's
  # measured_progress).
  local PACMAN_CACHE=/mnt/var/cache/pacman/pkg
  printf 'Packages: %s\n' "${packages[*]}" >> "$LOG_FILE"
  retry 10 run pacstrap -K -P /mnt "${packages[@]}" || die "Couldn't download Arch Linux. Check your internet connection."
  genfstab -U /mnt >> /mnt/etc/fstab
  cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
}

# Copies this installer into the new root and re-invokes it there. The
# copies through run, for its spinner: the icon theme is thousands of files,
# read off the USB's compressed system, seconds with nothing moving.
configure_new_system() {
  carry_wifi_networks
  local stage=/mnt$CHROOT_SETUP_DIR
  rm -rf "$stage"
  run cp -r "$SETUP_DIR" "$stage"
  # The AUR packages this USB brought prebuilt, for the desktop phase.
  if compgen -G "$ISO_PACKAGES/*.pkg.tar.zst" > /dev/null; then
    mkdir -p "$stage/packages"
    run cp "$ISO_PACKAGES"/*.pkg.tar.zst "$stage/packages/"
  fi
  # And the icon theme and widgets it brought, for the first Plasma session.
  [[ ! -d $ISO_EXTRAS ]] || run cp -r "$ISO_EXTRAS" "$stage/extras"

  # Passwords travel in a root-only file, never in argv or the environment.
  # The chroot phase deletes it as its first act; the trap covers the case
  # where arch-chroot never gets that far.
  trap 'rm -f '"$stage/creds" EXIT
  install -m 600 /dev/null "$stage/creds"
  printf '%s\n' "$PASSWORD" > "$stage/creds"

  # The bar carries on in the chroot phase, and from there in the desktop phase.
  screen_env
  arch-chroot /mnt env HOST_NAME="$HOST_NAME" USER_NAME="$USER_NAME" TIMEZONE="$TIMEZONE" TIME_LOCALE="$TIME_LOCALE" \
    KEYMAP="$KEYMAP" X11_LAYOUT="$X11_LAYOUT" X11_VARIANT="$X11_VARIANT" X11_OPTIONS="$X11_OPTIONS" \
    SWAP_PART="$SWAP_PART" BESIDE_WINDOWS="$BESIDE_WINDOWS" WINDOWS_ESP="$WINDOWS_ESP" OWN_ESP="$OWN_ESP" FAN_MODULES="$FAN_MODULES" FAN_PACKAGES="$FAN_PACKAGES" "${SCREEN_ENV[@]}" \
    bash "$CHROOT_SETUP_DIR/setup.sh" chroot
  # The desktop phase has done every step, and logged the last one's time: the
  # screens that follow show the bar full.
  progress_full
}

# Prints the disk the live ISO booted from (/dev/sdX). Where it's mounted,
# or, once the ISO has copied itself to RAM and let go of it (copytoram,
# archiso's default with memory to spare: the image and 2 GiB more), the
# device with the ISO's UUID, which the boot found it by
# (archisosearchuuid). The disk under it, by walking down from it
# (lsblk -s): a USB written with the ISO is mounted whole (/dev/sdb, its
# filesystem starts at the stick's first byte), where a partition's parent
# (PKNAME) is nothing; others mount a partition, or a device-mapper one over
# it (Ventoy). A VM's virtual CD is a rom, not a disk: nothing, as there's
# nothing to unplug.
live_usb_disk() {
  local source='' name type uuid path id
  if ! source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null); then
    [[ $(< /proc/cmdline) =~ archisosearchuuid=([^ ]+) ]] || return 1
    uuid=${BASH_REMATCH[1]} source=''
    while read -r path id; do
      [[ $id == "$uuid" ]] && { source=$path; break; }
    done < <(lsblk -rnpo PATH,UUID)
    [[ -n $source ]] || return 1
  fi
  while read -r name type; do
    [[ $type == disk ]] && { echo "/dev/$name"; return 0; }
  done < <(lsblk -nrso NAME,TYPE "$source" 2>/dev/null)
  return 1
}

# The Wi-Fi networks the live ISO connected to (its iwd remembers them, in
# /var/lib/iwd: phases/wifi.sh's) as NetworkManager
# connections on the new system, so it's online from its first boot: the
# first Plasma session downloads its widgets and icons. Root-only files, as
# they hold the passwords. iwd names a file by the network's name, or "="
# and the name in hex when it has other characters than letters, digits,
# - and _; NetworkManager then gets the name as its bytes.
carry_wifi_networks() {
  local file base ssid name security secret hex i escapes dir=/mnt/etc/NetworkManager/system-connections
  for file in /var/lib/iwd/*.psk /var/lib/iwd/*.open; do
    [[ -f $file ]] || continue
    base=${file##*/} base=${base%.*}
    if [[ $base == =* ]]; then
      # Hex, two digits a byte: the name as text (for its id and file), and
      # the SSID as NetworkManager takes raw bytes, "104;105;" for "hi".
      hex=${base#=} escapes='' ssid=''
      [[ $hex =~ ^([0-9a-fA-F]{2})+$ ]] || continue
      for (( i = 0; i < ${#hex}; i += 2 )); do
        escapes+="\\x${hex:i:2}" ssid+="$(( 16#${hex:i:2} ));"
      done
      printf -v name '%b' "$escapes"
    else
      name=$base ssid=$base
    fi
    security=''
    if [[ $file == *.psk ]]; then
      secret=$(sed -n 's/^Passphrase=//p' "$file" | head -1)
      [[ -n $secret ]] || secret=$(sed -n 's/^PreSharedKey=//p' "$file" | head -1)
      [[ -n $secret ]] || continue
      printf -v security '[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n' "$secret"
    fi
    printf '[connection]\nid=%s\ntype=wifi\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n%s\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
      "$name" "$ssid" "$security" | write_file "$dir/${name//\//_}.nmconnection" 600
    printf 'Wi-Fi carried over: %s\n' "$name" >> "$LOG_FILE"
  done
}
