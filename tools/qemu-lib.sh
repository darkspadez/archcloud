# shellcheck shell=bash disable=SC2034
#
# qemu-lib.sh — helpers shared by boot-test.sh and install-test.sh.

QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
QEMU_MEM="${QEMU_MEM:-3072}"
QEMU_SMP="${QEMU_SMP:-2}"

tlog()  { printf '\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
tdie()  { printf '\033[1;31m[%s] FAIL: %s\033[0m\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }
tok()   { printf '\033[1;32m[%s] ok: %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }

find_ovmf_code() {
  local f
  for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd \
           /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2/x64/OVMF_CODE.fd \
           /usr/share/edk2-ovmf/x64/OVMF_CODE.fd /usr/share/qemu/edk2-x86_64-code.fd \
           /opt/homebrew/share/qemu/edk2-x86_64-code.fd /usr/local/share/qemu/edk2-x86_64-code.fd; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}
find_ovmf_vars() {
  local f
  for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd \
           /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2/x64/OVMF_VARS.fd \
           /usr/share/edk2-ovmf/x64/OVMF_VARS.fd /usr/share/qemu/edk2-i386-vars.fd \
           /opt/homebrew/share/qemu/edk2-i386-vars.fd /usr/local/share/qemu/edk2-i386-vars.fd; do
    [[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
  done
  return 1
}

# Common QEMU arguments. $1 = "uefi"|"bios", $2 = ssh host port, $3 = serial log,
# $4 = scratch dir (for OVMF vars copy). Prints the args, one per line.
qemu_base_args() {
  local fw="$1" port="$2" serial="$3" scratch="$4" code vars
  printf '%s\n' -machine q35 -m "$QEMU_MEM" -smp "$QEMU_SMP" \
    -nic "user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:${port}-:22" \
    -display none -serial "file:${serial}" -monitor none \
    -device virtio-rng-pci
  if [[ -w /dev/kvm ]]; then printf '%s\n' -enable-kvm -cpu host
  else printf '%s\n' -cpu max; fi
  if [[ "$fw" == uefi ]]; then
    code=$(find_ovmf_code) || tdie "no OVMF firmware found (install ovmf / edk2-ovmf)"
    vars=$(find_ovmf_vars) || tdie "no OVMF vars template found"
    cp -f "$vars" "$scratch/OVMF_VARS.fd"
    printf '%s\n' -drive "if=pflash,format=raw,readonly=on,file=${code}" \
                  -drive "if=pflash,format=raw,file=${scratch}/OVMF_VARS.fd"
  fi
}

ssh_opts() { # KEY PORT
  printf '%s\n' -i "$1" -p "$2" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 -o LogLevel=ERROR
}

# wait_ssh KEY PORT USER TIMEOUT_SECONDS
wait_ssh() {
  local key="$1" port="$2" user="$3" timeout="$4" start now
  local -a o
  mapfile -t o < <(ssh_opts "$key" "$port")
  start=$(date +%s)
  while :; do
    if ssh "${o[@]}" "${user}@127.0.0.1" true 2>/dev/null; then return 0; fi
    now=$(date +%s)
    (( now - start < timeout )) || return 1
    sleep 5
  done
}

# run_ssh KEY PORT USER CMD...
run_ssh() {
  local key="$1" port="$2" user="$3"; shift 3
  local -a o
  mapfile -t o < <(ssh_opts "$key" "$port")
  ssh "${o[@]}" "${user}@127.0.0.1" "$@"
}

gen_test_key() { # DIR -> prints private key path
  local dir="$1"
  [[ -f "$dir/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C archcloud-test -f "$dir/id_ed25519"
  printf '%s\n' "$dir/id_ed25519"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])' 2>/dev/null || echo 2222
}
