#!/usr/bin/env bash
#
# arch-server-bootstrap.sh
# Idempotent provisioning for Arch Linux server deployments (BIOS/GPT, GRUB).
#
# Safe to re-run: each major step records a marker under /var/lib/qops-bootstrap
# on success and is skipped next time. Naturally-idempotent steps re-run harmlessly.
# Optional steps warn-and-continue instead of aborting the whole run.
#
#   - CachyOS repos + mirror ranking + cachyos-settings (system tuning)
#   - CachyOS kernel (linux-cachyos-server), set as default on either
#     systemd-boot or GRUB (auto-detected)
#   - Full system upgrade onto optimized CachyOS packages
#   - Shelly (ALPM package manager)
#   - Docker stack (engine, compose, buildx) with log rotation + live-restore
#   - Reliability: zram swap, systemd-oomd, vm sysctls, systemd-timesyncd
#   - I/O + network: ADIOS I/O scheduler (CachyOS kernel), TCP BBR + fq
#   - Go toolchain
#   - QOL CLI: eza, zoxide, fd, ripgrep, fzf, bat, neovim, zsh, Pure prompt;
#              flow + sshs optional (set INSTALL_FLOW_SSHS=true)
#   - Observability: glances
#   - Snapshots: snapper + snap-pac + grub-btrfs (Btrfs root; self-heals a
#                pre-existing @snapshots subvolume layout, with fstab-safety
#                checks — no separate repair script needed)
#   - Maintenance: informant (Arch news gate), paccache.timer (cache pruning)
#
# Usage:
#   ./arch-server-bootstrap.sh             # normal idempotent run
#   ./arch-server-bootstrap.sh --force     # ignore markers, re-run everything
#   ./arch-server-bootstrap.sh --only snapshots            # run just one step
#   ./arch-server-bootstrap.sh --only zsh_config,ssh_keys  # comma list works
#   ./arch-server-bootstrap.sh --skip flow_sshs            # skip a step this run
#   ./arch-server-bootstrap.sh --groups cachyos,reliability,qol,docker
#       Run only the named groups (+ base, always). --list-groups shows them:
#       hostname user cachyos reliability ext4 adios bbr docker observability
#       qol golang maintenance ssh snapshots
#   ./arch-server-bootstrap.sh --cachyos-only  # alias for --groups cachyos:
#       repos, mirror ranking, package conversion (upgrade), cachyos-settings,
#       kernel, default-kernel, Shelly (+ ananicy if INSTALL_ANANICY=true).
#   ./arch-server-bootstrap.sh --status    # print marker status and exit
#
# Run as root on a fresh (or partially-provisioned) Arch base install.
set -uo pipefail   # NOTE: -e intentionally omitted; we control failure per-step.

#--- tunables -----------------------------------------------------------------
KEEP_STOCK_KERNEL=true   # true = keep stock `linux` as a fallback boot entry

# Bootloader for the kernel-default step. "auto" detects systemd-boot vs GRUB
# (netcup boxes are systemd-boot/UEFI; the BIOS install guide produces GRUB).
# Force with "systemd-boot" or "grub" if detection is ever ambiguous.
BOOTLOADER="auto"

# CachyOS ananicy-cpp auto-nice daemon + CachyOS priority rules. Desktop-
# oriented (interactive responsiveness); off by default for servers.
INSTALL_ANANICY=false

# ADIOS I/O scheduler. CachyOS kernels ship ADIOS compiled in, but default to
# Kyber for NVMe — this installs a udev rule forcing ADIOS on non-rotational
# disks. Requires a CachyOS kernel (plain Arch kernels lack ADIOS).
SET_ADIOS_SCHEDULER=true
# netcup/virtio disks often misreport as rotational; force ADIOS regardless.
ADIOS_FORCE_ON_VIRTIO=true

# TCP BBR congestion control + fq qdisc (better throughput on internet-facing
# links). Applied as sysctls; kernel must provide the tcp_bbr module.
ENABLE_BBR=true

# Install the Go toolchain (pacman 'go' package).
INSTALL_GOLANG=true

# Primary user created at UID 1000. If the user already exists, creation is
# skipped but the key + sudo are still applied.
CREATE_USER="darkspadez"
USER_SHELL=/usr/bin/bash # temporary shell during install; bootstrap switches to zsh

# Hostname for this machine. Leave blank to leave the current hostname unchanged.
# Sets it via hostnamectl and keeps /etc/hosts consistent.
HOSTNAME=""              # e.g. "heimdal"

# Passwordless sudo for the wheel group. true = wheel members run sudo without
# a password prompt (written as a validated drop-in in /etc/sudoers.d/).
# Note: with key-only SSH, this means no password is required at any point.
PASSWORDLESS_SUDO=true

# Public SSH key for the primary user (the full one-liner). Required by default,
# since the script enforces key-only SSH auth.
SSH_PUBKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILMIEKei+ED9h1Azg/bwND6Y2Ah3qVxtX31uG+XH6xow darkspadez@tardis.local"

# Enforce key-only SSH auth. Default true — password auth is disabled once the
# key is installed. Lockout guard refuses to apply if authorized_keys is empty.
REQUIRE_SSH_KEY=true

# --- ext4 tuning (netcup VPS profile) ---
# noatime is the clear win on a server root (kills atime-update writes). Safe.
EXT4_NOATIME=true
# commit=60 batches journal flushes (less I/O on shared VPS storage) at the cost
# of up to 60s data loss on a hard crash. Conservative default: off.
EXT4_COMMIT60=false
# Lower ext4 reserved blocks on the ROOT fs from the ~5% default. Reclaims space
# but keep a cushion since this is root. 0 disables; e.g. 2 sets 2%. Default off.
EXT4_RESERVED_PCT=0

# Install flow (editor) + sshs (SSH TUI) from upstream binaries. These are
# optional extras pulled from the internet; set false to skip them entirely.
INSTALL_FLOW_SSHS=false

#--- state / flags ------------------------------------------------------------
STATE_DIR=/var/lib/qops-bootstrap
FORCE=false
ONLY=""
SKIP=""
GROUPS_ARG=""
declare -a RAN=() SKIPPED=() WARNED=()

# Named groups of steps, selectable with --groups a,b,c. `base` is always
# added in group mode because other steps depend on it (keyring, git, curl, jq).
declare -A GROUP_STEPS=(
  [hostname]="hostname"
  [user]="create_user"
  [cachyos]="cachyos_repo,cachyos_mirrors,upgrade,cachyos_settings,kernel,grub_default,shelly,ananicy"
  [reliability]="reliability,locale_utf8"
  [ext4]="ext4_tuning"
  [adios]="adios"
  [bbr]="bbr"
  [docker]="docker"
  [observability]="glances"
  [qol]="qol_tools,zsh_shell,zsh_config,pure_install,flow_sshs"
  [golang]="golang"
  [maintenance]="maintenance"
  [ssh]="ssh_keys"
  [snapshots]="snapshots"
)
GROUP_ORDER="hostname user cachyos reliability ext4 adios bbr docker observability qol golang maintenance ssh snapshots"

for arg in "$@"; do
  case "$arg" in
    --force)        FORCE=true ;;
    --only|--skip|--groups) ;;  # values consumed below
    --status)       STATUS_ONLY=true ;;
    --cachyos-only) GROUPS_ARG="${GROUPS_ARG:+$GROUPS_ARG,}cachyos" ;;
    --list-groups)  LIST_GROUPS=true ;;
    *) ;;
  esac
done
# Parse --only/--skip/--groups values (simple pairwise scan)
prev=""
for arg in "$@"; do
  [[ "$prev" == "--only"   ]] && ONLY="$arg"
  [[ "$prev" == "--skip"   ]] && SKIP="$arg"
  [[ "$prev" == "--groups" ]] && GROUPS_ARG="${GROUPS_ARG:+$GROUPS_ARG,}$arg"
  prev="$arg"
done

if [[ "${LIST_GROUPS:-false}" == "true" ]]; then
  echo "Available groups (use: --groups a,b,c):"
  for g in $GROUP_ORDER; do printf '  %-14s %s\n' "$g" "${GROUP_STEPS[$g]}"; done
  exit 0
fi

# Expand groups into a step list for --only (merged with any explicit --only).
if [[ -n "$GROUPS_ARG" ]]; then
  expanded="base"
  IFS=',' read -ra _grps <<<"$GROUPS_ARG"
  for g in "${_grps[@]}"; do
    g="${g// /}"; [[ -z "$g" ]] && continue
    if [[ -z "${GROUP_STEPS[$g]:-}" ]]; then
      echo "Unknown group: '$g'. Run --list-groups to see options." >&2; exit 1
    fi
    expanded+=",${GROUP_STEPS[$g]}"
  done
  ONLY="${ONLY:+$ONLY,}$expanded"
fi

#--- helpers ------------------------------------------------------------------
log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==>\033[0m %s\n' "$*" >&2; WARNED+=("$*"); }
die()  { printf '\033[1;31m!!\033[0m %s\n' "$*" >&2; exit 1; }

done_marker() { echo "$STATE_DIR/$1.done"; }
is_done()     { [[ -f "$(done_marker "$1")" ]]; }
mark_done()   { mkdir -p "$STATE_DIR"; date -u +%FT%TZ > "$(done_marker "$1")"; }

# should_run <step>: honor --only/--skip/--force and completion markers.
should_run() {
  local step="$1"
  [[ -n "$ONLY" && ",$ONLY," != *",$step,"* ]] && { SKIPPED+=("$step (not --only target)"); return 1; }
  [[ -n "$SKIP" && ",$SKIP," == *",$step,"* ]] && { SKIPPED+=("$step (--skip)"); return 1; }
  if [[ "$FORCE" != "true" ]] && is_done "$step"; then
    SKIPPED+=("$step (already done)"); return 1
  fi
  return 0
}

# run_step <step> <human label>: prints header; caller does work then mark_done.
begin_step() { log "[$1] $2"; }

# True when the CachyOS repos are active in pacman.conf.
cachyos_ready() { grep -qE '^\[cachyos(-v3|-v4|-znver4|-core|-extra)?' /etc/pacman.conf 2>/dev/null; }

#--- guards -------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root."
[[ -f /etc/arch-release ]] || die "Arch Linux only."
# (No bootloader guard: the kernel-default step auto-detects systemd-boot vs GRUB.)
mkdir -p "$STATE_DIR"

#--- --status short-circuit ---------------------------------------------------
if [[ "${STATUS_ONLY:-false}" == "true" ]]; then
  echo "Bootstrap step status (markers in $STATE_DIR):"
  for s in hostname create_user base cachyos_repo cachyos_mirrors upgrade cachyos_settings kernel shelly ananicy docker reliability locale_utf8 ext4_tuning \
           adios bbr glances qol_tools golang flow_sshs zsh_shell zsh_config pure_install \
           maintenance ssh_keys snapshots grub_default; do
    if is_done "$s"; then printf '  [x] %-16s (%s)\n' "$s" "$(cat "$(done_marker "$s")")"
    else printf '  [ ] %-16s\n' "$s"; fi
  done
  exit 0
fi

#--- informant pre-handling ---------------------------------------------------
# If informant is already installed from a previous run, the very next pacman
# call will block waiting on unread Arch news. Acknowledge it up front so an
# unattended re-run doesn't silently hang.
if command -v informant &>/dev/null; then
  log "informant present — marking Arch news read so pacman won't block"
  informant read </dev/null >/dev/null 2>&1 || warn "informant read returned nonzero (continuing)"
fi

#==============================================================================
# 0a. hostname
#==============================================================================
if should_run hostname; then
  if [[ -z "$HOSTNAME" ]]; then
    log "[hostname] HOSTNAME not set — leaving current hostname ($(hostnamectl --static 2>/dev/null || cat /etc/hostname 2>/dev/null)) unchanged."
    mark_done hostname; SKIPPED+=("hostname (not set)")
  else
    begin_step hostname "Setting hostname to '$HOSTNAME'"
    if hostnamectl set-hostname "$HOSTNAME" 2>/dev/null; then
      log "Hostname set via hostnamectl"
    else
      # Fallback if hostnamectl/dbus isn't available (e.g. minimal chroot-like env)
      echo "$HOSTNAME" > /etc/hostname
      hostname "$HOSTNAME" 2>/dev/null || true
      warn "hostnamectl unavailable — wrote /etc/hostname directly"
    fi

    # Keep /etc/hosts consistent so local name resolution + sudo don't complain
    # about an unresolvable host. Manage a single 127.0.1.1 line idempotently.
    host_line="127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}"
    touch /etc/hosts
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
      sed -i "s|^127\.0\.1\.1[[:space:]].*|$host_line|" /etc/hosts
    else
      printf '%s\n' "$host_line" >> /etc/hosts
    fi
    # Ensure the loopback basics exist too.
    grep -qE '^127\.0\.0\.1[[:space:]]+localhost' /etc/hosts || sed -i '1i 127.0.0.1   localhost' /etc/hosts
    grep -qE '^::1[[:space:]]+localhost'          /etc/hosts || sed -i '1i ::1         localhost' /etc/hosts

    log "Updated /etc/hosts with $HOSTNAME"
    mark_done hostname; RAN+=("hostname")
  fi
fi

#==============================================================================
# 0. primary user creation (UID 1000)
#==============================================================================
if should_run create_user; then
  # Helper: write a validated wheel-sudo drop-in honoring PASSWORDLESS_SUDO.
  configure_wheel_sudo() {
    local sudo_rule sudo_desc tmp_sudo
    if [[ "$PASSWORDLESS_SUDO" == "true" ]]; then
      sudo_rule='%wheel ALL=(ALL:ALL) NOPASSWD: ALL'; sudo_desc='passwordless'
    else
      sudo_rule='%wheel ALL=(ALL:ALL) ALL'; sudo_desc='password-required'
    fi
    tmp_sudo=$(mktemp)
    printf '# Managed by arch-server-bootstrap. %s sudo for wheel.\n%s\n' \
      "$sudo_desc" "$sudo_rule" > "$tmp_sudo"
    # Validate in isolation before installing (never risk locking out sudo).
    if visudo -cf "$tmp_sudo" >/dev/null 2>&1; then
      install -m440 -o root -g root "$tmp_sudo" /etc/sudoers.d/10-qops-wheel
      log "wheel sudo configured: $sudo_desc (/etc/sudoers.d/10-qops-wheel)"
    else
      warn "sudoers drop-in failed validation — NOT installed. Enable %wheel manually."
    fi
    rm -f "$tmp_sudo"
  }

  if [[ -z "$CREATE_USER" ]]; then
    # No username configured — check UID 1000 already exists from install guide.
    existing=$(getent passwd 1000 | cut -d: -f1 || true)
    if [[ -n "$existing" ]]; then
      log "[create_user] CREATE_USER not set — using existing UID-1000 user: $existing"
      # Ensure the existing user is in wheel, then configure sudo.
      id -nG "$existing" 2>/dev/null | grep -qw wheel || usermod -aG wheel "$existing"
      configure_wheel_sudo
      mark_done create_user; RAN+=("create_user")
    else
      die "No UID-1000 user exists and CREATE_USER is not set. Set CREATE_USER in tunables."
    fi
  else
    begin_step create_user "Creating user '$CREATE_USER' (UID 1000)"
    if getent passwd "$CREATE_USER" >/dev/null 2>&1; then
      log "User '$CREATE_USER' already exists — skipping useradd."
      id -nG "$CREATE_USER" 2>/dev/null | grep -qw wheel || usermod -aG wheel "$CREATE_USER"
    else
      useradd -m -u 1000 -G wheel -s "$USER_SHELL" "$CREATE_USER" \
        || die "useradd failed for '$CREATE_USER'"
      log "User '$CREATE_USER' created with home /home/$CREATE_USER."
      # Set a password as a console-login / fallback credential. With key-only
      # SSH and passwordless sudo this won't be used day-to-day, but it's wise
      # to have one for the physical/VM console.
      log "Set a password for '$CREATE_USER' (console/fallback; not used for SSH or sudo):"
      passwd "$CREATE_USER" || warn "passwd returned nonzero — set it manually: passwd $CREATE_USER"
    fi
    configure_wheel_sudo
    mark_done create_user; RAN+=("create_user")
  fi
fi
# Resolve real_user now for all subsequent steps.
real_user=$(getent passwd 1000 | cut -d: -f1 || true)

#==============================================================================
# 1. base prep
#==============================================================================
if should_run base; then
  begin_step base "Refreshing keyring and base tooling"
  pacman -Sy --noconfirm archlinux-keyring || die "keyring refresh failed"
  pacman -S  --noconfirm --needed base-devel git wget curl tar jq || die "base tooling failed"
  mark_done base
  RAN+=("base")
fi

#==============================================================================
# 2. CachyOS repos
#==============================================================================
if should_run cachyos_repo; then
  if cachyos_ready; then
    log "[cachyos_repo] repos already present in pacman.conf"
    mark_done cachyos_repo
  else
    begin_step cachyos_repo "Installing CachyOS repositories"
    # Self-sufficient prerequisites (so --groups cachyos works without base):
    # keyring, curl/tar, gawk (awk -i inplace), libarchive (bsdtar), gcc (ISA probe).
    pacman -Sy --noconfirm archlinux-keyring || warn "keyring refresh failed (continuing)"
    pacman -S --noconfirm --needed curl tar gawk libarchive gcc || warn "could not ensure installer prerequisites"

    # Mirrors the official cachyos-repo.sh, but resolves package filenames from
    # the live repo database. Upstream hardcodes exact versions (e.g.
    # pacman-7.1.0.r9.g54d9411-4) that 404 once the mirror moves on.
    CACHY_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
    repo_ok=false
    for attempt in 1 2 3; do
      tmp=$(mktemp -d)
      # Standalone subshell (not an if-condition) so set -e actually aborts on
      # the first failure instead of being silently ignored.
      (
        set -e
        # 1) Signing key
        pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
        pacman-key --lsign-key F3B607488DB35A47

        # 2) Current filenames for the bootstrap packages, from cachyos.db
        curl -fsSL "$CACHY_URL/cachyos.db" -o "$tmp/cachyos.db"
        bsdtar -xOf "$tmp/cachyos.db" --include='*/desc' > "$tmp/desc.txt"
        awk '/^%FILENAME%$/{getline fn} /^%NAME%$/{getline nm; print nm, fn}' "$tmp/desc.txt" > "$tmp/index.txt"
        urls=()
        for pkg in cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist cachyos-v4-mirrorlist pacman; do
          fn=$(awk -v p="$pkg" '$1==p {print $2; exit}' "$tmp/index.txt")
          [[ -n "$fn" ]] || { echo "cachyos.db has no entry for '$pkg'" >&2; exit 1; }
          echo "  -> $pkg: $fn"
          urls+=("$CACHY_URL/$fn")
        done
        pacman -U --noconfirm "${urls[@]}"

        # 3) Pick the repo level and patch pacman.conf with upstream's awk files.
        curl -fsSL https://mirror.cachyos.org/cachyos-repo.tar.xz -o "$tmp/repo.tar.xz"
        tar xf "$tmp/repo.tar.xz" -C "$tmp"
        awkdir="$tmp/cachyos-repo"
        if gcc -march=native -Q --help=target 2>&1 | grep 'march' | grep -qE '(znver4|znver5)'; then
          awkfile="$awkdir/install-znver4-repo.awk"; level=znver4
        elif /lib/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v4 (supported, searched)'; then
          awkfile="$awkdir/install-v4-repo.awk"; level=v4
        elif /lib/ld-linux-x86-64.so.2 --help | grep -q 'x86-64-v3 (supported, searched)'; then
          awkfile="$awkdir/install-repo.awk"; level=v3
        else
          echo "CPU supports neither x86-64-v3 nor v4; CachyOS optimized repos not applicable" >&2; exit 1
        fi
        echo "  -> CPU level: $level ($(basename "$awkfile"))"
        cp /etc/pacman.conf "$tmp/pacman.conf"
        gawk -i inplace -f "$awkfile" "$tmp/pacman.conf" || true
        grep -q '^\[cachyos' "$tmp/pacman.conf" || { echo "awk produced no [cachyos*] repos" >&2; exit 1; }
        cp -n /etc/pacman.conf /etc/pacman.conf.qops.bak
        install -m644 "$tmp/pacman.conf" /etc/pacman.conf
        pacman -Syy --noconfirm
      ); rc=$?
      [[ $rc -eq 0 ]] && repo_ok=true
      rm -rf "$tmp"
      [[ "$repo_ok" == "true" ]] && cachyos_ready && break
      repo_ok=false
      if [[ $attempt -lt 3 ]]; then
        warn "CachyOS repo install attempt $attempt failed — retrying in 20s"
        sleep 20
      fi
    done
    if [[ "$repo_ok" == "true" ]]; then
      log "CachyOS repos active: $(grep -oE '^\[cachyos[^]]*\]' /etc/pacman.conf | tr '\n' ' ')"
      mark_done cachyos_repo
      RAN+=("cachyos_repo")
    else
      warn "CachyOS repo install failed after 3 attempts. NOT marking done — original config kept at /etc/pacman.conf.qops.bak if it was changed."
    fi
  fi
fi

#==============================================================================
# 2b. CachyOS mirror ranking (faster package downloads)
#==============================================================================
_r=false; should_run cachyos_mirrors && _r=true
if $_r && ! cachyos_ready; then
  warn "[cachyos_mirrors] CachyOS repos not active — skipping mirror ranking (NOT marked done; re-run once repos install)."
elif $_r; then
  begin_step cachyos_mirrors "Ranking CachyOS mirrors by speed"
  # cachyos-rate-mirrors ships with the repo setup; rank both cachyos + Arch.
  if command -v cachyos-rate-mirrors >/dev/null 2>&1; then
    cachyos-rate-mirrors >/dev/null 2>&1 \
      && log "CachyOS mirrors ranked" \
      || warn "cachyos-rate-mirrors returned nonzero (continuing)"
    mark_done cachyos_mirrors; RAN+=("cachyos_mirrors")
  elif pacman -S --noconfirm --needed cachyos-rate-mirrors 2>/dev/null; then
    cachyos-rate-mirrors >/dev/null 2>&1 || warn "cachyos-rate-mirrors returned nonzero"
    mark_done cachyos_mirrors; RAN+=("cachyos_mirrors")
  else
    warn "cachyos-rate-mirrors not available — skipping mirror ranking (non-fatal)."
    mark_done cachyos_mirrors; SKIPPED+=("cachyos_mirrors (tool absent)")
  fi
fi

#==============================================================================
# 3. full upgrade
#==============================================================================
if should_run upgrade; then
  begin_step upgrade "Full system upgrade (pulls optimized CachyOS replacements)"
  if pacman -Syyu --noconfirm; then
    if cachyos_ready; then
      mark_done upgrade
      RAN+=("upgrade")
    else
      # Plain Arch upgrade succeeded, but packages weren't converted to CachyOS
      # builds. Leave unmarked so the next run (with repos active) converts them.
      warn "Upgrade ran without CachyOS repos — NOT marking done so conversion happens on a later run."
    fi
  else
    warn "Full upgrade returned nonzero — resolve manually, then re-run. NOT marking done."
  fi
fi

#==============================================================================
# 3b. CachyOS settings (sysctl/udev/system tuning — the CachyOS "feel")
#==============================================================================
_r=false; should_run cachyos_settings && _r=true
if $_r && ! cachyos_ready; then
  warn "[cachyos_settings] CachyOS repos not active — skipping cachyos-settings (NOT marked done; re-run once repos install)."
elif $_r; then
  begin_step cachyos_settings "Installing cachyos-settings (system tuning)"
  if pacman -S --noconfirm --needed cachyos-settings; then
    log "cachyos-settings installed (kernel sysctls, udev rules, optimizations)"
    mark_done cachyos_settings; RAN+=("cachyos_settings")
  else
    warn "cachyos-settings install failed — kernel works but tuning layer missing."
  fi
fi

#==============================================================================
# 4. CachyOS kernel
#==============================================================================
_r=false; should_run kernel && _r=true
if $_r && ! cachyos_ready; then
  warn "[kernel] CachyOS repos not active — skipping CachyOS kernel (NOT marked done; re-run once repos install)."
elif $_r; then
  begin_step kernel "Installing CachyOS kernel (linux-cachyos-server)"
  if pacman -S --noconfirm --needed linux-cachyos-server linux-cachyos-server-headers; then
    if [[ "$KEEP_STOCK_KERNEL" != "true" ]]; then
      log "Removing stock linux kernel (no fallback entry)"
      pacman -R --noconfirm linux 2>/dev/null || true
    fi
    mark_done kernel
    RAN+=("kernel")
  else
    warn "CachyOS kernel install failed — NOT marking done. Default-kernel step will be skipped."
  fi
fi

#==============================================================================
# 5. Shelly
#==============================================================================
if should_run shelly; then
  begin_step shelly "Installing Shelly (ALPM package manager)"
  if pacman -S --noconfirm --needed shelly; then
    mark_done shelly; RAN+=("shelly")
  else
    warn "Shelly install failed (continuing; not required for the rest)."
  fi
fi

#==============================================================================
# 5b. CachyOS ananicy-cpp (optional; desktop-oriented, off by default)
#==============================================================================
if should_run ananicy; then
  if [[ "$INSTALL_ANANICY" != "true" ]]; then
    log "[ananicy] INSTALL_ANANICY=false — skipping (desktop-oriented)."
    mark_done ananicy; SKIPPED+=("ananicy (disabled)")
  else
    begin_step ananicy "Installing ananicy-cpp + CachyOS rules"
    if pacman -S --noconfirm --needed ananicy-cpp cachyos-ananicy-rules; then
      systemctl enable --now ananicy-cpp.service 2>/dev/null \
        || warn "could not enable ananicy-cpp.service"
      mark_done ananicy; RAN+=("ananicy")
    else
      warn "ananicy install failed (non-fatal)."
    fi
  fi
fi

#==============================================================================
# 6. Docker stack
#==============================================================================
if should_run docker; then
  begin_step docker "Installing Docker, Compose, Buildx + daemon config"
  if pacman -S --noconfirm --needed docker docker-compose docker-buildx; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true
}
JSON
    systemctl enable --now docker.service || warn "could not enable docker.service"
    real_user=$(getent passwd 1000 | cut -d: -f1 || true)
    [[ -n "${real_user:-}" ]] && { usermod -aG docker "$real_user"; log "Added $real_user to docker group"; }
    mark_done docker; RAN+=("docker")
  else
    warn "Docker install failed — NOT marking done."
  fi
fi
# Resolve real_user for later steps even if docker step was skipped.
real_user=$(getent passwd 1000 | cut -d: -f1 || true)

#==============================================================================
# 7. reliability (timesyncd, journald, oomd, zram, sysctls)
#==============================================================================
if should_run reliability; then
  begin_step reliability "Configuring timesyncd, journald, oomd, zram, sysctls"
  systemctl enable --now systemd-timesyncd.service || warn "timesyncd enable failed"

  mkdir -p /etc/systemd/journald.conf.d
  cat > /etc/systemd/journald.conf.d/00-server.conf <<'CONF'
[Journal]
Storage=persistent
SystemMaxUse=500M
CONF
  systemctl restart systemd-journald || warn "journald restart failed"

  systemctl enable --now systemd-oomd.service || warn "oomd enable failed"

  pacman -S --noconfirm --needed zram-generator || warn "zram-generator install failed"
  cat > /etc/systemd/zram-generator.conf <<'CONF'
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
CONF
  systemctl daemon-reload
  systemctl start systemd-zram-setup@zram0.service 2>/dev/null || true

  cat > /etc/sysctl.d/99-server-vm.conf <<'CONF'
vm.swappiness = 100
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
CONF
  sysctl --system >/dev/null || warn "sysctl reload failed"
  mark_done reliability; RAN+=("reliability")
fi

#==============================================================================
# 7b. locale: ensure UTF-8 (prevents prompt width / backspace desync over SSH)
#==============================================================================
if should_run locale_utf8; then
  begin_step locale_utf8 "Ensuring en_US.UTF-8 locale is generated and set"
  if ! locale -a 2>/dev/null | grep -qiE '^en_US\.(utf8|UTF-8)$'; then
    sed -i 's/^#\s*en_US\.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    grep -qE '^en_US\.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen
    locale-gen || warn "locale-gen failed"
  fi
  if [[ -f /etc/locale.conf ]] && grep -q '^LANG=' /etc/locale.conf; then
    sed -i 's/^LANG=.*/LANG=en_US.UTF-8/' /etc/locale.conf
  else
    echo 'LANG=en_US.UTF-8' >> /etc/locale.conf
  fi
  mark_done locale_utf8; RAN+=("locale_utf8")
fi

#==============================================================================
# 7c. ext4 tuning — fstab mount opts + reserved blocks (root fs only)
#==============================================================================
if should_run ext4_tuning; then
  root_src=$(findmnt -no SOURCE / 2>/dev/null)
  root_fstype=$(findmnt -no FSTYPE / 2>/dev/null)
  if [[ "$root_fstype" != "ext4" ]]; then
    log "[ext4_tuning] root fs is '$root_fstype', not ext4 — skipping."
    mark_done ext4_tuning; SKIPPED+=("ext4_tuning (not ext4)")
  else
    begin_step ext4_tuning "Tuning ext4 root ($root_src)"

    # --- build desired mount-option set ---
    # Start from a clean base; we manage atime + commit explicitly.
    want_opts=()
    [[ "$EXT4_NOATIME" == "true" ]] && want_opts+=("noatime")
    [[ "$EXT4_COMMIT60" == "true" ]] && want_opts+=("commit=60")

    if [[ ${#want_opts[@]} -gt 0 ]]; then
      # Identify the root fstab line by its UUID= or PARTUUID= or device source.
      root_uuid=$(findmnt -no UUID / 2>/dev/null)
      # Back up fstab once.
      cp -n /etc/fstab "/etc/fstab.qops.bak" 2>/dev/null && log "Backed up /etc/fstab -> /etc/fstab.qops.bak"

      # Locate the fstab line whose mountpoint (field 2) is exactly "/".
      # We rewrite only field 4 (options), preserving the rest.
      tmp_fstab=$(mktemp)
      awk -v want="$(IFS=,; echo "${want_opts[*]}")" '
        # skip comments/blank unchanged
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
        {
          # fields: 1=spec 2=mount 3=type 4=opts 5=dump 6=pass
          if ($2 == "/") {
            n=split($4, cur, ",")
            # drop relatime/atime/noatime/strictatime and any existing commit=,
            # then we will append the wanted ones.
            out=""
            for (i=1;i<=n;i++) {
              o=cur[i]
              if (o ~ /^(rel|no|strict)?atime$/) continue
              if (o ~ /^commit=/) continue
              out = (out=="" ? o : out","o)
            }
            # append wanted opts
            m=split(want, w, ",")
            for (j=1;j<=m;j++) out = (out=="" ? w[j] : out","w[j])
            $4 = out
            # reprint with single spaces (tabs not required; mount is whitespace-tolerant)
            printf "%s %s %s %s %s %s\n", $1,$2,$3,$4,$5,$6
            next
          }
          print
        }
      ' /etc/fstab > "$tmp_fstab"

      # Validate: the new file must still have a "/" ext4 line with our opts.
      if grep -qE "[[:space:]]/[[:space:]]+ext4[[:space:]]" "$tmp_fstab" \
         && grep -qE "[[:space:]]/[[:space:]]+ext4[[:space:]]+[^[:space:]]*noatime" "$tmp_fstab" 2>/dev/null \
         || { [[ "$EXT4_NOATIME" != "true" ]] && grep -qE "[[:space:]]/[[:space:]]+ext4" "$tmp_fstab"; }; then
        install -m644 "$tmp_fstab" /etc/fstab
        log "Updated root fstab options: $(IFS=,; echo "${want_opts[*]}")"
        # Apply live without reboot (atime/commit can be remounted on the fly).
        if mount -o "remount,$(IFS=,; echo "${want_opts[*]}")" / 2>/dev/null; then
          log "Remounted / live with new options."
        else
          warn "Live remount failed — options will apply on next reboot."
        fi
      else
        warn "Rewritten fstab failed validation — NOT applied. Backup at /etc/fstab.qops.bak."
      fi
      rm -f "$tmp_fstab"
    else
      log "No mount-option changes requested (EXT4_NOATIME/EXT4_COMMIT60 both off)."
    fi

    # --- reserved blocks (root fs) ---
    if [[ "$EXT4_RESERVED_PCT" =~ ^[0-9]+$ ]] && [[ "$EXT4_RESERVED_PCT" -gt 0 ]]; then
      if have_tune2fs=$(command -v tune2fs); then
        tune2fs -m "$EXT4_RESERVED_PCT" "$root_src" >/dev/null 2>&1 \
          && log "Reserved blocks on $root_src set to ${EXT4_RESERVED_PCT}%" \
          || warn "tune2fs -m failed on $root_src"
      else
        warn "tune2fs not found — cannot adjust reserved blocks."
      fi
    fi

    mark_done ext4_tuning; RAN+=("ext4_tuning")
  fi
fi

#==============================================================================
# 7d. ADIOS I/O scheduler (CachyOS kernels; overrides CachyOS's Kyber default)
#==============================================================================
if should_run adios; then
  if [[ "$SET_ADIOS_SCHEDULER" != "true" ]]; then
    log "[adios] SET_ADIOS_SCHEDULER=false — skipping."
    mark_done adios; SKIPPED+=("adios (disabled)")
  else
    begin_step adios "Configuring ADIOS I/O scheduler"

    # 1) udev rule for add/change events. Named 61-* so it sorts after
    #    cachyos-settings' 60-ioschedulers.rules (which picks Kyber) and wins.
    {
      echo '# Managed by arch-server-bootstrap: prefer the ADIOS I/O scheduler.'
      echo 'ACTION=="add|change", KERNEL=="nvme[0-9]*n[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="adios"'
      echo 'ACTION=="add|change", KERNEL=="sd[a-z]*|mmcblk[0-9]*", ENV{DEVTYPE}=="disk", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="adios"'
      if [[ "$ADIOS_FORCE_ON_VIRTIO" == "true" ]]; then
        echo '# virtio disks often report rotational=1 even on flash-backed VPS storage.'
        echo 'ACTION=="add|change", KERNEL=="vd[a-z]*", ENV{DEVTYPE}=="disk", ATTR{queue/scheduler}="adios"'
      fi
    } > /etc/udev/rules.d/61-qops-adios.rules

    # 2) Boot-time re-apply. The CachyOS forum reports the Kyber rule can still
    #    win at early boot; a oneshot after udev settles makes it stick.
    adios_pattern='/sys/block/nvme*n*/queue/scheduler /sys/block/sd*/queue/scheduler /sys/block/mmcblk*/queue/scheduler'
    [[ "$ADIOS_FORCE_ON_VIRTIO" == "true" ]] && adios_pattern+=' /sys/block/vd*/queue/scheduler'
    cat > /etc/systemd/system/qops-adios.service <<UNIT
[Unit]
Description=Apply ADIOS I/O scheduler to block devices (arch-server-bootstrap)
After=systemd-udev-settle.service local-fs.target
Wants=systemd-udev-settle.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'modprobe -q adios 2>/dev/null || modprobe -q adios-iosched 2>/dev/null || true; for f in $adios_pattern; do [ -w "\$\$f" ] && grep -qw adios "\$\$f" && echo adios > "\$\$f"; done; exit 0'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable qops-adios.service >/dev/null 2>&1 || warn "could not enable qops-adios.service"

    # 3) Apply now if the running kernel offers ADIOS (only true once booted
    #    into the CachyOS kernel; plain Arch kernels don't ship it).
    modprobe -q adios 2>/dev/null || modprobe -q adios-iosched 2>/dev/null || true
    if grep -qw adios /sys/block/*/queue/scheduler 2>/dev/null; then
      systemctl start qops-adios.service 2>/dev/null || true
      udevadm control --reload-rules && udevadm trigger --subsystem-match=block --action=change 2>/dev/null || true
      for f in /sys/block/*/queue/scheduler; do
        dev=${f#/sys/block/}; dev=${dev%%/*}
        case "$dev" in loop*|ram*|zram*|sr*) continue ;; esac
        log "  $dev: $(cat "$f")"
      done
    else
      log "Running kernel ($(uname -r)) has no ADIOS — rule + service are in place and"
      log "will take effect after rebooting into linux-cachyos-server."
    fi
    mark_done adios; RAN+=("adios")
  fi
fi

#==============================================================================
# 7e. TCP BBR congestion control + fq qdisc
#==============================================================================
if should_run bbr; then
  if [[ "$ENABLE_BBR" != "true" ]]; then
    log "[bbr] ENABLE_BBR=false — skipping."
    mark_done bbr; SKIPPED+=("bbr (disabled)")
  else
    begin_step bbr "Enabling TCP BBR + fq qdisc"
    modprobe tcp_bbr 2>/dev/null || true
    if ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
      warn "Kernel offers no bbr congestion control ($(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null)) — NOT marking done."
    else
      echo tcp_bbr > /etc/modules-load.d/qops-bbr.conf
      cat > /etc/sysctl.d/99-qops-bbr.conf <<'CONF'
# Managed by arch-server-bootstrap: BBR congestion control paced by fq.
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
CONF
      sysctl -q -p /etc/sysctl.d/99-qops-bbr.conf || warn "sysctl apply returned nonzero"
      cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
      if [[ "$cc" == "bbr" ]]; then
        log "Congestion control: bbr (new connections now; fq applies to interfaces from next boot)"
        mark_done bbr; RAN+=("bbr")
      else
        warn "tcp_congestion_control is '$cc' after apply — NOT marking done."
      fi
    fi
  fi
fi

#==============================================================================
# 8. observability
#==============================================================================
if should_run glances; then
  begin_step glances "Installing glances"
  if pacman -S --noconfirm --needed glances; then mark_done glances; RAN+=("glances")
  else warn "glances install failed"; fi
fi

#==============================================================================
# 9. QOL CLI tools (repos)
#==============================================================================
if should_run qol_tools; then
  begin_step qol_tools "Installing eza, zoxide, fd, ripgrep, fzf, bat, neovim, zsh"
  if pacman -S --noconfirm --needed \
       eza zoxide fd ripgrep fzf bat neovim zsh; then
    mark_done qol_tools; RAN+=("qol_tools")
  else
    warn "Some QOL tools failed to install — NOT marking done."
  fi
fi

#==============================================================================
# 9b. Go toolchain
#==============================================================================
if should_run golang; then
  if [[ "$INSTALL_GOLANG" != "true" ]]; then
    log "[golang] INSTALL_GOLANG=false — skipping."
    mark_done golang; SKIPPED+=("golang (disabled)")
  else
    begin_step golang "Installing Go toolchain"
    if pacman -S --noconfirm --needed go; then
      log "$(go version 2>/dev/null || echo 'go installed')"
      mark_done golang; RAN+=("golang")
    else
      warn "Go install failed — NOT marking done."
    fi
  fi
fi

#==============================================================================
# 10. flow + sshs (PREBUILT BINARIES — avoids broken OCaml AUR build chain)
#==============================================================================
if should_run flow_sshs; then
  if [[ "$INSTALL_FLOW_SSHS" != "true" ]]; then
    log "[flow_sshs] INSTALL_FLOW_SSHS=false — skipping flow + sshs."
    mark_done flow_sshs; SKIPPED+=("flow_sshs (disabled)")
  else
  begin_step flow_sshs "Installing flow + sshs from prebuilt binaries"

  # Ensure jq is present — the flow installer needs it, and base may have been
  # marked done on a prior run before jq was added to the base package set.
  command -v jq &>/dev/null || pacman -S --noconfirm --needed jq \
    || warn "jq install failed — flow installer may not work."

  # --- flow: official installer drops a static binary; pin dest to /usr/local/bin
  if command -v flow &>/dev/null; then
    log "flow already present ($(command -v flow))"
  else
    # Download the installer to a file first, then run it with stdin from
    # /dev/null. Piping `curl | sh` puts the script on sh's stdin, so any
    # prompt the script makes reads from the same pipe and corrupts it
    # (curl error 23). Decoupling avoids that and keeps it non-interactive.
    flow_inst=$(mktemp)
    if curl -fsSL https://flow-control.dev/install -o "$flow_inst" \
       && sh "$flow_inst" --dest /usr/local/bin </dev/null; then
      # Verify it actually runs (the installer needs jq; confirm success).
      if /usr/local/bin/flow --version >/dev/null 2>&1 || command -v flow >/dev/null 2>&1; then
        log "flow installed"
      else
        warn "flow installer ran but binary not found/working — install manually."
      fi
    else
      warn "flow installer failed — ensure jq is installed, or install manually:"
      warn "  curl -fsSL https://flow-control.dev/install -o /tmp/flow-install && sh /tmp/flow-install --dest /usr/local/bin"
    fi
    rm -f "$flow_inst"
  fi

  # --- sshs: GitHub releases ship BARE Linux binaries (no tarball):
  #     sshs-linux-amd64, sshs-linux-amd64-musl, plus .deb/.sha256 variants.
  #     We want the plain glibc binary: sshs-linux-amd64 (musl also works).
  if command -v sshs &>/dev/null; then
    log "sshs already present ($(command -v sshs))"
  else
    sshs_url=$(curl -fsSL https://api.github.com/repos/quantumsheep/sshs/releases/latest 2>/dev/null \
      | grep -oE '"browser_download_url": *"[^"]*sshs-linux-amd64"' \
      | sed -E 's/.*"(https[^"]+)".*/\1/' | head -n1)
    # Fallback to the musl build if the glibc binary isn't found.
    [[ -z "${sshs_url:-}" ]] && sshs_url=$(curl -fsSL https://api.github.com/repos/quantumsheep/sshs/releases/latest 2>/dev/null \
      | grep -oE '"browser_download_url": *"[^"]*sshs-linux-amd64-musl"' \
      | sed -E 's/.*"(https[^"]+)".*/\1/' | head -n1)

    if [[ -n "${sshs_url:-}" ]]; then
      # Asset is a bare executable — download straight to the install path.
      if curl -fsSL "$sshs_url" -o /usr/local/bin/sshs; then
        chmod 755 /usr/local/bin/sshs
        # Sanity-check it actually runs (catches truncated/HTML error downloads).
        if /usr/local/bin/sshs --version >/dev/null 2>&1; then
          log "sshs installed to /usr/local/bin ($(/usr/local/bin/sshs --version 2>/dev/null | head -n1))"
        else
          warn "sshs downloaded but won't execute — removing. Install manually."
          rm -f /usr/local/bin/sshs
        fi
      else
        warn "sshs download failed ($sshs_url) — install manually."
      fi
    else
      warn "Couldn't resolve sshs-linux-amd64 asset — install manually from github.com/quantumsheep/sshs/releases"
    fi
  fi

  # Mark done only if both are now present; otherwise leave unmarked to retry.
  if command -v flow &>/dev/null && command -v sshs &>/dev/null; then
    mark_done flow_sshs; RAN+=("flow_sshs")
  else
    warn "flow and/or sshs not fully installed — NOT marking done (will retry next run)."
  fi
  fi  # end INSTALL_FLOW_SSHS guard
fi

#==============================================================================
# 11. zsh default shell for UID-1000 user
#==============================================================================
if should_run zsh_shell; then
  if [[ -n "${real_user:-}" ]] && command -v zsh &>/dev/null; then
    begin_step zsh_shell "Setting zsh as default shell for $real_user"
    current_shell=$(getent passwd "$real_user" | cut -d: -f7)
    if [[ "$current_shell" == "/usr/bin/zsh" || "$current_shell" == "/bin/zsh" ]]; then
      log "$real_user already uses zsh"
    else
      chsh -s /usr/bin/zsh "$real_user" || warn "chsh failed for $real_user"
    fi
    mark_done zsh_shell; RAN+=("zsh_shell")
  else
    warn "No UID-1000 user or zsh missing — skipping shell change."
  fi
fi

#==============================================================================
# 12. system-wide zsh config
#==============================================================================
if should_run zsh_config; then
  begin_step zsh_config "Writing /etc/zsh/zshrc integrations"
  mkdir -p /etc/zsh
  cat > /etc/zsh/zshrc <<'ZSH'
# Quantum Ops server QOL — modern CLI tools + integrations (zsh, system-wide)

# --- terminfo fallback for new terminals (Ghostty, Kitty, WezTerm) over SSH ---
# If this host has no terminfo entry for the client's TERM, line editing and
# TUIs misbehave (backspace artifacts, broken keys). Fall back to a safe TERM.
if ! infocmp "$TERM" >/dev/null 2>&1; then
  export TERM=xterm-256color
fi

# --- eza (ls replacement) ---
if command -v eza >/dev/null 2>&1; then
  alias ls='eza --group-directories-first --icons=auto'
  alias ll='eza -l --group-directories-first --icons=auto --git'
  alias la='eza -la --group-directories-first --icons=auto --git'
  alias lt='eza --tree --level=2 --icons=auto'
fi

# --- bat (new names; do NOT shadow cat) ---
if command -v bat >/dev/null 2>&1; then
  alias batp='bat'
  alias ccat='bat --paging=never'
  export BAT_THEME='ansi'
  export MANPAGER="sh -c 'col -bx | bat -l man -p'"
  export MANROFFOPT='-c'
fi

# --- ripgrep / fd: native names, no shadowing ---
command -v rg >/dev/null 2>&1 && alias rgi='rg -i'
command -v fd >/dev/null 2>&1 && alias fdh='fd --hidden'

# --- editors ---
if command -v nvim >/dev/null 2>&1; then
  alias vim='nvim'; alias vi='nvim'
  export EDITOR='nvim'; export VISUAL='nvim'
fi
# Flow available as `flow`; uncomment to make it default editor:
# command -v flow >/dev/null 2>&1 && { export EDITOR='flow'; export VISUAL='flow'; }

# --- zoxide: use `z` / `zi`, do NOT alias cd ---
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init zsh)"
fi

# --- fzf keybindings + completion (zsh) ---
[ -f /usr/share/fzf/key-bindings.zsh ] && source /usr/share/fzf/key-bindings.zsh
[ -f /usr/share/fzf/completion.zsh ]   && source /usr/share/fzf/completion.zsh
export FZF_DEFAULT_COMMAND='fd --type f --hidden --exclude .git'
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'

# --- misc QOL ---
alias df='df -h'
alias free='free -h'
alias ip='ip -color=auto'

# --- Go: put `go install`ed binaries on PATH ---
command -v go >/dev/null 2>&1 && path+=("${GOPATH:-$HOME/go}/bin")

# --- Pure prompt (zsh-native, minimal; installed to /usr/share/zsh/pure) ---
if [[ -d /usr/share/zsh/pure ]]; then
  fpath+=(/usr/share/zsh/pure)
  autoload -U promptinit && promptinit
  prompt pure
fi
ZSH
  chmod 644 /etc/zsh/zshrc
  mark_done zsh_config; RAN+=("zsh_config")
fi

#==============================================================================
# 13. Pure prompt install (zsh-native, cloned to /usr/share/zsh/pure)
#==============================================================================
if should_run pure_install; then
  begin_step pure_install "Installing Pure zsh prompt"
  PURE_DIR=/usr/share/zsh/pure
  if [[ -d "$PURE_DIR/.git" ]]; then
    log "Pure already present — updating"
    git -C "$PURE_DIR" pull --quiet || warn "Pure update failed (keeping existing)"
    mark_done pure_install; RAN+=("pure_install")
  else
    mkdir -p /usr/share/zsh
    if git clone --depth=1 https://github.com/sindresorhus/pure.git "$PURE_DIR"; then
      # pure.zsh + async.zsh live at the repo root; promptinit needs prompt_pure_setup.
      if [[ -f "$PURE_DIR/pure.zsh" ]]; then
        log "Pure installed to $PURE_DIR"
        mark_done pure_install; RAN+=("pure_install")
      else
        warn "Pure cloned but pure.zsh missing — check repo layout."
      fi
    else
      warn "Pure clone failed — prompt will fall back to zsh default."
    fi
  fi
fi

#==============================================================================
# 14. maintenance: paccache.timer + informant
#==============================================================================
if should_run maintenance; then
  begin_step maintenance "Installing pacman-contrib (paccache.timer) + informant"
  if pacman -S --noconfirm --needed pacman-contrib; then
    systemctl enable --now paccache.timer || warn "paccache.timer enable failed"
  else
    warn "pacman-contrib install failed"
  fi

  if command -v informant &>/dev/null; then
    log "informant already installed"
  elif pacman -S --noconfirm --needed informant 2>/dev/null; then
    log "informant installed from repos"
  elif command -v shelly &>/dev/null && shelly aur install informant --no-confirm 2>/dev/null; then
    log "informant installed from AUR via Shelly"
  else
    warn "informant not installed (optional) — install later if you want the news gate."
  fi
  mark_done maintenance; RAN+=("maintenance")
fi

#==============================================================================
# 14b. SSH: key-based login for the primary user (optional password lockdown)
#==============================================================================
if should_run ssh_keys; then
  begin_step ssh_keys "Configuring SSH: key install + key-only auth"
  pacman -S --noconfirm --needed openssh || warn "openssh install failed"
  systemctl enable --now sshd || warn "could not enable sshd"

  if [[ -n "${real_user:-}" ]]; then
    user_home=$(getent passwd "$real_user" | cut -d: -f6)

    # --- install the pubkey ---
    if [[ -n "$SSH_PUBKEY" && -n "$user_home" && -d "$user_home" ]]; then
      install -d -m700 -o "$real_user" -g "$real_user" "$user_home/.ssh"
      touch "$user_home/.ssh/authorized_keys"
      grep -qxF "$SSH_PUBKEY" "$user_home/.ssh/authorized_keys" \
        || echo "$SSH_PUBKEY" >> "$user_home/.ssh/authorized_keys"
      chmod 600 "$user_home/.ssh/authorized_keys"
      chown "$real_user":"$real_user" "$user_home/.ssh/authorized_keys"
      log "Public key installed for $real_user"
    else
      if [[ "$REQUIRE_SSH_KEY" == "true" ]]; then
        warn "SSH_PUBKEY is empty but REQUIRE_SSH_KEY=true."
        warn "Set SSH_PUBKEY in tunables, or add your key manually then re-run --only ssh_keys."
        warn "Skipping SSH hardening this run — password auth left as-is."
        mark_done ssh_keys; RAN+=("ssh_keys")
        # Skip to next step without enforcing key-only; key is a prerequisite.
        true
      else
        log "SSH_PUBKEY empty — no key installed. Password auth unchanged."
      fi
    fi

    # --- enforce key-only (default on) ---
    # Only applied when authorized_keys is non-empty, so the lockout guard is
    # structural: you literally cannot disable password auth without a key present.
    if [[ "$REQUIRE_SSH_KEY" == "true" ]] \
       && [[ -s "${user_home}/.ssh/authorized_keys" ]]; then
      grep -q '^Include /etc/ssh/sshd_config.d' /etc/ssh/sshd_config 2>/dev/null \
        || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
      mkdir -p /etc/ssh/sshd_config.d
      cat > /etc/ssh/sshd_config.d/20-qops-keys.conf <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
CONF
      if sshd -t 2>/dev/null; then
        systemctl reload sshd 2>/dev/null || systemctl restart sshd
        log "SSH key-only auth enforced for all users."
        log "IMPORTANT: keep this session open; verify key login from a NEW terminal first."
      else
        warn "sshd -t config test failed — removing drop-in; password auth left enabled."
        rm -f /etc/ssh/sshd_config.d/20-qops-keys.conf
      fi
    fi
  else
    warn "No UID-1000 user — skipping SSH key setup."
  fi
  mark_done ssh_keys; RAN+=("ssh_keys")
fi
#==============================================================================
# 15. snapshots — snapper + snap-pac + grub-btrfs, with self-healing config
#==============================================================================
if should_run snapshots; then
  root_fs=$(findmnt -no FSTYPE /)
  if [[ "$root_fs" != "btrfs" ]]; then
    warn "Root fs is '$root_fs', not btrfs — skipping snapshots (not applicable)."
    mark_done snapshots   # mark so re-runs don't keep checking
  else
    begin_step snapshots "Installing snapper + snap-pac + grub-btrfs (Btrfs root)"
    pacman -S --noconfirm --needed snapper snap-pac grub-btrfs inotify-tools \
      || warn "snapshot package install hit an error (continuing)"

    # --- self-healing snapper 'root' config ---
    if snapper list-configs 2>/dev/null | grep -qw root; then
      log "snapper 'root' config already exists — good."
    else
      log "No 'root' config yet — creating (handling pre-existing @snapshots)."
      # Case A: /.snapshots is a pre-existing mounted subvolume (our install layout).
      if mountpoint -q /.snapshots; then
        # SAFETY: only unmount if fstab can remount it afterward, so we never
        # strand the subvolume. Confirm an fstab entry references /.snapshots.
        fstab_snap=$(grep -E '[[:space:]]/\.snapshots[[:space:]]' /etc/fstab || true)
        if [[ -z "$fstab_snap" ]]; then
          warn "/.snapshots is mounted but has NO /etc/fstab entry — refusing to unmount"
          warn "(can't safely restore it). Inspect: findmnt /.snapshots ; grep snapshots /etc/fstab"
          warn "Skipping snapper config creation this run."
        else
          log "/.snapshots is a mounted subvolume (fstab-backed) — working around create-config."
          umount /.snapshots || warn "could not unmount /.snapshots"
          if [[ -d /.snapshots && -z "$(ls -A /.snapshots 2>/dev/null)" ]]; then
            rmdir /.snapshots || warn "could not rmdir /.snapshots"
          fi
          if snapper -c root create-config /; then
            # snapper made its own .snapshots subvol; delete it, restore ours.
            if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
              btrfs subvolume delete /.snapshots || warn "could not delete snapper's .snapshots subvol"
            fi
            mkdir -p /.snapshots
            if mount /.snapshots; then
              chmod 750 /.snapshots; chown :root /.snapshots
              log "Restored your @snapshots subvolume at /.snapshots"
            else
              warn "Could not remount /.snapshots from fstab — check fstab subvol entry."
            fi
          else
            warn "snapper create-config still failed after unmount — inspect manually."
            # Best-effort: try to put the subvolume back so we don't leave it unmounted.
            mkdir -p /.snapshots && mount /.snapshots 2>/dev/null || true
          fi
        fi
      else
        # Case B: no pre-existing /.snapshots — let snapper do its normal thing.
        if [[ -d /.snapshots ]]; then
          # A bare directory (not a subvolume/mount) also blocks create-config.
          if [[ -z "$(ls -A /.snapshots 2>/dev/null)" ]]; then
            rmdir /.snapshots 2>/dev/null || true
          else
            warn "/.snapshots exists and is non-empty but not mounted — leaving it; create-config may fail."
          fi
        fi
        snapper -c root create-config / || warn "snapper create-config failed — inspect manually."
      fi
    fi

    # --- snapshot config tuning: server stance ---
    if snapper list-configs 2>/dev/null | grep -qw root; then
      # Disable periodic timeline snapshots (desktop-oriented); keep snap-pac.
      systemctl disable --now snapper-timeline.timer 2>/dev/null || true
      systemctl enable  --now snapper-cleanup.timer  2>/dev/null || warn "cleanup.timer enable failed"
      systemctl enable  --now grub-btrfsd.service    2>/dev/null || warn "grub-btrfsd enable failed"
      # Verify with a test snapshot (only if none exist yet).
      if ! snapper -c root list 2>/dev/null | grep -qE '^[[:space:]]*[0-9]+'; then
        snapper -c root create -d "bootstrap verification" 2>/dev/null \
          && log "Test snapshot created OK" \
          || warn "Could not create test snapshot."
      fi
      mark_done snapshots; RAN+=("snapshots")
    else
      warn "snapper 'root' config still missing — NOT marking snapshots done."
    fi
  fi
fi

#==============================================================================
# 16. bootloader: regenerate initramfs + set linux-cachyos-server as default.
#     Auto-detects systemd-boot vs GRUB (BOOTLOADER tunable can force either).
#==============================================================================
if should_run grub_default; then
  begin_step grub_default "Regenerating initramfs + pinning CachyOS kernel default"
  mkinitcpio -P || warn "mkinitcpio reported an error (continuing)"

  # --- detect bootloader ---
  detect_bootloader() {
    case "$BOOTLOADER" in
      systemd-boot|grub) echo "$BOOTLOADER"; return ;;
    esac
    # auto: systemd-boot reports itself via bootctl; confirm it's the live loader.
    if command -v bootctl >/dev/null 2>&1 \
       && bootctl status 2>/dev/null | grep -qiE 'Current Boot Loader:.*systemd-boot'; then
      echo "systemd-boot"; return
    fi
    # Fallback: a populated loader/entries dir + ESP also indicates systemd-boot.
    if [[ -d /boot/loader/entries ]] && compgen -G "/boot/loader/entries/*.conf" >/dev/null; then
      echo "systemd-boot"; return
    fi
    # Otherwise assume GRUB if its config exists.
    if [[ -f /boot/grub/grub.cfg ]] || command -v grub-mkconfig >/dev/null 2>&1; then
      echo "grub"; return
    fi
    echo "unknown"
  }
  bl=$(detect_bootloader)
  log "Bootloader detected: $bl"

  pinned=false

  #--------------------------------------------------------------------------
  if [[ "$bl" == "systemd-boot" ]]; then
  #--------------------------------------------------------------------------
    ENTRY_DIR=/boot/loader/entries
    LOADER_CONF=/boot/loader/loader.conf
    CACHY_ENTRY="cachyos-server.conf"
    cachy_vmlinuz="/vmlinuz-linux-cachyos-server"
    cachy_initrd="/initramfs-linux-cachyos-server.img"

    # Confirm the kernel files actually exist on the ESP/boot.
    if [[ ! -f "/boot${cachy_vmlinuz}" || ! -f "/boot${cachy_initrd}" ]]; then
      warn "CachyOS kernel/initramfs not found in /boot — cannot create entry. NOT marking done."
    else
      # Derive the kernel cmdline (options line) from an EXISTING entry so this
      # works on any box without hardcoding root=PARTUUID. Prefer the stock
      # linux entry; fall back to the first entry that has an options line.
      opts=""
      stock_entry=$(grep -lE '^[[:space:]]*linux[[:space:]]+/vmlinuz-linux([[:space:]]|$)' "$ENTRY_DIR"/*.conf 2>/dev/null | grep -v "$CACHY_ENTRY" | head -n1)
      [[ -z "$stock_entry" ]] && stock_entry=$(grep -lE '^[[:space:]]*options[[:space:]]' "$ENTRY_DIR"/*.conf 2>/dev/null | grep -v "$CACHY_ENTRY" | head -n1)
      [[ -n "$stock_entry" ]] && opts=$(grep -E '^[[:space:]]*options[[:space:]]' "$stock_entry" | head -n1 | sed -E 's/^[[:space:]]*options[[:space:]]+//')

      if [[ -z "$opts" ]]; then
        # Last-resort fallback: build from current /proc/cmdline (strip initrd=).
        opts=$(sed -E 's/initrd=[^ ]+ *//g' /proc/cmdline)
        warn "No existing options line found — derived cmdline from /proc/cmdline."
      fi

      # SAFETY: an empty options line produces an unbootable entry (no root=).
      if [[ -z "${opts// /}" ]] || ! grep -qE 'root=' <<<"$opts"; then
        warn "Refusing to write systemd-boot entry: kernel options empty or missing root=."
        warn "Derived opts: '$opts'. Inspect existing entries in $ENTRY_DIR and set manually."
      else
        log "Using kernel options: $opts"
        cat > "$ENTRY_DIR/$CACHY_ENTRY" <<EOF
# Created by: arch-server-bootstrap
title   Arch Linux (cachyos-server)
linux   $cachy_vmlinuz
initrd  $cachy_initrd
options $opts
EOF
        log "Wrote systemd-boot entry: $ENTRY_DIR/$CACHY_ENTRY"

        # Set it as default in loader.conf (idempotent: replace any default line).
        touch "$LOADER_CONF"
        if grep -qE '^[[:space:]]*default[[:space:]]' "$LOADER_CONF"; then
          sed -i -E "s|^[[:space:]]*default[[:space:]]+.*|default $CACHY_ENTRY|" "$LOADER_CONF"
        else
          sed -i "1i default $CACHY_ENTRY" "$LOADER_CONF"
        fi
        # Ensure a sane timeout so the fallback menu is reachable.
        grep -qE '^[[:space:]]*timeout[[:space:]]' "$LOADER_CONF" || echo 'timeout 3' >> "$LOADER_CONF"

        # Verify: bootctl should list the entry, or loader.conf default is set.
        if bootctl list 2>/dev/null | grep -qi 'cachyos-server'; then
          log "Verified: bootctl sees the cachyos-server entry."
          pinned=true
        elif grep -qE "^[[:space:]]*default[[:space:]]+$CACHY_ENTRY" "$LOADER_CONF"; then
          log "Verified: loader.conf default set to $CACHY_ENTRY."
          pinned=true
        else
          warn "Could not verify systemd-boot default — inspect: bootctl list; cat $LOADER_CONF"
        fi
      fi
    fi

  #--------------------------------------------------------------------------
  elif [[ "$bl" == "grub" ]]; then
  #--------------------------------------------------------------------------
    set_grub() {
      grep -q "^$1=" /etc/default/grub \
        && sed -i "s|^$1=.*|$1=$2|" /etc/default/grub \
        || echo "$1=$2" >> /etc/default/grub
    }
    set_grub GRUB_DEFAULT saved
    set_grub GRUB_SAVEDEFAULT false
    set_grub GRUB_TIMEOUT 3
    set_grub GRUB_TIMEOUT_STYLE menu

    grub-mkconfig -o /boot/grub/grub.cfg || warn "grub-mkconfig reported an error"

    sub_id=$(grep -E "^submenu " /boot/grub/grub.cfg \
             | sed -nE "s/.*\\\$menuentry_id_option '([^']+)'.*/\1/p" | head -n1)
    entry_id=$(grep -E "menuentry " /boot/grub/grub.cfg \
               | grep "linux-cachyos-server" | grep -vi "fallback" \
               | sed -nE "s/.*\\\$menuentry_id_option '([^']+)'.*/\1/p" | head -n1)

    if [[ -n "$entry_id" ]]; then
      if awk '/^submenu /{s=1} /linux-cachyos-server/ && s && !/fallback/{print "nested"; exit} /^}/{s=0}' \
           /boot/grub/grub.cfg | grep -q nested; then
        target="${sub_id}>${entry_id}"
      else
        target="$entry_id"
      fi
      grub-set-default "$target"
      log "Default boot entry pinned to: $target"
      if grep -q "saved_entry=${target}" /boot/grub/grubenv 2>/dev/null; then
        log "Verified saved_entry in grubenv."
        pinned=true
      else
        warn "grubenv saved_entry mismatch — verify: grep saved_entry /boot/grub/grubenv"
      fi
    else
      warn "linux-cachyos-server entry not found in grub.cfg."
      warn "Inspect: grep -E 'menuentry |submenu ' /boot/grub/grub.cfg"
    fi

  #--------------------------------------------------------------------------
  else
  #--------------------------------------------------------------------------
    warn "Bootloader could not be determined (BOOTLOADER=$BOOTLOADER, detect=$bl)."
    warn "Set BOOTLOADER to 'systemd-boot' or 'grub' and re-run --only grub_default."
  fi

  if [[ "$pinned" == "true" ]]; then
    mark_done grub_default; RAN+=("grub_default")
  else
    warn "Kernel default NOT pinned — NOT marking done (will retry next run)."
  fi
fi

#==============================================================================
# summary
#==============================================================================
echo
log "================= RUN SUMMARY ================="
printf '  Ran:     %s\n' "${RAN[*]:-(none)}"
printf '  Skipped: %s\n' "${SKIPPED[*]:-(none)}"
if [[ ${#WARNED[@]} -gt 0 ]]; then
  printf '\033[1;33m  Warnings (%d):\033[0m\n' "${#WARNED[@]}"
  for w in "${WARNED[@]}"; do printf '    - %s\n' "$w"; done
fi
echo
if is_done grub_default; then
  log "Provisioning complete. Reboot to land on linux-cachyos-server automatically."
else
  warn "grub_default not yet complete — kernel default NOT pinned. Re-run after resolving warnings."
fi
log "Re-run anytime; completed steps are skipped. Use --status to inspect, --force to redo all."
