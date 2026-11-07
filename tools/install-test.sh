#!/usr/bin/env bash
#
# install-test.sh — end-to-end: unattended install into a blank disk, then boot
# the result under UEFI and BIOS and assert the installed system.
#
#   tools/install-test.sh -i out/archcloud-generic-*.iso [--disk-size 20G] \
#        [--install-timeout 3600] [--boot-timeout 900] [--finish-timeout 1500] [--keep]
#
# Phase 1: ISO + seed (AUTOINSTALL=yes, HOSTNAME=citest, test key) + blank
#          qcow2, QEMU -no-reboot: the VM exits when the installer reboots.
# Phase 2: boot the disk alone (UEFI, then BIOS), ssh as the configured user,
#          wait for arch-server-bootstrap-finish, assert the end state.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qemu-lib.sh
source "$HERE/qemu-lib.sh"

ISO="" DISK_SIZE=20G INSTALL_TIMEOUT=3600 BOOT_TIMEOUT=900 FINISH_TIMEOUT=1500 KEEP=0
USER_NAME=citest
while (( $# )); do
  case "$1" in
    -i) ISO=$2; shift 2 ;;
    --disk-size) DISK_SIZE=$2; shift 2 ;;
    --install-timeout) INSTALL_TIMEOUT=$2; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT=$2; shift 2 ;;
    --finish-timeout) FINISH_TIMEOUT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) tdie "unknown option $1" ;;
  esac
done
[[ -f "$ISO" ]] || tdie "ISO not found: $ISO"
command -v "$QEMU_BIN" >/dev/null || tdie "$QEMU_BIN not installed"
command -v qemu-img >/dev/null || tdie "qemu-img not installed"

scratch=$(mktemp -d)
cleanup() {
  [[ -n "${qemu_pid:-}" ]] && kill "$qemu_pid" 2>/dev/null || true
  if (( KEEP )); then tlog "scratch kept at $scratch"; else rm -rf "$scratch"; fi
}
trap cleanup EXIT

key=$(gen_test_key "$scratch")
disk="$scratch/disk.qcow2"
qemu-img create -q -f qcow2 "$disk" "$DISK_SIZE"
"$HERE/make-seed.sh" -o "$scratch/seed.iso" --key "$key.pub" --hostname citest \
  --set AUTOINSTALL=yes --set COUNTDOWN=5 --set USER="$USER_NAME" --set TIMEZONE=UTC \
  --set INSTALL_LAZYVIM=true >/dev/null

#--- phase 1: install ------------------------------------------------------------------
port=$(free_port)
serial="$scratch/serial-install.log"
mapfile -t args < <(qemu_base_args uefi "$port" "$serial" "$scratch")
tlog "phase 1: installing from $(basename "$ISO") into $DISK_SIZE disk (serial: $serial)"
"$QEMU_BIN" "${args[@]}" -no-reboot \
  -drive "file=${disk},if=virtio,format=qcow2" \
  -drive "file=${ISO},media=cdrom,readonly=on,if=ide,index=0" \
  -drive "file=${scratch}/seed.iso,media=cdrom,readonly=on,if=ide,index=1" \
  -boot d &
qemu_pid=$!

start=$(date +%s)
while kill -0 "$qemu_pid" 2>/dev/null; do
  (( $(date +%s) - start < INSTALL_TIMEOUT )) || { tail -n 60 "$serial" >&2; tdie "install did not finish within ${INSTALL_TIMEOUT}s"; }
  sleep 10
done
wait "$qemu_pid" || true
unset qemu_pid
# The installer writes ARCHCLOUD_INSTALL_OK/FAILED straight to the kernel console;
# everything else in the serial log goes through tmux and may be garbled.
if grep -aq 'ARCHCLOUD_INSTALL_FAILED' "$serial"; then
  grep -a 'ARCHCLOUD_INSTALL_FAILED' "$serial" >&2; tail -n 80 "$serial" >&2; tdie "installer reported failure"
fi
grep -aq 'ARCHCLOUD_INSTALL_OK' "$serial" || { tail -n 80 "$serial" >&2; tdie "installer did not report success (no ARCHCLOUD_INSTALL_OK on the console)"; }
tok "installer reported success and rebooted (VM exited): $(grep -ao 'ARCHCLOUD_INSTALL_OK.*' "$serial" | head -n1)"

#--- phase 2: boot the installed disk -------------------------------------------------------
assert_installed() { # FW
  local fw="$1" p s
  p=$(free_port); s="$scratch/serial-boot-$fw.log"
  mapfile -t args < <(qemu_base_args "$fw" "$p" "$s" "$scratch")
  tlog "phase 2 [$fw]: booting the installed disk (ssh port $p)"
  "$QEMU_BIN" "${args[@]}" -drive "file=${disk},if=virtio,format=qcow2" &
  qemu_pid=$!
  wait_ssh "$key" "$p" "$USER_NAME" "$BOOT_TIMEOUT" || { tail -n 60 "$s" >&2; tdie "[$fw] no SSH to the installed system"; }
  tok "[$fw] ssh as $USER_NAME with the seed key"

  r() { run_ssh "$key" "$p" "$USER_NAME" "$@"; }

  [[ "$(r uname -n)" == citest ]] || tdie "[$fw] hostname mismatch (got '$(r uname -n)')"
  r 'sudo -n true' || tdie "[$fw] passwordless sudo missing"
  r 'uname -r' | grep -q cachyos || tdie "[$fw] not running a CachyOS kernel: $(r uname -r)"
  tok "[$fw] hostname, sudo, kernel $(r uname -r)"

  for m in / /home /.snapshots /var/log /var/cache/pacman/pkg; do
    [[ "$(r "findmnt -no FSTYPE $m")" == btrfs ]] || tdie "[$fw] $m is not a btrfs mount"
  done
  [[ "$(r 'findmnt -no FSTYPE /boot')" == vfat ]] || tdie "[$fw] /boot is not the FAT ESP"
  tok "[$fw] btrfs subvolumes + ESP mounted"

  r 'sudo test -f /boot/vmlinuz-linux-cachyos-server && sudo test -f /boot/vmlinuz-linux' || tdie "[$fw] kernels missing (cachyos-server + fallback)"
  r 'sudo grep -q "vmlinuz-linux-cachyos-server" /boot/limine/limine.conf && sudo grep -q "vmlinuz-linux$" /boot/limine/limine.conf' || tdie "[$fw] limine.conf lacks the cachyos-server or fallback entry"
  r 'sudo awk "/^\\/Arch Linux/{print; exit}" /boot/limine/limine.conf | grep -q cachyos-server' || tdie "[$fw] the first (default) Limine entry is not cachyos-server"
  r 'sudo test -s /boot/EFI/BOOT/BOOTX64.EFI && sudo test -s /boot/limine/limine-bios.sys' || tdie "[$fw] Limine binaries missing from the ESP"
  tok "[$fw] Limine config + both kernels present"
  r 'sudo snapper --no-dbus -c root create -d citest-snap >/dev/null && sudo /usr/local/sbin/limine-update >/dev/null' || tdie "[$fw] snapshot + limine-update failed"
  r 'sudo grep -q "citest-snap" /boot/limine/limine.conf && sudo grep -q "rootflags=subvol=/@snapshots/" /boot/limine/limine.conf' || tdie "[$fw] no Limine entry for the new snapshot"
  r 'sudo test -s /boot/snapshots/linux-cachyos-server/$(uname -r)/initramfs.img' || tdie "[$fw] kernel not archived for snapshot booting"
  tok "[$fw] snapshot boot entry generated + kernel archived"

  tlog "[$fw] waiting for arch-server-bootstrap-finish (up to ${FINISH_TIMEOUT}s)"
  local t0; t0=$(date +%s)
  until r 'test -e /var/lib/arch-server-bootstrap/.finished' 2>/dev/null; do
    (( $(date +%s) - t0 < FINISH_TIMEOUT )) || { r 'sudo journalctl -u arch-server-bootstrap-finish --no-pager | tail -n 40' >&2 || true; tdie "[$fw] finisher did not complete"; }
    sleep 15
  done
  tok "[$fw] first-boot finisher completed"

  r 'sudo arch-server-bootstrap --status' > "$scratch/status-$fw.txt"
  if grep -q '^\s*\[ \]' "$scratch/status-$fw.txt"; then
    cat "$scratch/status-$fw.txt" >&2; tdie "[$fw] bootstrap steps left undone"
  fi
  tok "[$fw] every bootstrap step marked done"

  for u in sshd docker systemd-networkd systemd-resolved systemd-timesyncd login-status-collect.timer; do
    r "systemctl is-active --quiet $u" || tdie "[$fw] unit $u not active"
  done
  [[ "$(r 'sysctl -n net.ipv4.tcp_congestion_control')" == bbr ]] || tdie "[$fw] BBR not active"
  r 'zramctl --noheadings | grep -q zram0' || tdie "[$fw] zram swap missing"
  r 'sudo snapper --no-dbus list-configs | grep -q root' || tdie "[$fw] snapper root config missing"
  tok "[$fw] services, bbr, zram, snapper"

  [[ "$(r 'zsh -ic "whence -w ls" 2>/dev/null')" == *function* ]] || tdie "[$fw] modern-cli ls wrapper not active"
  r 'test -x /usr/local/bin/login-status && login-status | grep -q Uptime' || tdie "[$fw] login-status broken"
  r 'test -f ~/.config/nvim/lua/config/lazy.lua && test -d ~/.local/share/nvim/lazy/LazyVim' || tdie "[$fw] LazyVim not installed for $USER_NAME"
  r 'sudo test -d /root/.local/share/nvim/lazy/LazyVim' || tdie "[$fw] LazyVim not installed for root"
  r 'sudo passwd -S root | grep -q " L "' || tdie "[$fw] root password not locked"
  r 'sudo test -f /etc/ssh/sshd_config.d/20-keys.conf' || tdie "[$fw] key-only sshd drop-in missing"
  tok "[$fw] shell wrappers, login-status, LazyVim, hardening"

  r 'systemctl --failed --no-legend' > "$scratch/failed-$fw.txt" || true
  if grep -q . "$scratch/failed-$fw.txt"; then cat "$scratch/failed-$fw.txt" >&2; tdie "[$fw] failed units on the installed system"; fi
  tok "[$fw] no failed units"

  kill "$qemu_pid" 2>/dev/null || true; wait "$qemu_pid" 2>/dev/null || true; unset qemu_pid
}

assert_installed uefi
assert_installed bios

#--- phase 3: the ISO must refuse to reinstall over the existing system ---------------------
port=$(free_port); serial="$scratch/serial-guard.log"
mapfile -t args < <(qemu_base_args uefi "$port" "$serial" "$scratch")
tlog "phase 3: booting the ISO again with the installed disk attached"
"$QEMU_BIN" "${args[@]}" \
  -drive "file=${disk},if=virtio,format=qcow2" \
  -drive "file=${ISO},media=cdrom,readonly=on,if=ide,index=0" \
  -drive "file=${scratch}/seed.iso,media=cdrom,readonly=on,if=ide,index=1" \
  -boot d &
qemu_pid=$!
wait_ssh "$key" "$port" root "$BOOT_TIMEOUT" || tdie "guard phase: no SSH to the live ISO"
# the seed says AUTOINSTALL=yes, the guard must still stop it
t0=$(date +%s)
until run_ssh "$key" "$port" root 'grep -q "already holds an archcloud installation" /run/archcloud/install.log' 2>/dev/null; do
  (( $(date +%s) - t0 < 300 )) || { run_ssh "$key" "$port" root 'cat /run/archcloud/install.log' >&2 || true; tdie "re-install guard did not trigger"; }
  sleep 5
done
run_ssh "$key" "$port" root 'blkid -L archcloud >/dev/null' || tdie "guard phase: the installed filesystem vanished"
tok "re-install guard refused to wipe the existing installation"

tlog "end-to-end test passed"
