#!/usr/bin/env bash
# The gaming build, in one place, so the rest stays as upstream's: CachyOS's
# repositories, added on the live ISO before pacstrap so the whole system
# comes from them; the system's tuning (kernel options, scheduler, drivers),
# run as root by the chroot phase before the initramfs and grub.cfg are
# built; and the user's (GameMode, the desktop), run by the desktop phase
# once the gaming packages are in. The values are config.sh's Gaming section.

# ── CachyOS ────────────────────────────────────────────────────────────

# cachyos_level — the CPU's best CachyOS build, as their own cachyos-repo.sh
# picks it: znver4 (AMD Zen 4 and later), v4 (AVX-512), v3 (AVX2: Intel
# Haswell, AMD Zen 1 and later), or nothing for an older CPU, which gets
# only their generic repo (their kernel, Proton and tools; Arch's builds of
# the rest). By the dynamic loader's own test of the CPU, and for znver4 the
# CPU family (25, Zen 3 and 4, of which only Zen 4 has AVX-512; 26, Zen 5),
# as their test (gcc -march=native) needs a compiler the ISO doesn't have.
cachyos_level() {
  local levels family
  levels=$(/lib/ld-linux-x86-64.so.2 --help)
  family=$(lscpu | awk -F: '/^CPU family/ { print $2 + 0 }')
  if [[ $levels == *'x86-64-v4 (supported, searched)'* ]]; then
    if [[ $(cpu_vendor) == amd ]] && (( family >= 25 )); then echo znver4; else echo v4; fi
  elif [[ $levels == *'x86-64-v3 (supported, searched)'* ]]; then
    echo v3
  fi
}

# add_cachyos_repos — on the live ISO, before pacstrap, which reads its
# pacman.conf and copies it into the new system (-P): CachyOS's repositories
# for this CPU, above Arch's, so every package they rebuild comes from them
# (multilib, which they don't rebuild, stays Arch's). What cachyos-repo.sh
# does, without running it:
# - their signing key, from assets/cachyos (their keyring package's),
#   trusted by its full fingerprint (CACHYOS_KEY) rather than fetched from a
#   keyserver at install time. The new system gets it from cachyos-keyring,
#   which pacstrap installs (BASE_PACKAGES) and whose install script
#   populates it.
# - their mirror lists: a first one of their two main servers, enough to
#   fetch their mirrorlist packages, whose full lists then replace it.
# - the packages' architectures (x86_64_v3...) named in Architecture, which
#   their own pacman works out (auto) but the ISO's doesn't. Their lists'
#   $arch_v3 needs nothing: pacman replaces $arch in it, giving x86_64_v3.
# Already there on a restarted install: kept.
add_cachyos_repos() {
  grep -q '^\[cachyos\]' /etc/pacman.conf && return 0
  local level arches=x86_64 list repo section='' name
  local -a repos=()
  level=$(cachyos_level)
  case $level in
    znver4) repos=(cachyos-znver4 cachyos-core-znver4 cachyos-extra-znver4) list=v4 arches+=' x86_64_v3 x86_64_v4' ;;
    v4)     repos=(cachyos-v4 cachyos-core-v4 cachyos-extra-v4) list=v4 arches+=' x86_64_v3 x86_64_v4' ;;
    v3)     repos=(cachyos-v3 cachyos-core-v3 cachyos-extra-v3) list=v3 arches+=' x86_64_v3' ;;
  esac
  note "Adding CachyOS's packages, built for ${level:-any} processors"
  printf 'CachyOS: %s\n' "${level:-generic}" >> "$LOG_FILE"

  run pacman-key --add "$SETUP_DIR/assets/cachyos/cachyos.gpg" \
    && run pacman-key --lsign-key "$CACHYOS_KEY" \
    || die "Couldn't set up CachyOS's signing key."

  for name in '' v3 v4; do
    printf 'Server = https://%s/repo/$arch%s/$repo\n' cdn77.cachyos.org "${name:+_$name}" mirror.cachyos.org "${name:+_$name}" \
      > "/etc/pacman.d/cachyos${name:+-$name}-mirrorlist"
  done
  for repo in "${repos[@]}"; do
    section+="[$repo]\nInclude = /etc/pacman.d/cachyos-$list-mirrorlist\n\n"
  done
  section+='[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n\n'
  # Before the first repository: pacman takes a package from the first
  # that has it.
  awk -v section="$section" '!done && /^\[/ && $0 != "[options]" { printf "%s", section; done = 1 } 1' \
    /etc/pacman.conf > /etc/pacman.conf.new && mv /etc/pacman.conf.new /etc/pacman.conf
  sed -i -E "s/^#?Architecture *=.*/Architecture = $arches/" /etc/pacman.conf

  retry 10 run pacman -Sy --needed --noconfirm --overwrite '/etc/pacman.d/cachyos*' \
      cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist \
    || die "Couldn't reach CachyOS's servers. Check your internet connection."
}

# ── The system ─────────────────────────────────────────────────────────
# cachyos-settings (BASE_PACKAGES) brings most of it: zram, the sysctls,
# huge pages, the I/O schedulers, NTSYNC's module, no hardware watchdogs.
# What it leaves out, here.

configure_gaming_system() {
  # The kernel's soft watchdog off too: a timer on every core, for a lockup
  # detector a desktop has no use for. zswap off from the start, as zram
  # does the compressing (cachyos-settings turns it off only once zram is up).
  add_kernel_option nowatchdog
  add_kernel_option zswap.enabled=0
  [[ $CPU_MITIGATIONS != off ]] || add_kernel_option mitigations=off

  # On top of cachyos-settings' (70-cachyos-settings.conf).
  write_file /etc/sysctl.d/80-gaming.conf <<'EOF'
# Managed by arch-setup (lib/gaming.sh).
# zram's (Arch wiki, Zram#Optimizing swap on zram): no reclaim bursts ahead
# of need.
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
# No memory compaction in the background, stealing cycles mid-frame.
vm.compaction_proactiveness = 0
# SteamOS's: some games need more memory maps than Arch's 1048576, and a
# game that splits a lock isn't slowed down on purpose for it (- : skipped
# on a kernel without that knob).
vm.max_map_count = 2147483642
-kernel.split_lock_mitigate = 0
EOF

  # NTSYNC: Windows' synchronisation done by the kernel, for Wine and Proton.
  # cachyos-settings loads the module; its device is root's only.
  echo 'KERNEL=="ntsync", MODE="0644"' | write_file /etc/udev/rules.d/60-ntsync.rules

  # The CPU scheduler: SCX_SCHEDULER (sched_ext), loaded at boot by
  # scx_loader in SCX_MODE, in place of the kernel's own (BORE, on
  # linux-cachyos). If it ever fails, the kernel goes back to its own by
  # itself. None, with SCX_SCHEDULER empty. ananicy-cpp, which
  # cachyos-settings brings, is left off: it renices processes, which
  # schedulers like scx_lavd make their own decisions about.
  if [[ -n $SCX_SCHEDULER ]]; then
    printf 'default_sched = "%s"\ndefault_mode = "%s"\n' "$SCX_SCHEDULER" "$SCX_MODE" \
      | write_file /etc/scx_loader.toml
    enable_service scx_loader
  fi

  # Shader caches big enough to keep a library's shaders (Mesa's default is
  # 1 GB, NVIDIA's even less), so games don't recompile them, and stutter,
  # after the cache has been trimmed. Proton told to use NTSYNC.
  write_file /etc/environment.d/80-gaming.conf <<EOF
MESA_SHADER_CACHE_MAX_SIZE=$SHADER_CACHE_SIZE
__GL_SHADER_DISK_CACHE_SIZE=$(numfmt --from=iec "$SHADER_CACHE_SIZE")
__GL_SHADER_DISK_CACHE_SKIP_CLEANUP=1
PROTON_USE_NTSYNC=1
EOF

  # NVIDIA: memory mapped with the CPU's page attribute table, as on
  # Windows (cachyos-settings already skips zeroing its system memory). In
  # the initramfs with the modules (mkinitcpio's modconf hook).
  if pacman -Q nvidia-utils &>/dev/null; then
    echo 'options nvidia NVreg_UsePageAttributeTable=1' | write_file /etc/modprobe.d/80-gaming-nvidia.conf
  fi

  # cachyos-settings hands NetworkManager's DNS to systemd-resolved, which
  # CachyOS runs and this system doesn't: without this, no name resolves.
  # NetworkManager's own, as before (the same file name, in /etc, wins).
  printf '[main]\ndns=default\n' | write_file /etc/NetworkManager/conf.d/dns.conf
}

# ── The desktop ────────────────────────────────────────────────────────

configure_gaming_desktop() {
  # GameMode (gamemoderun %command% in a game's Steam launch options): the
  # CPU at full clocks while the game runs, the game ahead of everything
  # else for the CPU (renice; its group may go to -10) and the disk, and no
  # screen saver. Only with Steam (GAMING_PACKAGES, on a real GPU).
  if pacman -Q gamemode &>/dev/null; then
    sudo usermod -aG gamemode "$USER"
    write_file /etc/gamemode.ini <<'EOF'
[general]
renice=10
ioprio=0
inhibit_screensaver=1
EOF
  fi

  # Fullscreen games may tear when they ask to (vsync off in the game) for
  # the lowest latency; VRR screens stay synced either way.
  kwriteconfig6 --file kwinrc --group Compositing --key AllowTearing true
  # No file indexing: Baloo crawling a Steam library's hundreds of
  # thousands of files is disk and CPU taken from the game.
  kwriteconfig6 --file baloofilerc --group 'Basic Settings' --key Indexing-Enabled false
}
