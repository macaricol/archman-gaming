#!/usr/bin/env bash
# This machine's cooling, from macaricol/cooling_setup: CoolerControl's fan
# curves for every fan, the graphics card's included, and LACT's undervolt
# for the card (its clocks only, as CoolerControl has its fans). For one
# machine only, an MSI MAG B660M MORTAR (MS-7D42) with an RTX 4070 Ti
# SUPER: anywhere else it does nothing.
#
# Run by the desktop phase (lib/gaming.sh's configure_gaming_desktop), as
# the user, in the installer's chroot, after the fan driver and both apps
# are in. On its own: nothing of the installer's, so this folder can go at
# any time, and the install simply carries on without it. Its output goes
# to the install log.
#
# Nothing can run in the chroot, so it only puts the files in place;
# CoolerControl and LACT take them up at the first boot. CoolerControl's
# settings are keyed by IDs it works out from the hardware: should one come
# out different, that device's fans stay as the firmware has them, and
# CoolerControl shows them unassigned.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
board=MS-7D42

if [[ $(cat /sys/class/dmi/id/board_name 2>/dev/null) != *"$board"* ]]; then
  echo "Cooling: not this machine (board $(cat /sys/class/dmi/id/board_name 2>/dev/null || echo unknown)), nothing done"
  exit 0
fi

# The fan driver (lib/gaming.sh), for the motherboard's fans: without it
# CoolerControl only finds the graphics card's.
grep -qx nct6687 /etc/modules-load.d/fans.conf 2>/dev/null \
  || echo "Cooling: warning: the nct6687 fan driver isn't set up, the motherboard's fans won't be found"

# CoolerControl: its files as they were saved, with the list of devices
# emptied, which the service writes again at its start with those it finds.
for file in "$here"/coolercontrol/*; do
  sudo install -Dm644 "$file" "/etc/coolercontrol/${file##*/}"
done
sudo sed -i '/^\[devices\]$/,/^\[/{/^[0-9a-f]\{64\} = /d}' /etc/coolercontrol/config.toml
sudo systemctl enable coolercontrold
echo "Cooling: CoolerControl's settings in place"

# LACT, on a real GPU only (GAMING_PACKAGES). Never with its fan control
# on: two services setting the same fans keep undoing each other.
if pacman -Q lact &>/dev/null; then
  if grep -q 'fan_control_enabled: *true' "$here/lact/config.yaml"; then
    echo "Cooling: warning: LACT's config controls the card's fans, which CoolerControl has: left out"
  else
    sudo install -Dm644 "$here/lact/config.yaml" /etc/lact/config.yaml
    sudo systemctl enable lactd
    echo "Cooling: LACT's settings in place"
  fi
fi
