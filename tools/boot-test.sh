#!/usr/bin/env bash
#
# boot-test.sh — smoke-boot an archcloud ISO under QEMU and verify sshd + installer.
#
#   tools/boot-test.sh -i out/archcloud-generic-*.iso [-u|-b] [--timeout 600] [--keep]
#
#   -u / -b      UEFI (default) or BIOS firmware
#   --timeout    seconds to wait for SSH (default 600; TCG without KVM is slow)
#   --keep       keep the scratch directory (serial log, keys)
#
# A throwaway SSH key is injected through a seed ISO with AUTOINSTALL=no, so the
# installer never runs. Asserts: SSH works, archcloud-install --version answers,
# no failed systemd units, the live pacman keyring knows the CachyOS key,
# archcloud-install --dry-run refuses (no disk) without touching anything.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=qemu-lib.sh
source "$HERE/qemu-lib.sh"

ISO="" FW=uefi TIMEOUT=600 KEEP=0
while (( $# )); do
  case "$1" in
    -i) ISO=$2; shift 2 ;;
    -u) FW=uefi; shift ;;
    -b) FW=bios; shift ;;
    --timeout) TIMEOUT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    *) tdie "unknown option $1" ;;
  esac
done
[[ -f "$ISO" ]] || tdie "ISO not found: $ISO"
command -v "$QEMU_BIN" >/dev/null || tdie "$QEMU_BIN not installed"

# v3/v4 ISOs carry kernels/userland that SIGILL on CPUs without AVX2/AVX-512.
# With KVM the guest sees the host CPU, so skip (not fail) on an unsuitable host.
level=generic
[[ "$(basename "$ISO")" =~ ^archcloud-(generic|v3|v4|znver4)- ]] && level=${BASH_REMATCH[1]}
if [[ -w /dev/kvm ]]; then
  case "$level" in
    v3) grep -qw avx2 /proc/cpuinfo    || { tlog "SKIP: host CPU lacks AVX2, cannot boot a v3 ISO under KVM"; exit 0; } ;;
    znver4) grep -qw avx512_bf16 /proc/cpuinfo || { tlog "SKIP: host CPU lacks AVX-512 BF16 (Zen4-class), cannot boot a znver4 ISO under KVM"; exit 0; } ;;
    v4) grep -qw avx512f /proc/cpuinfo || { tlog "SKIP: host CPU lacks AVX-512, cannot boot a v4 ISO under KVM"; exit 0; } ;;
  esac
fi

scratch=$(mktemp -d)
cleanup() {
  [[ -n "${qemu_pid:-}" ]] && kill "$qemu_pid" 2>/dev/null || true
  if (( KEEP )); then tlog "scratch kept at $scratch"; else rm -rf "$scratch"; fi
}
trap cleanup EXIT

key=$(gen_test_key "$scratch")
"$HERE/make-seed.sh" -o "$scratch/seed.iso" --key "$key.pub" --set AUTOINSTALL=no --hostname smoketest >/dev/null
port=$(free_port)
serial="$scratch/serial-$FW.log"

mapfile -t args < <(qemu_base_args "$FW" "$port" "$serial" "$scratch")
tlog "booting $(basename "$ISO") [$FW] (ssh port $port, serial $serial)"
"$QEMU_BIN" "${args[@]}" \
  -drive "file=${ISO},media=cdrom,readonly=on,if=ide,index=0" \
  -drive "file=${scratch}/seed.iso,media=cdrom,readonly=on,if=ide,index=1" \
  -boot d &
qemu_pid=$!

if ! wait_ssh "$key" "$port" root "$TIMEOUT"; then
  tail -n 40 "$serial" >&2 || true
  tdie "no SSH within ${TIMEOUT}s"
fi
tok "ssh root login with the seed key"

out=$(run_ssh "$key" "$port" root archcloud-install --version)
[[ "$out" == archcloud-install* ]] || tdie "unexpected --version output: $out"
tok "$out"

hn=$(run_ssh "$key" "$port" root uname -n)
[[ "$hn" == smoketest ]] || tdie "seed hostname not applied (got '$hn')"
tok "seed hostname applied"

run_ssh "$key" "$port" root 'systemctl is-system-running --wait >/dev/null; systemctl --failed --no-legend' > "$scratch/failed.txt" || true
if grep -q . "$scratch/failed.txt"; then
  cat "$scratch/failed.txt" >&2
  tdie "failed systemd units in the live environment"
fi
tok "no failed units"

run_ssh "$key" "$port" root 'pacman-key --list-keys 2>/dev/null | grep -q "CachyOS"' || tdie "CachyOS key missing from the live keyring"
tok "live keyring knows the CachyOS key"

run_ssh "$key" "$port" root 'uname -r' | grep -q cachyos || tdie "live kernel is not a CachyOS kernel"
tok "running $(run_ssh "$key" "$port" root uname -r)"

run_ssh "$key" "$port" root 'systemctl is-active archcloud-install.service >/dev/null && tmux -L archcloud has-session -t archcloud' \
  || tdie "installer tmux session not present"
run_ssh "$key" "$port" root 'grep -q "AUTOINSTALL=no" /run/archcloud/install.log' || tdie "installer did not honour AUTOINSTALL=no"
tok "installer service ran and honoured AUTOINSTALL=no"

# no eligible disk: --dry-run must fail cleanly at disk selection
if run_ssh "$key" "$port" root 'archcloud-install --dry-run' >"$scratch/dry.txt" 2>&1; then
  tdie "--dry-run succeeded without a disk?"; fi
grep -q "no eligible target disk" "$scratch/dry.txt" || { cat "$scratch/dry.txt" >&2; tdie "--dry-run failed for an unexpected reason"; }
tok "--dry-run refuses without an eligible disk"

tlog "smoke test passed [$FW]"
