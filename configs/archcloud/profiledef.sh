#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# archcloud — Arch Linux / CachyOS unattended installer ISO for cloud VMs.
#
# ARCHCLOUD_LEVEL selects the CachyOS repo level the ISO itself is built from
# (generic | v3 | v4). build.sh exports it and renders pacman.conf from
# pacman.conf.in to match. The installer probes the target CPU separately.

iso_name="archcloud-${ARCHCLOUD_LEVEL:-generic}"
iso_label="ARCHCLOUD_$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y%m)"
iso_publisher="archcloud <https://github.com/darkspadez/archcloud>"
iso_application="archcloud Arch/CachyOS cloud installer (${ARCHCLOUD_LEVEL:-generic})"
iso_version="$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)"
install_dir="arch"
bootmodes=('bios.syslinux'
           'uefi.systemd-boot')
pacman_conf="pacman.conf"
airootfs_image_type="squashfs"
airootfs_image_tool_options=('-comp' 'xz' '-Xbcj' 'x86' '-b' '1M' '-Xdict-size' '1M')
bootstrap_tarball_compression=('zstd' '-c' '-T0' '--auto-threads=logical' '--long' '-19')
# Serial first so provider serial consoles get the installer output; tty0 keeps
# the VNC/web console usable. systemd spawns serial-getty@ttyS0 automatically.
kernel_params_x86_64="console=tty0 console=ttyS0,115200n8"
file_permissions=(
  ["/etc/shadow"]="0:0:400"
  ["/root"]="0:0:750"
  ["/root/.automated_script.sh"]="0:0:755"
  ["/etc/ssh/authorized_keys.d"]="0:0:755"
  ["/etc/ssh/authorized_keys.d/root"]="0:0:644"
  ["/usr/local/bin/choose-mirror"]="0:0:755"
  ["/usr/local/bin/archcloud-install"]="0:0:755"
  ["/usr/local/bin/archcloud-seed"]="0:0:755"
  ["/usr/local/lib/archcloud/arch-server-bootstrap.sh"]="0:0:755"
  ["/usr/local/lib/archcloud/templates/login-status"]="0:0:755"
  ["/usr/local/lib/archcloud/templates/login-status-collect"]="0:0:755"
)
