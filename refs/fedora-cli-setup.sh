#!/usr/bin/env bash
# =============================================================================
# fedora-cli-setup.sh  (v4)
# Installs a modern CLI toolkit + LazyVim on Fedora 45 and configures bash
# aliases for root and (if it exists) a deploy user. Adds a status screen on
# interactive login (see the login-status step).
#
# Tools: LazyVim (neovim), eza (exa successor), duf, fzf, jq, yq (mikefarah),
#        doggo, fastfetch, btop, iperf3, nmap, mtr  (+ lazygit, ripgrep, fd)
#
# Usage:
#   sudo ./fedora-cli-setup.sh
#   sudo DEPLOY_USER=deployer ./fedora-cli-setup.sh
#   sudo SKIP_LAZYVIM=1 ./fedora-cli-setup.sh
#   sudo FORCE=1 ./fedora-cli-setup.sh        # re-apply every step
#
# Re-runs: every step is fingerprinted (its code + its data, e.g. package
# lists or the alias file). State lives in /var/lib/fedora-cli-setup/state.
# On re-run a step is applied only if
#   - it has never run,
#   - this version of the script changed it, or
#   - its result has drifted (e.g. a package or alias file was removed).
# Everything else is reported as "up to date" and skipped.
#
# The deploy user is never created. If it doesn't exist it is skipped; once
# it exists, the next run configures it.
# =============================================================================
set -Eeuo pipefail

SCRIPT_VERSION=4
DEPLOY_USER="${DEPLOY_USER:-deploy}"
SKIP_LAZYVIM="${SKIP_LAZYVIM:-0}"
FORCE="${FORCE:-0}"
STATE_DIR=/var/lib/fedora-cli-setup
STATE_FILE="$STATE_DIR/state"
TS="$(date +%Y%m%d-%H%M%S)"

log()  { printf '\e[1;34m==>\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m ok\e[0m %s\n' "$*"; }
skip() { printf '\e[2m  - %s\e[0m\n' "$*"; }
warn() { printf '\e[1;33m !!\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m xx\e[0m %s\n' "$*" >&2; exit 1; }
trap 'die "Failed at line $LINENO: $BASH_COMMAND"' ERR

have() { command -v "$1" >/dev/null 2>&1; }

# >>> state-lib ---------------------------------------------------------------
state_get() { # $1=key -> value (empty if unset)
  [[ -f "$STATE_FILE" ]] || return 0
  awk -v k="$1" '$1 == k { print $2; exit }' "$STATE_FILE"
}

state_set() { # $1=key $2=value
  local tmp
  mkdir -p "$STATE_DIR"
  tmp="$(mktemp "$STATE_DIR/.state.XXXXXX")"
  { [[ -f "$STATE_FILE" ]] && awk -v k="$1" '$1 != k' "$STATE_FILE"
    printf '%s %s\n' "$1" "$2"; } > "$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

fingerprint() { # names of functions/variables -> short sha256 of their definitions
  local n
  for n in "$@"; do
    declare -f "$n" 2>/dev/null || declare -p "$n" 2>/dev/null || printf 'missing:%s\n' "$n"
  done | sha256sum | cut -c1-16
}

# run_step KEY "FINGERPRINT NAMES" CHECK_FN|- STEP_FN [ARGS...]
# CHECK_FN is called with ARGS and must succeed when the step's result is in place.
run_step() {
  local key="$1" names="$2" check="$3"; shift 3
  local want prev reason=""
  # shellcheck disable=SC2086  # names is an intentional word list
  want="$(fingerprint $names)"
  prev="$(state_get "$key")"

  if   [[ "$FORCE" == "1" ]];        then reason="forced"
  elif [[ -z "$prev" ]];             then reason="not applied before"
  elif [[ "$prev" != "$want" ]];     then reason="changed in this version"
  elif [[ "$check" != "-" ]] && ! "$check" "${@:2}"; then reason="drift detected"
  fi

  if [[ -z "$reason" ]]; then
    skip "$key: up to date"
    return 0
  fi
  log "$key: applying ($reason)"
  "$@"
  state_set "$key" "$want"
}
# <<< state-lib ---------------------------------------------------------------

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root: sudo $0"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "fedora" ]] || die "This script targets Fedora (found: ${ID:-unknown})"
[[ "${VERSION_ID:-}" == "45" ]] || warn "Written for Fedora 45, found ${VERSION_ID:-?} — continuing anyway"

case "$(uname -m)" in
  x86_64)  ARCH_GNU="x86_64";  ARCH_GO="amd64" ;;
  aarch64) ARCH_GNU="aarch64"; ARCH_GO="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

# Previous-run detection
PREV_VERSION="$(state_get version)"
if [[ -n "$PREV_VERSION" ]]; then
  log "Previous run detected: v$PREV_VERSION at $(state_get last_run) — applying only what changed"
elif grep -qs 'managed by fedora-cli-setup.sh' /root/.bashrc.d/50-modern-cli.sh; then
  log "Previous run of v1 (no state file) detected — reconciling once, then tracking changes"
else
  log "No previous run detected — full install"
fi
[[ "$FORCE" == "1" ]] && warn "FORCE=1: every step will be re-applied"

# Target users: root always, deploy user only if it already exists
USERS=(root)
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  USERS+=("$DEPLOY_USER")
else
  warn "User '$DEPLOY_USER' does not exist — skipping it (not creating)"
fi

# ----------------------------------------------------------------------------
# Step: packages
# ----------------------------------------------------------------------------
REQUIRED_PKGS=(
  git curl wget tar gzip unzip which findutils util-linux
  gcc make                     # treesitter parser builds
  ripgrep fd-find              # LazyVim pickers / fzf backend
  neovim
  fzf jq duf fastfetch btop iperf3 nmap mtr
  bash-completion
)
OPTIONAL_PKGS=(
  eza yq doggo                 # GitHub-release fallbacks below if absent
  tree-sitter-cli              # newer nvim-treesitter wants this
  python3-neovim nodejs npm    # LSP/mason helpers
  xclip
)

step_packages() {
  dnf -y makecache --refresh >/dev/null
  dnf -y install "${REQUIRED_PKGS[@]}"
  dnf -y install --skip-unavailable "${OPTIONAL_PKGS[@]}" || warn "Some optional packages failed"
}
check_packages() { rpm -q "${REQUIRED_PKGS[@]}" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Step: tools not (reliably) in the Fedora repos — GitHub release fallbacks
# ----------------------------------------------------------------------------
gh_asset_url() { # $1=owner/repo  $2=regex matched against asset download URL
  curl -fsSL -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/releases/latest" |
    jq -r --arg re "$2" \
      'first(.assets[].browser_download_url | select(test($re; "i"))) // empty'
}

install_gh_tarball() { # $1=repo $2=asset regex $3=binary name
  local url tmp bin
  url="$(gh_asset_url "$1" "$2")"
  [[ -n "$url" ]] || { warn "No release asset matching '$2' in $1"; return 1; }
  tmp="$(mktemp -d)"
  curl -fsSL "$url" -o "$tmp/pkg.tar.gz"
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp"
  bin="$(find "$tmp" -type f -name "$3" -print -quit)"
  [[ -n "$bin" ]] || { warn "Binary $3 not found in $url"; rm -rf "$tmp"; return 1; }
  install -m 0755 "$bin" "/usr/local/bin/$3"
  rm -rf "$tmp"
  ok "$3 installed from $1"
}

install_gh_binary() { # $1=repo $2=asset regex $3=binary name
  local url
  url="$(gh_asset_url "$1" "$2")"
  [[ -n "$url" ]] || { warn "No release asset matching '$2' in $1"; return 1; }
  curl -fsSL "$url" -o "/usr/local/bin/$3"
  chmod 0755 "/usr/local/bin/$3"
  ok "$3 installed from $1"
}

yq_is_mikefarah() { have yq && yq --version 2>&1 | grep -qi mikefarah; }

# Asset patterns are anchored on "/<name>" followed directly by an optional
# version and the OS, accepting both "-" and "_" separators
# (doggo-linux-x86_64.tar.gz, lazygit_0.55.1_linux_x86_64.tar.gz), so sibling
# assets like doggo_web_*_linux_amd64.tar.gz or checksums never match.
# A failed fallback only warns: the step's check sees the missing tool and the
# next run retries it, instead of one GitHub hiccup aborting the whole setup.
step_extra_tools() {
  have eza || install_gh_tarball eza-community/eza \
    "/eza_${ARCH_GNU}-unknown-linux-gnu\\.tar\\.gz$" eza ||
    warn "eza install failed — will retry on next run"
  yq_is_mikefarah || install_gh_binary mikefarah/yq "/yq_linux_${ARCH_GO}$" yq ||
    warn "yq install failed — will retry on next run"
  have doggo || install_gh_tarball mr-karan/doggo \
    "/doggo[-_](v?[0-9][0-9.]*[-_])?linux[-_](${ARCH_GNU}|${ARCH_GO})\\.tar\\.gz$" doggo ||
    warn "doggo install failed — will retry on next run"
  have lazygit || install_gh_tarball jesseduffield/lazygit \
    "/lazygit[-_](v?[0-9][0-9.]*[-_])?linux[-_](${ARCH_GNU}|${ARCH_GO})\\.tar\\.gz$" lazygit ||
    warn "lazygit install failed — will retry on next run (LazyVim still works)"
  return 0
}
check_extra_tools() { have eza && have doggo && have lazygit && yq_is_mikefarah; }

# ----------------------------------------------------------------------------
# Step (per user): login shell + aliases in ~/.bashrc.d/50-modern-cli.sh
# ----------------------------------------------------------------------------
write_alias_file() { # $1=path
  cat > "$1" <<'EOF'
# ~/.bashrc.d/50-modern-cli.sh — managed by fedora-cli-setup.sh (rewritten on re-run)
# Bypass any alias with a backslash or `command`, e.g.  \ls   command top
[[ $- == *i* ]] || return 0

export EDITOR=nvim VISUAL=nvim
export MANPAGER='nvim +Man!'

# --- eza (replaces ls / exa / tree) ------------------------------------------
# Icons need a Nerd Font in YOUR terminal; set EZA_ICONS=never to disable.
if command -v eza >/dev/null 2>&1; then
  _eza_icons="--icons=${EZA_ICONS:-auto}"
  alias ls="eza --group-directories-first $_eza_icons"
  alias l="eza -1 --group-directories-first $_eza_icons"
  alias ll="eza -lh --git --group-directories-first $_eza_icons"
  alias la="eza -lah --git --group-directories-first $_eza_icons"
  alias lt="eza --tree --level=2 --group-directories-first $_eza_icons"
  alias tree="eza --tree $_eza_icons"
  alias exa='eza'
  unset _eza_icons
fi

# --- neovim / LazyVim ---------------------------------------------------------
if command -v nvim >/dev/null 2>&1; then
  alias vi='nvim'
  alias vim='nvim'
  alias vimdiff='nvim -d'
fi

# --- disk / system / network --------------------------------------------------
command -v duf       >/dev/null 2>&1 && alias df='duf'
command -v btop      >/dev/null 2>&1 && { alias top='btop'; alias htop='btop'; }
command -v fastfetch >/dev/null 2>&1 && { alias neofetch='fastfetch'; alias screenfetch='fastfetch'; }
command -v doggo     >/dev/null 2>&1 && { alias dig='doggo'; alias nslookup='doggo'; }
command -v mtr       >/dev/null 2>&1 && alias traceroute='mtr --report-wide --report --report-cycles 3'
command -v iperf3    >/dev/null 2>&1 && alias iperf='iperf3'
command -v lazygit   >/dev/null 2>&1 && alias lg='lazygit'

# --- fzf ----------------------------------------------------------------------
if command -v fzf >/dev/null 2>&1; then
  if command -v fd >/dev/null 2>&1; then
    export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
    export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
    export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
  fi
  export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border --info=inline'
  # Ctrl-R history, Ctrl-T files, Alt-C cd, ** completion
  eval "$(fzf --bash 2>/dev/null)" ||
    { [[ -f /usr/share/fzf/shell/key-bindings.bash ]] && . /usr/share/fzf/shell/key-bindings.bash; }
fi

# --- completions --------------------------------------------------------------
command -v yq    >/dev/null 2>&1 && eval "$(yq shell-completion bash 2>/dev/null)"
command -v doggo >/dev/null 2>&1 && eval "$(doggo completions bash 2>/dev/null)"
true
EOF
}

user_home() { getent passwd "$1" | cut -d: -f6; }

step_shell() { # $1=user
  local user="$1" home group rc dir
  home="$(user_home "$user")"
  group="$(id -gn "$user")"
  rc="$home/.bashrc"
  dir="$home/.bashrc.d"

  if [[ "$(getent passwd "$user" | cut -d: -f7)" != "/bin/bash" ]]; then
    log "Setting login shell for $user to /bin/bash"
    usermod -s /bin/bash "$user"
  fi

  [[ -f "$rc" ]] || install -m 0644 -o "$user" -g "$group" /etc/skel/.bashrc "$rc"

  # Fedora's skel .bashrc already sources ~/.bashrc.d; root's may not.
  if ! grep -q '\.bashrc\.d' "$rc"; then
    cat >> "$rc" <<'EOF'

# Source per-tool snippets (added by fedora-cli-setup.sh)
if [ -d ~/.bashrc.d ]; then
  for rc in ~/.bashrc.d/*; do
    [ -f "$rc" ] && . "$rc"
  done
  unset rc
fi
EOF
  fi

  install -d -m 0755 -o "$user" -g "$group" "$dir"
  write_alias_file "$dir/50-modern-cli.sh"
  chown "$user:$group" "$dir/50-modern-cli.sh"
  chmod 0644 "$dir/50-modern-cli.sh"
  ok "Shell config written for $user ($dir/50-modern-cli.sh)"
}

check_shell() { # $1=user
  local home; home="$(user_home "$1")"
  [[ "$(getent passwd "$1" | cut -d: -f7)" == "/bin/bash" ]] &&
    grep -qs 'managed by fedora-cli-setup.sh' "$home/.bashrc.d/50-modern-cli.sh" &&
    grep -qs '\.bashrc\.d' "$home/.bashrc"
}

# ----------------------------------------------------------------------------
# Step (per user): LazyVim
# ----------------------------------------------------------------------------
run_as() { # $1=user $2=home  rest=command
  local user="$1" home="$2"; shift 2
  (cd "$home" && runuser -u "$user" -- env HOME="$home" USER="$user" "$@")
}

step_lazyvim() { # $1=user
  local user="$1" home cfg d
  home="$(user_home "$user")"
  cfg="$home/.config/nvim"

  if grep -qs 'LazyVim/LazyVim' "$cfg/lua/config/lazy.lua"; then
    ok "LazyVim already configured for $user — leaving config alone"
  else
    if [[ -e "$cfg" ]]; then
      log "Backing up existing nvim config for $user (suffix .bak.$TS)"
      for d in "$cfg" "$home/.local/share/nvim" "$home/.local/state/nvim" "$home/.cache/nvim"; do
        [[ -e "$d" ]] && mv "$d" "$d.bak.$TS"
      done
    fi
    log "Installing LazyVim starter for $user"
    run_as "$user" "$home" mkdir -p "$home/.config"
    run_as "$user" "$home" git clone --quiet --depth 1 https://github.com/LazyVim/starter "$cfg"
    rm -rf "$cfg/.git"
  fi

  log "Syncing LazyVim plugins for $user (headless, may take a minute)"
  if run_as "$user" "$home" nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then
    ok "LazyVim ready for $user"
  else
    warn "Headless plugin sync for $user reported errors — they'll finish on first launch of nvim"
  fi
}

check_lazyvim() { # $1=user
  local home; home="$(user_home "$1")"
  grep -qs 'LazyVim/LazyVim' "$home/.config/nvim/lua/config/lazy.lua" &&
    [[ -d "$home/.local/share/nvim/lazy/LazyVim" ]]
}

# ----------------------------------------------------------------------------
# Step: login status screen (shown on interactive login, e.g. SSH)
#   /usr/local/bin/login-status            renderer (fast, runs as the user)
#   /usr/local/libexec/login-status-collect root collector -> cache, every 5 min
#   /etc/login-status.conf                 optional settings (never overwritten)
#   /etc/profile.d/zz-login-status.sh      login hook (skip with ~/.hushlogin)
# ----------------------------------------------------------------------------
write_login_status_renderer() {
  cat > /usr/local/bin/login-status <<'EOF_RENDER'
#!/usr/bin/env bash
# login-status — managed by fedora-cli-setup.sh (rewritten on re-run)
# Live: uptime, memory, disk, network, failed units, reboot-needed.
# Cached (root collector, every 5 min): updates, containers, backup, crowdsec, ssh, netbird.
CACHE=/var/cache/login-status/status.env
CONF=/etc/login-status.conf
HIDE=""
# shellcheck disable=SC1090
[[ -r $CONF ]] && . "$CONF"
# shellcheck disable=SC1090
[[ -r $CACHE ]] && . "$CACHE"

if [[ -t 1 ]]; then
  B=$'\e[1m' D=$'\e[2m' C=$'\e[36m' G=$'\e[32m' Y=$'\e[33m' R=$'\e[31m' N=$'\e[0m'
else
  B='' D='' C='' G='' Y='' R='' N=''
fi

hidden() { [[ " ${HIDE,,} " == *" ${1,,} "* ]]; }
row()    { hidden "$1" || printf ' %s%-9s%s %s\n' "$C" "$1" "$N" "$2"; }
commas() { sed ':a;s/\B[0-9]\{3\}\>/,&/;ta' <<<"$1"; }
ago() {
  local s=$(( $(date +%s) - $1 ))
  if   (( s < 90 ));     then echo "just now"
  elif (( s < 5400 ));   then echo "$(( s / 60 ))m ago"
  elif (( s < 172800 )); then echo "$(( s / 3600 ))h ago"
  else                        echo "$(( s / 86400 ))d ago"; fi
}

# --- header -------------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
printf '\n %s%s%s %s·%s %s %s·%s %s %s· as of %s%s\n' \
  "$B" "$(hostname -s)" "$N" "$D" "$N" "${NAME:-Linux} ${VERSION_ID:-}" \
  "$D" "$N" "$(uname -r)" "$D" "$(date +%H:%M)" "$N"

# --- uptime / load --------------------------------------------------------------
cpus=$(nproc)
read -r l1 l5 l15 _ < /proc/loadavg
lc=$N; awk -v l="$l1" -v c="$cpus" 'BEGIN{exit !(l>c)}' && lc=$Y
row Uptime "$(uptime -p | sed 's/^up //')   ${D}load${N} ${lc}${l1}${N} $l5 $l15 ${D}(${cpus} cpu)${N}"

# --- memory -----------------------------------------------------------------------
read -r mt mu < <(free -h | awk '/^Mem:/{print $2, $3}')
read -r st su < <(free -h | awk '/^Swap:/{print $2, $3}')
if [[ -z $st || $st == 0B ]]; then swap="${D}swap${N} none"; else swap="${D}swap${N} $su / $st"; fi
row Memory "$mu / $mt   $swap"

# --- disk -----------------------------------------------------------------------
read -r du ds dp < <(df -h --output=used,size,pcent / | tail -n1)
p=${dp%\%}; dc=$D; (( p >= 80 )) && dc=$Y; (( p >= 90 )) && dc=$R
row Disk "$du / $ds ${dc}(${dp})${N}"

# --- network ----------------------------------------------------------------------
v4=$(ip -o -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+')
v6=$(ip -o -6 route get 2606:4700:4700::1111 2>/dev/null | grep -oP 'src \K\S+')
row Network "${v4:-${D}no ipv4${N}}${v6:+   $v6}"

# --- updates + reboot -------------------------------------------------------------
running=$(uname -r)
newest=$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core 2>/dev/null | sort -V | tail -n1)
reboot=""; [[ -n $newest && $newest != "$running" ]] && reboot="   ${R}reboot needed${N} ${D}(kernel updated)${N}"
if [[ -n ${UPD_TS:-} ]]; then
  if (( UPD_COUNT == 0 )); then u="${G}up to date${N}"
  else u="${Y}${UPD_COUNT} pending${N} ${D}(dnf upgrade)${N}"; fi
  row Updates "$u ${D}checked $(ago "$UPD_TS")${N}$reboot"
else
  row Updates "${D}not checked yet${N}$reboot"
fi

# --- systemd ------------------------------------------------------------------------
mapfile -t failed < <(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}')
if (( ${#failed[@]} == 0 )); then row Services "${G}all running${N}"
else row Services "${R}${#failed[@]} failed${N} ${D}${failed[*]}${N}"; fi

# --- containers -------------------------------------------------------------------
if [[ -n ${CTR_ENGINE:-} ]]; then
  label=${CTR_ENGINE^}
  if [[ -n ${CTR_ERR:-} ]]; then row "$label" "${R}not responding${N}"
  elif (( CTR_UNHEALTHY > 0 )); then row "$label" "$CTR_RUNNING running ${R}${CTR_UNHEALTHY} unhealthy${N}"
  else row "$label" "$CTR_RUNNING running ${G}all healthy${N}"; fi
fi

# --- backup (BACKUP_CHECK_CMD in /etc/login-status.conf) --------------------------
if [[ -n ${BACKUP_TS:-} ]]; then
  if (( BACKUP_RC == 0 )); then bc=$G; else bc=$R; fi
  row Backup "${bc}${BACKUP_LINE:-?}${N} ${D}checked $(ago "$BACKUP_TS")${N}"
fi

# --- crowdsec -----------------------------------------------------------------------
if [[ -n ${CS_BANNED:-} ]]; then
  case ${CS_FW:-} in
    active) fw="${G}firewall on${N}" ;; absent) fw="${D}no bouncer${N}" ;; *) fw="${R}firewall off${N}" ;;
  esac
  row CrowdSec "$CS_BANNED banned ${D}·${N} $(commas "$CS_BLOCKLIST") blocklisted   $fw"
fi

# --- ssh ------------------------------------------------------------------------------
if [[ -n ${SSH_FAILS:-} ]]; then
  if (( SSH_FAILS == 0 )); then row SSH "${G}no failed logins${N} ${D}(24h)${N}"
  else row SSH "$(commas "$SSH_FAILS") failed logins from $(commas "$SSH_IPS") IPs ${D}(24h)${N}"; fi
fi

# --- netbird ----------------------------------------------------------------------------
if [[ -n ${NB_TOTAL:-} ]]; then
  if [[ ${NB_MGMT:-true} != true ]]; then nb=" ${R}management disconnected${N}"; else nb=""; fi
  row NetBird "${NB_CONNECTED}/${NB_TOTAL} peers connected$nb"
fi

# --- stale cache warning ------------------------------------------------------------
if [[ -n ${COLLECTED_TS:-} ]] && (( $(date +%s) - COLLECTED_TS > 1800 )); then
  printf ' %scached status is %s — check login-status-collect.timer%s\n' "$Y" "$(ago "$COLLECTED_TS")" "$N"
fi
echo
EOF_RENDER
  chmod 0755 /usr/local/bin/login-status
}

write_login_status_collector() {
  install -d -m 0755 /usr/local/libexec
  cat > /usr/local/libexec/login-status-collect <<'EOF_COLLECT'
#!/usr/bin/env bash
# login-status-collect — managed by fedora-cli-setup.sh (rewritten on re-run)
# Runs as root from login-status-collect.timer; writes /var/cache/login-status/status.env
# Usage: login-status-collect [--updates]   (--updates forces a dnf check now)
set -uo pipefail
CACHE_DIR=/var/cache/login-status
OUT=$CACHE_DIR/status.env
CONF=/etc/login-status.conf
UPDATE_INTERVAL=14400   # seconds between dnf checks (rpmdb changes also trigger one)
BACKUP_CHECK_CMD=""
# shellcheck disable=SC1090
[[ -r $CONF ]] && . "$CONF"

have() { command -v "$1" >/dev/null 2>&1; }
mkdir -p "$CACHE_DIR"
now=$(date +%s)

# keep previous update results unless it's time to refresh
UPD_COUNT="" UPD_TS=""
[[ -r $OUT ]] && eval "$(grep -E '^UPD_(COUNT|TS)=' "$OUT")"

lines=()
emit() { lines+=("$(printf '%s=%q' "$1" "$2")"); }

# --- dnf updates ----------------------------------------------------------------
rpmdb_mtime=$(stat -c %Y /var/lib/rpm/rpmdb.sqlite 2>/dev/null || echo 0)
if [[ ${1:-} == --updates || -z $UPD_TS ]] ||
   (( now - UPD_TS >= UPDATE_INTERVAL || rpmdb_mtime > UPD_TS )); then
  out=$(timeout 300 dnf -q check-upgrade --refresh 2>/dev/null); rc=$?
  if (( rc == 0 || rc == 100 )); then
    UPD_COUNT=$(awk 'NF >= 3 && $1 ~ /\./ && $1 !~ /:$/' <<<"$out" | grep -c .)
    UPD_TS=$now
  fi
fi
[[ -n $UPD_TS ]] && { emit UPD_COUNT "$UPD_COUNT"; emit UPD_TS "$UPD_TS"; }

# --- containers (docker first, then podman) ---------------------------------------
for eng in docker podman; do
  have "$eng" || continue
  emit CTR_ENGINE "$eng"
  if st=$(timeout 15 "$eng" ps --format '{{.Status}}' 2>/dev/null); then
    emit CTR_RUNNING "$(grep -c . <<<"$st")"
    emit CTR_UNHEALTHY "$(grep -c '(unhealthy)' <<<"$st")"
  else
    emit CTR_ERR 1
  fi
  break
done

# --- backup (user-defined check; first line of output + exit code) ----------------
if [[ -n $BACKUP_CHECK_CMD ]]; then
  bout=$(timeout 120 bash -c "$BACKUP_CHECK_CMD" 2>&1); brc=$?
  emit BACKUP_LINE "${bout%%$'\n'*}"; emit BACKUP_RC "$brc"; emit BACKUP_TS "$now"
fi

# --- crowdsec -----------------------------------------------------------------------
if have cscli; then
  j=$(timeout 60 cscli decisions list --all --limit 0 -o json 2>/dev/null ||
      timeout 60 cscli decisions list --all -o json 2>/dev/null)
  [[ -z $j || $j == null ]] && j='[]'
  emit CS_BANNED "$(jq '[.[]?.decisions[]? | select(.origin == "crowdsec" or .origin == "cscli")] | length' <<<"$j" 2>/dev/null || echo 0)"
  emit CS_BLOCKLIST "$(jq '[.[]?.decisions[]? | select(.origin == "CAPI" or .origin == "lists")] | length' <<<"$j" 2>/dev/null || echo 0)"
  if systemctl list-unit-files 'crowdsec-firewall-bouncer*' --no-legend 2>/dev/null | grep -q .; then
    if systemctl is-active --quiet 'crowdsec-firewall-bouncer*'; then emit CS_FW active; else emit CS_FW inactive; fi
  else
    emit CS_FW absent
  fi
fi

# --- ssh failed logins (24h) ----------------------------------------------------------
slog=$(timeout 60 journalctl --since "24 hours ago" -o cat -t sshd -t sshd-session 2>/dev/null |
       grep -E 'Failed (password|publickey|none|keyboard-interactive)|Invalid user' |
       grep -v 'Failed .* for invalid user')
emit SSH_FAILS "$(grep -c . <<<"$slog")"
emit SSH_IPS "$(grep -oE 'from [0-9a-fA-F:.]+' <<<"$slog" | sort -u | grep -c .)"

# --- netbird ----------------------------------------------------------------------------
if have netbird && nj=$(timeout 15 netbird status --json 2>/dev/null); then
  emit NB_CONNECTED "$(jq -r '.peers.connected // 0' <<<"$nj")"
  emit NB_TOTAL "$(jq -r '.peers.total // 0' <<<"$nj")"
  emit NB_MGMT "$(jq -r '.management.connected // true' <<<"$nj")"
fi

emit COLLECTED_TS "$now"
tmp=$(mktemp "$CACHE_DIR/.status.XXXXXX")
printf '%s\n' "${lines[@]}" > "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" "$OUT"
EOF_COLLECT
  chmod 0755 /usr/local/libexec/login-status-collect
}

write_login_status_units() {
  cat > /etc/systemd/system/login-status-collect.service <<'EOF_SVC'
# managed by fedora-cli-setup.sh
[Unit]
Description=Collect cached data for the login status screen
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/login-status-collect
Nice=10
IOSchedulingClass=idle
EOF_SVC

  cat > /etc/systemd/system/login-status-collect.timer <<'EOF_TIMER'
# managed by fedora-cli-setup.sh
[Unit]
Description=Refresh login status cache every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
RandomizedDelaySec=30s

[Install]
WantedBy=timers.target
EOF_TIMER
}

write_login_status_hook() {
  cat > /etc/profile.d/zz-login-status.sh <<'EOF_HOOK'
# managed by fedora-cli-setup.sh — status screen on interactive login.
# Skip per user with: touch ~/.hushlogin
case $- in
  *i*)
    if [ -t 1 ] && [ -z "${LOGIN_STATUS_SHOWN:-}" ] && [ -z "${SUDO_USER:-}" ] &&
       [ ! -e "$HOME/.hushlogin" ] && [ -x /usr/local/bin/login-status ]; then
      LOGIN_STATUS_SHOWN=1; export LOGIN_STATUS_SHOWN
      /usr/local/bin/login-status
    fi
    ;;
esac
EOF_HOOK
  chmod 0644 /etc/profile.d/zz-login-status.sh
}

write_login_status_conf() { # only if absent — this file is yours to edit
  [[ -e /etc/login-status.conf ]] && return 0
  cat > /etc/login-status.conf <<'EOF_CONF'
# /etc/login-status.conf — settings for the login status screen (never overwritten)

# Rows to hide (space-separated, case-insensitive):
#   uptime memory disk network updates services docker podman backup crowdsec ssh netbird
HIDE=""

# Backup row: a command run as root by the collector every 5 minutes.
# Its FIRST LINE of output is shown; exit code 0 = green, anything else = red.
# Example (restic):
# BACKUP_CHECK_CMD='restic -r /srv/backup --password-file /root/.restic snapshots --latest 1 --json | jq -r ".[0] | \"\(.short_id) · \(.time[:16])\""'
BACKUP_CHECK_CMD=""

# Seconds between dnf update checks (a package install/upgrade also triggers one).
UPDATE_INTERVAL=14400
EOF_CONF
  chmod 0644 /etc/login-status.conf
}

step_login_status() {
  write_login_status_renderer
  write_login_status_collector
  write_login_status_units
  write_login_status_hook
  write_login_status_conf
  systemctl daemon-reload
  systemctl enable --now login-status-collect.timer >/dev/null
  systemctl start --no-block login-status-collect.service
  ok "Login status installed (preview: login-status · refresh now: sudo /usr/local/libexec/login-status-collect --updates)"
}

check_login_status() {
  [[ -x /usr/local/bin/login-status && -x /usr/local/libexec/login-status-collect &&
     -f /etc/profile.d/zz-login-status.sh ]] &&
    systemctl is-enabled --quiet login-status-collect.timer
}

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
run_step packages \
  "step_packages REQUIRED_PKGS OPTIONAL_PKGS" \
  check_packages step_packages

run_step extra-tools \
  "step_extra_tools gh_asset_url install_gh_tarball install_gh_binary yq_is_mikefarah" \
  check_extra_tools step_extra_tools

run_step login-status \
  "step_login_status write_login_status_renderer write_login_status_collector write_login_status_units write_login_status_hook write_login_status_conf" \
  check_login_status step_login_status

for u in "${USERS[@]}"; do
  run_step "shell@$u" "step_shell write_alias_file" check_shell step_shell "$u"
  if [[ "$SKIP_LAZYVIM" == "1" ]]; then
    skip "lazyvim@$u: skipped (SKIP_LAZYVIM=1)"
  else
    run_step "lazyvim@$u" "step_lazyvim run_as" check_lazyvim step_lazyvim "$u"
  fi
done

state_set version "$SCRIPT_VERSION"
state_set last_run "$TS"

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
echo
log "Installed versions"
for t in nvim eza duf fzf jq yq doggo fastfetch btop iperf3 nmap mtr lazygit; do
  if have "$t"; then
    printf '  %-10s %s\n' "$t" "$("$t" --version 2>&1 | head -n1 || true)"
  else
    printf '  %-10s \e[1;31mMISSING\e[0m\n' "$t"
  fi
done
echo
ok "Done (v$SCRIPT_VERSION). Configured: ${USERS[*]}. Open a new shell (or: source ~/.bashrc) to pick up changes."
