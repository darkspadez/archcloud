#!/usr/bin/env bash
#
# build.sh — build the archcloud ISO(s).
#
#   ./build.sh                      # generic variant
#   ./build.sh --level v3           # one variant: generic | v3 | v4
#   ./build.sh --all                # all three
#   ./build.sh --out out --work work
#
# On a non-Arch host (macOS, Ubuntu, CI runner) the script re-executes itself
# inside a privileged archlinux container (docker or podman). Inside Arch it
# needs root. Steps: tools/cachyos-host-setup.sh, install archiso, render
# configs/archcloud/pacman.conf for the level, run mkarchiso, write sha256sums.
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILE="${REPO_DIR}/configs/archcloud"
OUT_DIR="${REPO_DIR}/out"
WORK_DIR="${REPO_DIR}/work"
LEVELS=()
IMAGE="${ARCHCLOUD_BUILD_IMAGE:-docker.io/library/archlinux:base-devel}"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (( $# )); do
  case "$1" in
    --level)        LEVELS+=("$2"); shift 2 ;;
    --all)          LEVELS=(generic v3 v4); shift ;;
    --out)          OUT_DIR="$2"; shift 2 ;;
    --work)         WORK_DIR="$2"; shift 2 ;;
    --in-container) shift ;;   # marker only; Arch detection below decides
    -h|--help)      usage 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
(( ${#LEVELS[@]} )) || LEVELS=(generic)
for l in "${LEVELS[@]}"; do
  case "$l" in generic|v3|v4) ;; *) die "invalid level '$l' (generic|v3|v4)" ;; esac
done

# --- not on Arch: re-exec in a container ---------------------------------------
if [[ ! -f /etc/arch-release ]]; then
  runtime=$(command -v docker || command -v podman || true)
  [[ -n "$runtime" ]] || die "need Arch Linux, docker or podman"
  log "re-executing inside $IMAGE via $(basename "$runtime")"
  args=(--in-container --out /work/out --work /work/work)
  for l in "${LEVELS[@]}"; do args+=(--level "$l"); done
  # The work dir lives in a named volume: pacstrap sets capability xattrs and
  # device nodes that a macOS/virtiofs bind mount cannot hold.
  exec "$runtime" run --rm --privileged --platform linux/amd64 \
    -v "${REPO_DIR}:/work" -v archcloud-work:/work/work -w /work \
    ${SOURCE_DATE_EPOCH:+-e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH"} \
    -e ARCHCLOUD_DISABLE_SANDBOX="${ARCHCLOUD_DISABLE_SANDBOX:-}" \
    "$IMAGE" bash /work/build.sh "${args[@]}"
fi

[[ $EUID -eq 0 ]] || die "run as root (or from a non-Arch host so it uses a container)"
# mkarchiso derives a build date from SOURCE_DATE_EPOCH only when it is unset.
[[ -n "${SOURCE_DATE_EPOCH:-}" ]] || unset SOURCE_DATE_EPOCH

# --- host preparation ------------------------------------------------------------
"${REPO_DIR}/tools/cachyos-host-setup.sh"
log "installing archiso + build dependencies"
pacman -Syu --noconfirm --needed archiso arch-install-scripts dosfstools e2fsprogs \
  libarchive libisoburn mtools openssl squashfs-tools erofs-utils grub >/dev/null

# --- render pacman.conf for a level ----------------------------------------------
render_pacman_conf() {
  local level="$1" repos="" sandbox="" arch=""
  case "$level" in
    generic)
      arch="x86_64"
      repos=$'[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' ;;
    v3)
      arch="x86_64 x86_64_v3"
      repos=$'[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n'
      repos+=$'[cachyos-core-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n'
      repos+=$'[cachyos-extra-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n'
      repos+=$'[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' ;;
    v4)
      arch="x86_64 x86_64_v3 x86_64_v4"
      repos=$'[cachyos-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n'
      repos+=$'[cachyos-core-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n'
      repos+=$'[cachyos-extra-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n'
      repos+=$'[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' ;;
  esac
  [[ -e /run/archcloud-build.nosandbox ]] && sandbox="DisableSandbox"
  awk -v repos="$repos" -v sandbox="$sandbox" -v arch="$arch" '
    $0 == "@CACHYOS_REPOS@"   { printf "%s", repos; next }
    $0 == "@DISABLE_SANDBOX@" { if (sandbox != "") print sandbox; next }
    { gsub(/@ARCHITECTURE@/, arch); print }' "${PROFILE}/pacman.conf.in" > "${PROFILE}/pacman.conf"
  # The rendered file must parse and must name every repo we expect.
  pacman-conf --config "${PROFILE}/pacman.conf" --repo-list | tr '\n' ' ' | grep -q 'cachyos' \
    || die "rendered pacman.conf lists no cachyos repo"
}

# --- build ---------------------------------------------------------------------------
mkdir -p "$OUT_DIR" "$WORK_DIR"
for level in "${LEVELS[@]}"; do
  log "building archcloud-${level}"
  render_pacman_conf "$level"
  export ARCHCLOUD_LEVEL="$level"
  printf '%s\n' "$level" > "${PROFILE}/airootfs/etc/archcloud/iso-level"
  rm -rf "${WORK_DIR:?}/${level}"
  mkarchiso -v -m iso -w "${WORK_DIR}/${level}" -o "$OUT_DIR" "$PROFILE"
  rm -rf "${WORK_DIR:?}/${level}"
done

cd "$OUT_DIR"
# shellcheck disable=SC2035
sha256sum -- *.iso > sha256sums
{
  for iso in *.iso; do
    printf 'iso_size_bytes{name="%s"} %s\n' "$iso" "$(stat -c %s "$iso")"
  done
} > metrics.txt
log "done:"; ls -la -- *.iso sha256sums
