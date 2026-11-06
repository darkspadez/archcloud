# /etc/zsh/modern-cli.zsh — installed by arch-server-bootstrap (archcloud).
# Ported from modern-cli-setup.zsh (macOS/Homebrew) to Arch paths; rm->trash,
# Homebrew-only plugins (fzf-tab, carapace, broot, herdr, viddy) are dropped.
#
# Escape hatches: `command ls`, `\ls`, `builtin cd` always reach the original.
# Everything here only applies to interactive shells; scripts get the real tools.
#
# Toggles — set them in ~/.zshenv (read before this file):
#   MODERN_CLI_GREP=rg|ugrep|off   what `grep` runs              (default rg)
#   MODERN_CLI_CD=zoxide|z         zoxide replaces cd, or z/zi   (default zoxide)
#   MODERN_CLI_ATUIN_UP=0|1        atuin also takes the Up arrow (default 0)
#   MODERN_CLI_WRAP=0              skip every wrapper, keep completion/plugins

(( $+commands[nvim] )) && export EDITOR=nvim VISUAL=nvim

[[ -o interactive ]] || return 0

: ${MODERN_CLI_GREP:=rg} ${MODERN_CLI_CD:=zoxide} ${MODERN_CLI_ATUIN_UP:=0} ${MODERN_CLI_WRAP:=1}

_mc_has() { (( $+commands[$1] )) }
# True if any argument before `--` is an option
_mc_opts() { local a; for a in "$@"; do [[ $a == -- ]] && return 1; [[ $a == -?* ]] && return 0; done; return 1 }

if (( MODERN_CLI_WRAP )); then

# --- ls / tree → eza ---------------------------------------------------------
if _mc_has eza; then
  unalias ls ll la lt tree 2>/dev/null
  _mc_eza=(eza --group-directories-first --icons=auto)
  function ls {
    local a
    for a in "$@"; do
      [[ $a == -- ]] && break
      # eza reads -t/-s/-S/-c/-f differently (time field, sort, blocksize…): use real ls
      if [[ $a == -[^-]* && $a == *[tsScf]* ]]; then command ls "$@"; return; fi
    done
    command $_mc_eza "$@"
  }
  function ll   { command $_mc_eza -l --git "$@" }
  function la   { command $_mc_eza -la --git "$@" }
  function lt   { command $_mc_eza --tree --level=2 "$@" }
  function tree { command $_mc_eza --tree "$@" }
fi

# --- cat → bat, man pages through bat ---------------------------------------
if _mc_has bat; then
  unalias cat 2>/dev/null
  function cat { if _mc_opts "$@"; then command cat "$@"; else command bat --paging=never "$@"; fi }
  export BAT_THEME=${BAT_THEME:-ansi}
  export MANPAGER="sh -c 'col -bx | bat -l man -p'" MANROFFOPT="-c"
fi

# --- find → fd (any find predicate like -name falls back to real find) -----
if _mc_has fd; then
  unalias find 2>/dev/null
  function find {
    if _mc_opts "$@"; then command find "$@"
    elif (( $# == 1 )) && [[ -d $1 ]]; then command fd . "$1"
    else command fd "$@"; fi
  }
fi

# --- grep → ripgrep (or ugrep) ----------------------------------------------
if [[ $MODERN_CLI_GREP == rg ]] && _mc_has rg; then
  unalias grep 2>/dev/null
  # Translate grep's boolean flags to rg's: rg recurses by default and skips binaries,
  # and its -r/-E/-I/-h/-L/-s mean different things.
  function grep {
    local -a args extra; local a c endopts=0 takesarg=0
    for a in "$@"; do
      if (( takesarg )); then takesarg=0                       # value of -e/-f/-A/-B/-C/-m
      elif (( ! endopts )) && [[ $a == -[efABCm] ]]; then takesarg=1
      elif (( ! endopts )) && [[ $a == -- ]]; then endopts=1
      elif (( ! endopts )) && [[ $a =~ '^-[rREinvwlcoqsxHhILF]+$' ]]; then
        c=${a#-}; c=${c//[rREI]/}; extra=()
        [[ $c == *L* ]] && { c=${c//L/}; extra+=(--files-without-match) }
        [[ $c == *s* ]] && { c=${c//s/}; extra+=(--no-messages) }
        c=${c//h/I}
        [[ -n $c ]] && args+=(-$c)
        args+=($extra); continue
      fi
      args+=("$a")
    done
    command rg "${args[@]}"
  }
elif [[ $MODERN_CLI_GREP == ugrep ]] && _mc_has ug; then
  unalias grep 2>/dev/null
  alias grep='ug'
fi

# --- df / du → duf / dust (-h is the default there; other flags use the originals)
if _mc_has duf; then
  unalias df 2>/dev/null
  function df { local -a a=("${@:#-h}"); if _mc_opts "${a[@]}"; then command df "$@"; else command duf "${a[@]}"; fi }
fi
if _mc_has dust; then
  unalias du 2>/dev/null
  function du { local -a a=("${@:#-h}"); if _mc_opts "${a[@]}"; then command du "$@"; else command dust "${a[@]}"; fi }
fi

# --- processes ----------------------------------------------------------------
_mc_has btop  && alias top='btop' htop='btop'
if _mc_has procs; then
  unalias ps 2>/dev/null
  function ps { if (( $# )); then command ps "$@"; else command procs; fi }   # `ps aux` etc. stay classic
fi

# --- networking ---------------------------------------------------------------
if _mc_has gping; then
  unalias ping 2>/dev/null
  function ping { if (( $# == 0 )) || _mc_opts "$@"; then command ping "$@"; else command gping "$@"; fi }
fi
if _mc_has doggo; then
  unalias dig 2>/dev/null
  function dig {
    local a
    for a in "$@"; do [[ $a == [-+]* ]] && { command dig "$@"; return } ; done   # +short, -x… stay dig
    if (( $# )); then command doggo "$@"; else command dig; fi
  }
fi
# raw sockets: run through sudo (NOPASSWD for wheel on archcloud boxes)
_mc_sudo() { if (( EUID == 0 )); then "$@"; else sudo "$@"; fi }
if _mc_has trip; then
  alias trip="_mc_sudo ${commands[trip]}"
  unalias traceroute 2>/dev/null
  function traceroute { if (( $# == 0 )) || _mc_opts "$@"; then command traceroute "$@"; else _mc_sudo ${commands[trip]} "$@"; fi }
fi
_mc_has mtr       && alias mtr="_mc_sudo ${commands[mtr]}"
_mc_has bandwhich && alias bandwhich="_mc_sudo ${commands[bandwhich]}"
_mc_has xh        && alias http='xh'
_mc_has xhs       && alias https='xhs'

# --- diff → difftastic for plain two-file diffs ------------------------------
if _mc_has difft; then
  unalias diff 2>/dev/null
  function diff { if (( $# == 2 )) && ! _mc_opts "$@"; then command difft "$@"; else command diff "$@"; fi }
fi

# --- small conveniences ------------------------------------------------------
_mc_has tokei      && alias cloc='tokei'
_mc_has lazygit    && alias lg='lazygit'
_mc_has lazydocker && alias lzd='lazydocker'
_mc_has nvim       && alias vim='nvim' vi='nvim' vimdiff='nvim -d'
_mc_has fastfetch  && alias neofetch='fastfetch'

# y: yazi that cds to wherever you quit it
if _mc_has yazi; then
  function y {
    local tmp cwd
    tmp=$(mktemp -t yazi-cwd.XXXXXX)
    command yazi "$@" --cwd-file="$tmp"
    IFS= read -r -d '' cwd < "$tmp"
    [[ -n $cwd && $cwd != $PWD ]] && builtin cd -- "$cwd"
    command rm -f -- "$tmp"
  }
fi

fi  # MODERN_CLI_WRAP

# --- completion ---------------------------------------------------------------
# zsh-completions installs into /usr/share/zsh/site-functions (already on fpath).
autoload -Uz compinit
_mc_zcache=${XDG_CACHE_HOME:-$HOME/.cache}/zsh
command mkdir -p -- "$_mc_zcache" 2>/dev/null
compinit -i -d "$_mc_zcache/zcompdump"
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
zstyle ':completion:*:descriptions' format '[%d]'
zstyle ':completion:*' cache-path "$_mc_zcache/zcompcache"
zstyle ':completion:*' use-cache on

# --- environment managers ------------------------------------------------------
_mc_has mise   && eval "$(mise activate zsh)"
_mc_has direnv && eval "$(direnv hook zsh)"

# --- shell integrations (order matters: fzf first, then atuin takes Ctrl-R) --
if _mc_has fzf; then
  if _mc_has fd; then
    export FZF_DEFAULT_COMMAND=${FZF_DEFAULT_COMMAND:-'fd --type f --hidden --follow --exclude .git'}
    export FZF_CTRL_T_COMMAND=${FZF_CTRL_T_COMMAND:-$FZF_DEFAULT_COMMAND}
    export FZF_ALT_C_COMMAND=${FZF_ALT_C_COMMAND:-'fd --type d --hidden --follow --exclude .git'}
  fi
  export FZF_DEFAULT_OPTS=${FZF_DEFAULT_OPTS:-'--height 40% --layout=reverse --border --info=inline'}
  _mc_has bat && export FZF_CTRL_T_OPTS=${FZF_CTRL_T_OPTS:-"--preview 'bat --color=always --style=numbers --line-range=:300 {}'"}
  _mc_has eza && export FZF_ALT_C_OPTS=${FZF_ALT_C_OPTS:-"--preview 'eza --tree --level=2 --color=always --icons=always {}'"}
  source <(fzf --zsh)
fi

if _mc_has atuin; then
  if (( MODERN_CLI_ATUIN_UP )); then eval "$(atuin init zsh)"
  else eval "$(atuin init zsh --disable-up-arrow)"; fi
fi

# zoxide last, as its docs recommend
if _mc_has zoxide; then
  unalias cd z zi cdi 2>/dev/null
  if [[ $MODERN_CLI_CD == zoxide && $MODERN_CLI_WRAP == 1 ]]; then eval "$(zoxide init zsh --cmd cd)"   # cd + cdi
  else eval "$(zoxide init zsh)"; fi                                                                 # z + zi
fi

# --- these wrap every widget defined above, so they load last ------------------
[[ -r /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh ]] &&
  source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
if [[ -r /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # must be the very last thing
fi
