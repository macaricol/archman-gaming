#!/usr/bin/env bash
# Every user-tunable value lives here; the phases only read from this file.

# ── Source repo (used by bootstrap.sh and the ISO builder) ──────────────
REPO=${REPO:-macaricol/archman-gaming}
BRANCH=${BRANCH:-main}

# ── Install media (tools/build-autoinstall-iso.sh) ─────────────────────
# Where the builder fetches the official ISO from when you don't hand it one.
# Any Arch mirror works; this is the project's own geo-balanced one.
ISO_MIRROR='https://geo.mirror.pkgbuild.com/iso/latest'

# ── Installer look ─────────────────────────────────────────────────────
# Shown under the logo (assets/logo) on every step.
TAGLINE='ARCHMAN · KDE Plasma'
# The 16 console colours used while installing, in VT order. Built on the
# palette 01050E near-black, 021742 navy, 033574 blue, A80440 crimson,
# F3065E neon pink, and FFC400 Pac-Man yellow; the grey-white text,
# blue-grey hints, amber warnings and red-orange errors are tints added for
# roles it has no colour for. How lib/ui.sh uses them:
#   0 background · 2 the logo's extrusion · 3 Pac-Man (in the logo, the
#   tags and the spinner) · 6 the logo's letters
#   4 empty progress bar, unselected buttons · 5 Tux's splat (the hints'
#   blue-grey, in a slot the 512-glyph font keeps) · 7 the facts · 8 hints
#   9 errors · 10 closing title · 11 warnings · 13 tagline
#   14 progress · 15 text
# Only applies on a real console (TERM=linux), not in a terminal emulator.
CONSOLE_PALETTE=(
  # black  red    green  yellow blue   magenta cyan   white
  01050E A80440 033574 FFC400 021742 4A5A80 F3065E 8E95A8
  4A5A80 FF5A3C F3065E E0A040 033574 A80440 F3065E C9CEDB
)

# ── Locale ─────────────────────────────────────────────────────────────
# The timezone: auto is where this machine is, by its public IP, looked up
# during the install (UTC if that fails); or a fixed one, e.g. 'Europe/Lisbon'.
# Never asked. (The install phase hands its answer on, hence the ${...:-}.)
TIMEZONE=${TIMEZONE:-auto}
# The keyboard is asked, the layout of where this machine is first (the
# list: lib/keyboard.sh's KEYBOARD_LAYOUTS). These are its answer, handed
# on to the later phases, or US until it's given.
KEYMAP=${KEYMAP:-us}                 # the console's: live ISO and installed system
X11_LAYOUT=${X11_LAYOUT:-us}         # Plasma's and the login screen's
X11_VARIANT=${X11_VARIANT:-}
X11_OPTIONS=${X11_OPTIONS:-}
LOCALE='en_US.UTF-8'                 # the language, everywhere: Plasma, terminal, numbers. Never asked.
# Dates and times (LC_TIME) in the way of where this machine is: auto is the
# country's, by its public IP, looked up during the install (LOCALE's if
# that fails); or a fixed one, e.g. 'en_GB.UTF-8'. Never asked.
TIME_LOCALE=${TIME_LOCALE:-auto}

# ── Disk ───────────────────────────────────────────────────────────────
# Layout is always: EFI, swap sized to RAM (so hibernation works), Btrfs root
# with @ and @home subvolumes. Next to Windows (a drive with Windows on it
# and free space beside it), only swap and root, in the largest free block,
# all of it, and Windows' EFI partition as /efi (an EFI partition of
# ARCHMAN's own first, in that block, when Windows' is on another drive);
# the block must hold them and at least MIN_ROOT_SIZE (GiB) of root.
MIN_ROOT_SIZE=30
# GRUB's menu, next to Windows (hidden otherwise): its seconds before it
# starts the first entry, ARCHMAN, and its theme (assets/grub/archman,
# rebuilt with tools/make-grub-theme.py), drawn for this mode, the
# firmware's own when it has none.
GRUB_MENU_TIMEOUT=5
GRUB_MENU_GFXMODE='1920x1080,auto'
# Mirrors are ranked in this machine's country, looked up from its public IP
# (auto), or in the countries listed here, e.g. 'PT,ES'.
MIRROR_COUNTRIES='auto'
# Files pacman downloads at once, during the install and on the new system
# (pacman's own default is 5).
PARALLEL_DOWNLOADS=10
EFI_SIZE='512M'           # erasing the drive; next to Windows, its own is used
BTRFS_MOUNT_OPTS='noatime,compress=zstd:1'

# ── Packages ───────────────────────────────────────────────────────────
# Installed from CachyOS's repositories as well as Arch's (lib/gaming.sh's
# add_cachyos_repos): every package they rebuild, for this CPU, comes from
# them. Their kernel, linux-cachyos (BORE scheduler, built with LTO and
# profile-guided optimisation), not the stock one; their keyring and mirror
# lists, which keep the system on their repos; cachyos-settings, their
# system tuning (zram, sysctls, I/O schedulers...); the sched_ext CPU
# schedulers with their loader; and lm_sensors (sensors, fancontrol), for
# the fans the motherboard's fan driver brings (lib/gaming.sh).
BASE_PACKAGES=(base linux-cachyos linux-firmware btrfs-progs grub efibootmgr nano networkmanager sudo plymouth pciutils
               cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist cachyos-settings
               scx-scheds scx-tools lm_sensors)

KDE_PACKAGES=(
  plasma-desktop sddm sddm-kcm kscreen plasma-pa plasma-nm plasma-systemmonitor
  bluedevil kdeconnect kdenetwork-filesharing kwalletmanager
  konsole dolphin ark featherpad kio-admin spectacle
  kde-gtk-config   # GTK apps (Zen) follow KDE: window buttons, fonts, cursor, theme
  kdegraphics-thumbnailers ffmpegthumbs pipewire-jack
)

EXTRA_PACKAGES=(
  fastfetch mpv krdc krdp git code
  ttf-liberation noto-fonts-cjk
  ntfs-3g exfatprogs dosfstools   # format/repair NTFS, exFAT, FAT32 (mounting needs nothing extra)
  matugen                         # skwd-wall's desktop colours, from the wallpaper
  coolercontrol                   # fan curves, the motherboard's and the GPU's (CachyOS's repo; brings its service)
)

# Only installed when a supported GPU was detected, see desktop phase. Steam,
# and for its games: Proton-CachyOS (CachyOS's Proton, built for Steam's
# runtime; picked in Steam's Compatibility settings), GameMode
# (gamemoderun %command%), MangoHud's overlay (mangohud %command%; Shift+F12
# toggles it) and gamescope, Valve's compositor for one game (upscaling,
# frame limits, HDR). And LACT, the graphics card's settings: clocks, power
# limit, undervolt, fan curve (AMD, NVIDIA, Intel).
GAMING_PACKAGES=(steam proton-cachyos-slr gamemode lib32-gamemode mangohud lib32-mangohud gamescope lact)
# From the AUR, installed in this order. paru first, with makepkg (its
# dependencies all official): the AUR helper, which installs the rest (it
# finds each one's recipe and AUR dependencies) and then keeps them all up
# to date (paru -Syu, or Apdatifier in the panel), itself included. Those
# built from source (all but -bin) come prebuilt on the USB. skwd-wall, the
# wallpaper picker, comes as four, from two recipes.
AUR_PACKAGES=(paru zen-browser-bin qview skwd-paper-bin skwd-deck-bin skwd-wall-v2-bin skwd-paper-plasma)
# The -bin ones the USB carries prebuilt too (tools/build-autoinstall-iso.sh;
# a -bin package is only a download, otherwise left to installs): skwd-wall's,
# a beta, so an install doesn't depend on its downloads being up then.
AUR_PREBUILT_BIN=(skwd-paper-bin skwd-deck-bin skwd-wall-v2-bin)

# The lib32-* packages are what Steam needs. Installing the right ones up
# front matters: steam depends on virtual lib32-vulkan-driver / lib32-libgl,
# and pacman --noconfirm would otherwise pick lib32-nvidia-utils (and with it
# the whole NVIDIA userspace) even on AMD/Intel machines.
GPU_PACKAGES_INTEL=(mesa lib32-mesa vulkan-intel lib32-vulkan-intel intel-media-driver)
GPU_PACKAGES_AMD=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon radeontop)
# nvidia-open, not nvidia: the proprietary kernel modules are gone from the
# repos (nvidia-open declares Replaces: nvidia<=580.119.02-2), so the old name
# is simply "target not found" and aborts the whole desktop phase. CachyOS's
# build of its modules for their kernel, linux-cachyos-nvidia-open: Arch's
# nvidia-open is only for the stock `linux` one. Note this only drives Turing (RTX 20xx)
# and newer — NVIDIA's 615 branch dropped Maxwell/Pascal/Volta, and with the
# proprietary package gone those cards now fall back to nouveau.
GPU_PACKAGES_NVIDIA=(linux-cachyos-nvidia-open nvidia-utils lib32-nvidia-utils nvidia-settings opencl-nvidia)
# VMs and unknown hardware. Deliberately no software Vulkan: a 64-bit Vulkan
# device (vulkan-swrast) makes the SDDM theme's video background render blank
# under VirtualBox (in the astronaut SDDM theme), and lib32-vulkan-swrast
# can't be installed without it.
GPU_PACKAGES_FALLBACK=(mesa lib32-mesa)

# ── Audio ──────────────────────────────────────────────────────────────
# PipeWire does not upmix by default: on a surround card, stereo content
# plays out of front L/R only and the rear/side/centre speakers stay silent.
# These settings feed every speaker. Set UPMIX_SURROUND=0 on a machine with
# plain stereo output, where upmixing does nothing useful.
UPMIX_SURROUND=1
UPMIX_METHOD='psd'        # psd = matrix-decode rears from L-R; also 'simple', 'none'
UPMIX_LFE_CUTOFF=150      # Hz and below go to the subwoofer
UPMIX_FC_CUTOFF=12000     # Hz and below go to the centre speaker
UPMIX_REAR_DELAY=12.0     # ms of Haas delay on the rears, so they stay behind you

# ── Gaming ─────────────────────────────────────────────────────────────
# The tuning in lib/gaming.sh. The CPU scheduler (sched_ext): scx_lavd,
# Valve's, made for the Steam Deck: it finds a game's latency-critical
# threads and runs them first. Its mode: Gaming, or Auto, LowLatency,
# PowerSave, Server (scx_loader's); scxctl switches them on a running
# system. '' keeps the kernel's own scheduler (BORE, linux-cachyos's).
SCX_SCHEDULER='scx_lavd'
SCX_MODE='Gaming'
# CachyOS's signing key (assets/cachyos/cachyos.gpg, from their keyring
# package), by its full fingerprint: their packages are trusted by this.
CACHYOS_KEY='882DCFE48E2051D48E2562ABF3B607488DB35A47'
# Mesa's and NVIDIA's shader caches, each.
SHADER_CACHE_SIZE='12G'
# The CPU's protections against Spectre-class attacks. off gives back a few
# percent in CPU-bound games on older Intel CPUs (little on recent ones and
# on AMD), but leaves the browser and everything else open to them.
CPU_MITIGATIONS='on'

# ── Screen ─────────────────────────────────────────────────────────────
# The screens' brightness, in percent, set in the first Plasma session (a
# laptop's panel, or a monitor through DDC/CI); both looks.
BRIGHTNESS=80

# ── Look & feel ────────────────────────────────────────────────────────
# The login screen: the archman theme (assets/sddm/archman), an Omarchy-style
# unlock screen in the installer's look (rebuild with tools/make-sddm-theme.py).
SDDM_THEME='archman'
# Installed too, with its fonts: it stays available as an alternative login
# theme in System Settings.
ASTRONAUT_REPO='https://github.com/macaricol/sddm-astronaut-theme.git'
ASTRONAUT_THEME='sddm-astronaut-theme'
# The wallpapers (assets/wallpapers), installed system-wide here and copied
# into the user's ~/Pictures/Wallpapers (skwd-wall's folder); and the one
# applied: the desktop's and the lock screen's.
WALLPAPERS_DIR=/usr/share/wallpapers/archman
WALLPAPER="$WALLPAPERS_DIR/synthwave-city-sunset.jpg"
# The icon theme: YAMIS (yet another monochrome icon set), the repo itself,
# installed under ICON_THEME; and the one applied, ICON_THEME_APPLIED, which
# inherits it: assets/icons/YAMIS-Grey (tools/make-yamis-grey.py), its
# folders, Trash and Recent Files toned down to a grey.
ICON_THEME_REPO='https://bitbucket.org/dirn-typo/yet-another-monochrome-icon-set.git'
ICON_THEME='YAMIS'
ICON_THEME_APPLIED='YAMIS-Grey'
PLASMOID_REPOS=(                     # each repo's package/ directory, or the repo itself (metadata.json at its top)
  https://github.com/macaricol/kde_modernclock.git
  https://github.com/exequtic/apdatifier
  https://github.com/luisbocanegra/plasma-panel-colorizer   # the panels' look (the Translucent preset)
  https://github.com/yassine20011/kvitals   # system monitor, in its own panel
)

# ── Samba ──────────────────────────────────────────────────────────────
SAMBA_WORKGROUP='WORKGROUP'
