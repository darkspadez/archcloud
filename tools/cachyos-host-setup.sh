#!/usr/bin/env bash
#
# cachyos-host-setup.sh — prepare an Arch Linux build host (or container) so
# that pacstrap/mkarchiso can verify and fetch CachyOS packages.
#
#   * trusts the vendored CachyOS signing key (keys/cachyos-keyring.asc)
#   * installs cachyos-keyring + the three mirrorlists, resolving current
#     filenames from the live cachyos.db (the upstream installer hard-codes
#     versions that 404 once the mirror moves on). CachyOS' patched pacman is
#     not needed: the profile lists package architectures explicitly.
#   * populates the cachyos keyring
#   * detects a broken pacman download sandbox (amd64 emulation on Apple
#     Silicon, some CI sandboxes) and sets DisableSandbox for this host
#
# Idempotent. Run as root. Mirrors the cachyos_repo step of
# arch-server-bootstrap.sh but never touches /etc/pacman.conf repo sections:
# the archcloud profile renders its own pacman.conf.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY_FILE="${REPO_DIR}/keys/cachyos-keyring.asc"
CACHY_FPR="882DCFE48E2051D48E2562ABF3B607488DB35A47"
CACHY_URL="${CACHY_URL:-https://mirror.cachyos.org/repo/x86_64/cachyos}"
NOSANDBOX_MARKER="/run/archcloud-build.nosandbox"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "run as root"
[[ -f /etc/arch-release ]] || die "Arch Linux host required"
[[ -f "$KEY_FILE" ]] || die "missing $KEY_FILE"

# --- pacman download sandbox probe --------------------------------------------
# pacman >= 7 downloads as the unprivileged 'alpm' user inside a seccomp
# sandbox. Under qemu/Rosetta emulation that fails with
# "error restricting syscalls via seccomp". Probe with a real database sync
# (needed anyway), remember the outcome for build.sh.
disable_sandbox() {
  warn "pacman download sandbox unusable here — setting DisableSandbox (build host only)"
  grep -qE '^\s*DisableSandbox\s*$' /etc/pacman.conf || sed -i '/^\[options\]/a DisableSandbox' /etc/pacman.conf
  touch "$NOSANDBOX_MARKER"
}
if [[ "${ARCHCLOUD_DISABLE_SANDBOX:-}" == "1" ]]; then
  disable_sandbox
else
  sync_out=$(pacman -Sy 2>&1) || true
  if [[ "$sync_out" == *"restricting syscalls"* || "$sync_out" == *"sandbox user"* ]]; then
    disable_sandbox
    pacman -Sy >/dev/null
  elif [[ "$sync_out" == *"error:"* ]]; then
    die "pacman -Sy failed: $sync_out"
  else
    log "pacman download sandbox works on this host"
    rm -f "$NOSANDBOX_MARKER"
  fi
fi

# --- keyring init ---------------------------------------------------------------
# The archlinux container images ship a populated keyring without the local
# master secret key, which lsign-key needs. --init is idempotent and creates
# the master key when it is missing.
log "initialising pacman keyring (idempotent)"
pacman-key --init >/dev/null 2>&1
if [[ -f /usr/share/pacman/keyrings/archlinux.gpg ]]; then
  pacman-key --populate archlinux >/dev/null 2>&1
fi

# --- trust the vendored CachyOS key --------------------------------------------
if pacman-key --list-keys "$CACHY_FPR" >/dev/null 2>&1 \
   && pacman-key --list-sigs "$CACHY_FPR" 2>/dev/null | grep -q 'Pacman Keyring Master Key'; then
  log "CachyOS key ${CACHY_FPR: -16} already trusted"
else
  log "adding + locally signing CachyOS key ${CACHY_FPR: -16}"
  pacman-key --add "$KEY_FILE"
  # Refuse to continue if the vendored file does not contain the expected key.
  pacman-key --list-keys "$CACHY_FPR" >/dev/null 2>&1 || die "vendored key file lacks fingerprint $CACHY_FPR"
  pacman-key --lsign-key "$CACHY_FPR"
fi

# --- keyring + mirrorlist + pacman packages ----------------------------------
need_pkgs=()
for p in cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist; do
  pacman -Qq "$p" >/dev/null 2>&1 || need_pkgs+=("$p")
done
if (( ${#need_pkgs[@]} )); then
  log "resolving ${need_pkgs[*]} from $CACHY_URL/cachyos.db"
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL --retry 3 "$CACHY_URL/cachyos.db" -o "$tmp/cachyos.db"
  bsdtar -xOf "$tmp/cachyos.db" --include='*/desc' > "$tmp/desc.txt"
  awk '/^%FILENAME%$/{getline fn} /^%NAME%$/{getline nm; print nm, fn}' "$tmp/desc.txt" > "$tmp/index.txt"
  urls=()
  for p in "${need_pkgs[@]}"; do
    fn=$(awk -v p="$p" '$1==p {print $2; exit}' "$tmp/index.txt")
    [[ -n "$fn" ]] || die "cachyos.db has no entry for '$p'"
    log "  -> $p: $fn"
    urls+=("$CACHY_URL/$fn")
  done
  pacman -U --noconfirm --needed "${urls[@]}"
else
  log "cachyos keyring/mirrorlists already installed"
fi

pacman-key --populate cachyos >/dev/null
log "CachyOS keyring populated; mirrorlists in /etc/pacman.d/cachyos*-mirrorlist"
