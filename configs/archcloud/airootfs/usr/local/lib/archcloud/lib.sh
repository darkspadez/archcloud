# shellcheck shell=bash disable=SC2034
#
# lib.sh — shared functions for archcloud-install. Sourced, not executed.
#
# Config precedence (highest first): CLI flags > seed install.conf >
# kernel cmdline archcloud.<key>= > /etc/archcloud/install.conf.

ARCHCLOUD_LIB_DIR=/usr/local/lib/archcloud
ARCHCLOUD_TEMPLATES="$ARCHCLOUD_LIB_DIR/templates"
RUN_DIR=/run/archcloud
LOG_FILE="$RUN_DIR/install.log"
ABORT_FLAG="$RUN_DIR/abort"
TARGET=/mnt
CONF_FILE=/etc/archcloud/install.conf
BTRFS_LABEL=archcloud
ROOT_PARTLABEL=archcloud-root

# Every key the config can carry (upper-case shell names).
CONFIG_KEYS=(HOSTNAME DISK USER SSH_PUBKEY PASSWORD_HASH TIMEZONE LOCALE KEYMAP
             CACHYOS_LEVEL KEEP_STOCK_KERNEL INSTALL_LAZYVIM COUNTDOWN REBOOT
             AUTOINSTALL FORCE)

#--- output ---------------------------------------------------------------------
_ts() { date +%H:%M:%S; }
log()  { printf '\033[1;32m[%s] ==>\033[0m %s\n' "$(_ts)" "$*"; }
info() { printf '\033[1;36m[%s]  ->\033[0m %s\n' "$(_ts)" "$*"; }
warn() { printf '\033[1;33m[%s] WARN\033[0m %s\n' "$(_ts)" "$*" >&2; }
die()  { printf '\033[1;31m[%s] FAIL\033[0m %s\n' "$(_ts)" "$*" >&2; exit 1; }

#--- config --------------------------------------------------------------------
# All settings live in the associative array CFG.
declare -A CFG

cfg_set() { # KEY VALUE  (KEY normalised to upper-case; unknown keys warned)
  local key="${1^^}" val="$2" k
  for k in "${CONFIG_KEYS[@]}"; do
    [[ "$k" == "$key" ]] && { CFG[$key]="$val"; return 0; }
  done
  warn "ignoring unknown setting '$1'"
}

# Load KEY=value assignments from a file into CFG (shell-style quoting).
load_conf_file() {
  local file="$1" line key val
  [[ -r "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val%"${val##*[![:space:]]}"}"
    # strip one layer of matching quotes
    if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
    cfg_set "$key" "$val"
  done < "$file"
}

# archcloud.<key>=<value> on the kernel command line.
load_cmdline() {
  local param key val
  for param in $(</proc/cmdline); do
    [[ "$param" == archcloud.*=* ]] || continue
    key="${param#archcloud.}"; key="${key%%=*}"; val="${param#*=}"
    cfg_set "$key" "$val"
  done
}

load_config() {
  local k
  for k in "${CONFIG_KEYS[@]}"; do CFG[$k]=""; done
  CFG[DISK]=auto; CFG[CACHYOS_LEVEL]=auto; CFG[COUNTDOWN]=30; CFG[REBOOT]=yes
  CFG[AUTOINSTALL]=yes; CFG[KEEP_STOCK_KERNEL]=true; CFG[INSTALL_LAZYVIM]=true
  CFG[TIMEZONE]=UTC; CFG[LOCALE]=en_US.UTF-8; CFG[KEYMAP]=us; CFG[FORCE]=no
  load_conf_file "$CONF_FILE"
  load_cmdline
  if SEED_DIR=$(archcloud-seed mount 2>/dev/null); then
    load_conf_file "$SEED_DIR/install.conf"
    if [[ -f "$SEED_DIR/authorized_keys" ]]; then
      # seed keys are appended to the user's key (multi-line SSH_PUBKEY is fine)
      CFG[SSH_PUBKEY]="${CFG[SSH_PUBKEY]}"$'\n'"$(grep -vE '^\s*(#|$)' "$SEED_DIR/authorized_keys" || true)"
    fi
  else
    SEED_DIR=""
  fi
}

derive_hostname() {
  [[ -n "${CFG[HOSTNAME]}" ]] && return 0
  local id
  id=$(cat /etc/machine-id 2>/dev/null || true)
  [[ ${#id} -ge 4 && "$id" != uninitialized ]] || id=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
  CFG[HOSTNAME]="arch-${id:0:4}"
}

validate_config() {
  [[ "${CFG[HOSTNAME]}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || die "invalid hostname '${CFG[HOSTNAME]}'"
  [[ "${CFG[USER]}" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "invalid user name '${CFG[USER]}'"
  [[ -n "${CFG[SSH_PUBKEY]//[[:space:]]/}" ]] || die "SSH_PUBKEY is empty: the installed system would be unreachable"
  [[ -f "/usr/share/zoneinfo/${CFG[TIMEZONE]}" ]] || die "unknown timezone '${CFG[TIMEZONE]}'"
  case "${CFG[CACHYOS_LEVEL]}" in auto|generic|v3|v4|znver4) ;; *) die "CACHYOS_LEVEL must be auto|generic|v3|v4|znver4" ;; esac
  [[ "${CFG[COUNTDOWN]}" =~ ^[0-9]+$ ]] || die "COUNTDOWN must be a number"
  if [[ -n "${CFG[PASSWORD_HASH]}" && "${CFG[PASSWORD_HASH]}" != \$* ]]; then
    die "PASSWORD_HASH does not look like a crypt(3) hash (expected \$6\$... or \$y\$...)"
  fi
}

#--- environment -----------------------------------------------------------------
firmware() { [[ -d /sys/firmware/efi/efivars ]] && echo UEFI || echo BIOS; }
hypervisor() { systemd-detect-virt --vm 2>/dev/null || echo none; }

wait_for() { # LABEL TRIES SLEEP CMD...
  local label="$1" tries="$2" nap="$3" i; shift 3
  for (( i = 1; i <= tries; i++ )); do
    "$@" >/dev/null 2>&1 && return 0
    (( i == 1 )) && info "waiting for $label"
    sleep "$nap"
  done
  return 1
}

check_network() {
  wait_for "network (archlinux.org)" 20 6 curl -fsSI --max-time 10 https://archlinux.org/ \
    || die "no network: the installer needs the Arch + CachyOS mirrors"
}

check_keyring() {
  wait_for "pacman keyring (pacman-init.service)" 60 2 systemctl is-active --quiet pacman-init.service \
    || die "pacman-init.service did not finish; keyring unusable"
}

#--- disks ----------------------------------------------------------------------
# Block devices that must never be touched: the install medium and the seed.
protected_disks() {
  local src dev
  for src in /run/archiso/bootmnt "$RUN_DIR/seed"; do
    dev=$(findmnt -no SOURCE "$src" 2>/dev/null || true)
    [[ -n "$dev" ]] || continue
    dev=${dev%%\[*}
    lsblk -no PKNAME "$dev" 2>/dev/null | sed 's|^|/dev/|'
    printf '%s\n' "$dev"
  done | sort -u
}

# Candidate target disks: real, writable, non-removable, not protected.
candidate_disks() {
  local name type rm ro size tran prot
  prot=$(protected_disks)
  while read -r name type rm ro size tran; do
    [[ "$type" == disk && "$rm" == 0 && "$ro" == 0 ]] || continue
    case "$name" in /dev/loop*|/dev/zram*|/dev/sr*|/dev/fd*|/dev/ram*) continue ;; esac
    grep -qxF "$name" <<<"$prot" && continue
    printf '%s %s %s\n' "$name" "$size" "${tran:-?}"
  done < <(lsblk -dnpb -o NAME,TYPE,RM,RO,SIZE,TRAN)
}

select_disk() {
  local want="${CFG[DISK]}" cands n
  cands=$(candidate_disks)
  n=$(grep -c . <<<"$cands" || true)
  if [[ "$want" != auto ]]; then
    [[ -b "$want" ]] || die "DISK '$want' is not a block device"
    grep -q "^$want " <<<"$cands" || die "DISK '$want' is not an eligible target (removable, read-only, or the install medium)"
    TARGET_DISK="$want"
  else
    (( n >= 1 )) || die "no eligible target disk found"
    if (( n > 1 )); then
      warn "several eligible disks:"; printf '    %s\n' "${cands//$'\n'/$'\n'    }" >&2
      die "refusing to guess; pass archcloud.disk=/dev/XXX (or DISK= in the seed)"
    fi
    TARGET_DISK=${cands%% *}
  fi
  TARGET_DISK_SIZE=$(lsblk -dno SIZE "$TARGET_DISK")
  (( $(lsblk -dnbo SIZE "$TARGET_DISK") >= 8*1024*1024*1024 )) || die "$TARGET_DISK is smaller than 8 GiB"
}

# Refuse to clobber a previous archcloud install unless FORCE=yes.
guard_existing_install() {
  local hit
  # Two-column queries: an empty LABEL would otherwise shift PARTLABEL into $2.
  hit=$({ lsblk -nrpo NAME,LABEL "$TARGET_DISK" | awk -v l="$BTRFS_LABEL" '$2==l {print $1}'
          lsblk -nrpo NAME,PARTLABEL "$TARGET_DISK" | awk -v p="$ROOT_PARTLABEL" '$2==p {print $1}'; } | head -n1 || true)
  [[ -n "$hit" ]] || return 0
  if [[ "${CFG[FORCE]}" == yes ]]; then
    warn "$TARGET_DISK already holds an archcloud installation ($hit) — FORCE=yes, it will be wiped"
  else
    die "$TARGET_DISK already holds an archcloud installation ($hit). Boot order probably still prefers the ISO: eject it, or pass archcloud.force=yes to reinstall."
  fi
}

part_path() { # DISK N -> partition device path
  local disk="$1" n="$2"
  if [[ "$disk" == *[0-9] ]]; then printf '%sp%s\n' "$disk" "$n"; else printf '%s%s\n' "$disk" "$n"; fi
}

#--- CPU level -------------------------------------------------------------------
probe_cpu_level() {
  if [[ "${CFG[CACHYOS_LEVEL]}" != auto ]]; then CPU_LEVEL="${CFG[CACHYOS_LEVEL]}"; return 0; fi
  local ld=/lib/ld-linux-x86-64.so.2 help
  help=$("$ld" --help 2>/dev/null || true)
  if grep -qE '^vendor_id\s*:\s*AuthenticAMD' /proc/cpuinfo && grep -qw avx512f /proc/cpuinfo \
     && (( $(grep -m1 'cpu family' /proc/cpuinfo | awk '{print $NF}') >= 25 )); then
    CPU_LEVEL=znver4
  elif grep -q 'x86-64-v4 (supported, searched)' <<<"$help"; then CPU_LEVEL=v4
  elif grep -q 'x86-64-v3 (supported, searched)' <<<"$help"; then CPU_LEVEL=v3
  else CPU_LEVEL=generic; fi
}

# Render a pacman.conf for LEVEL to FILE (same shape as CachyOS' installer).
render_pacman_conf() {
  local level="$1" file="$2" arch repos=""
  case "$level" in
    generic) arch="x86_64" ;;
    v3)      arch="x86_64 x86_64_v3"
             repos=$'[cachyos-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n[cachyos-core-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n[cachyos-extra-v3]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n' ;;
    v4)      arch="x86_64 x86_64_v3 x86_64_v4"
             repos=$'[cachyos-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n[cachyos-core-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n[cachyos-extra-v4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n' ;;
    znver4)  arch="x86_64 x86_64_v3 x86_64_v4"
             repos=$'[cachyos-znver4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n[cachyos-core-znver4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n[cachyos-extra-znver4]\nInclude = /etc/pacman.d/cachyos-v4-mirrorlist\n\n' ;;
    *) die "bad level $level" ;;
  esac
  cat > "$file" <<EOF
#
# /etc/pacman.conf — written by archcloud-install (CachyOS level: $level)
#
[options]
HoldPkg     = pacman glibc
Architecture = $arch
ParallelDownloads = 5
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

${repos}[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
}

#--- target package set --------------------------------------------------------------
target_packages() {
  local pkgs=(
    base base-devel linux-cachyos-server linux-cachyos-server-headers linux-firmware
    btrfs-progs grub efibootmgr dosfstools mkinitcpio sudo openssh zsh git curl jq tmux inetutils
    cachyos-settings cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist
    cachyos-rate-mirrors pacman-contrib zram-generator snapper snap-pac grub-btrfs inotify-tools
  )
  [[ "${CFG[KEEP_STOCK_KERNEL]}" == true ]] && pkgs+=(linux)
  if grep -qE '^vendor_id\s*:\s*AuthenticAMD' /proc/cpuinfo; then pkgs+=(amd-ucode)
  elif grep -qE '^vendor_id\s*:\s*GenuineIntel' /proc/cpuinfo; then pkgs+=(intel-ucode); fi
  case "$(hypervisor)" in
    kvm|qemu|bochs) pkgs+=(qemu-guest-agent) ;;
    vmware)         pkgs+=(open-vm-tools) ;;
    microsoft)      pkgs+=(hyperv) ;;
    oracle)         pkgs+=(virtualbox-guest-utils-nox) ;;
  esac
  printf '%s\n' "${pkgs[@]}"
}
