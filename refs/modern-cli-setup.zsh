#!/usr/bin/env zsh
# modern-cli-setup.zsh
#
# Installs modern replacements for classic *nix tools with Homebrew, checks for
# problems before changing anything, and wires up zsh aliases, wrappers and hooks.
#
# Usage: ./modern-cli-setup.zsh [options]
#   --check       Run every preflight check and stop (only refreshes Homebrew's index)
#   --yes, -y     Don't ask for confirmation
#   --no-extras   Skip yazi preview deps, fkill (npm) and the one-time atuin history import
#   --no-aliases  Don't write the alias file or touch .zshrc
#   --no-git      Don't change global git config (delta / difftastic)
#   --force       Continue despite errors, and overwrite conflicting git settings
#   --no-update   Skip `brew update`
#   --zshrc PATH  Use this file instead of the auto-detected .zshrc
#   --no-migrate  Leave custom config in terminal wrapper files where it is
#   --no-lazyvim  Don't install the LazyVim Neovim config
#
# Safe to re-run: installed formulae are skipped, the alias file is regenerated, and
# the .zshrc block is replaced in place (a timestamped backup is made each time).

emulate -L zsh
setopt pipe_fail extended_glob

# ---------------------------------------------------------------------------
# What gets installed
# ---------------------------------------------------------------------------
typeset -a FORMULAE=(
  eza bat fd broot zoxide xcp
  ripgrep ugrep sd choose-rust git-delta difftastic
  jq yq jaq fx csvlens visidata
  duf dust btop viddy procs
  xh mtr gping doggo trippy bandwhich rustscan
  atuin fzf tealdeer hyperfine
  lazygit gitui lazydocker ctop just yazi
  tokei scc
  neovim tree-sitter-cli herdr
  mise direnv uv chezmoi age sops
  dive hadolint nmap iperf3 fastfetch topgrade pueue
  zsh-autosuggestions zsh-syntax-highlighting zsh-completions carapace fzf-tab
)
# yazi previews: video thumbnails, archives, PDFs, SVGs, images
# macOS 15+ ships /usr/bin/trash; Homebrew's trash is keg-only (not on PATH), so only
# pull it in where macOS lacks one — the rm wrapper finds it in its keg.
[[ -x /usr/bin/trash ]] || FORMULAE+=(trash)
typeset -a EXTRAS=(ffmpeg sevenzip poppler resvg imagemagick)
# Deprecated or removed predecessors that clash with the picks above
typeset -a RETIRED=(exa tldr tlrc dog)

# formula -> the binary it puts on PATH (used for shadowing checks)
typeset -A BIN=(
  eza eza  bat bat  fd fd  broot broot  zoxide zoxide  trash trash  xcp xcp
  ripgrep rg  ugrep ug  sd sd  choose-rust choose  git-delta delta  difftastic difft
  jq jq  yq yq  jaq jaq  fx fx  csvlens csvlens  visidata vd
  duf duf  dust dust  btop btop  viddy viddy  procs procs
  xh xh  mtr mtr  gping gping  doggo doggo  trippy trip  bandwhich bandwhich  rustscan rustscan
  atuin atuin  fzf fzf  tealdeer tldr  hyperfine hyperfine
  lazygit lazygit  gitui gitui  lazydocker lazydocker  ctop ctop  just just  yazi yazi
  tokei tokei  scc scc
  neovim nvim  tree-sitter-cli tree-sitter  herdr herdr
  mise mise  direnv direnv  uv uv  chezmoi chezmoi  age age  sops sops
  dive dive  hadolint hadolint  nmap nmap  iperf3 iperf3  fastfetch fastfetch
  topgrade topgrade  pueue pueue  carapace carapace
  # zsh plugin formulae have no binary
)

# Names the alias file defines; used to spot existing definitions in your rc files
typeset -a WRAPPED=(ls ll la lt tree cat find grep df du top htop ps watch ping dig
                    traceroute mtr trip bandwhich diff rm cd cdi z zi cloc http https lg lzd cpx y br vim vi)

ALIAS_DIR=${XDG_CONFIG_HOME:-$HOME/.config}/zsh
ALIAS_FILE=$ALIAS_DIR/modern-cli.zsh
BLOCK_BEGIN='# >>> modern-cli >>>'
BLOCK_END='# <<< modern-cli <<<'

# ---------------------------------------------------------------------------
# Options and output helpers
# ---------------------------------------------------------------------------
zparseopts -D -E -F -- -check=o_check -yes=o_yes y=o_yes -no-extras=o_noextras \
  -no-aliases=o_noaliases -no-git=o_nogit -force=o_force -no-update=o_noupdate \
  -zshrc:=o_zshrc -no-migrate=o_nomigrate -no-lazyvim=o_nolazyvim h=o_help -help=o_help || exit 2

if (( $#o_help )); then
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [[ -t 1 ]]; then
  B=$'\e[1m' RED=$'\e[31m' YEL=$'\e[33m' GRN=$'\e[32m' CYN=$'\e[36m' RST=$'\e[0m'
else
  B= RED= YEL= GRN= CYN= RST=
fi
typeset -a ERRORS WARNINGS
err()  { ERRORS+=("$*");   print -r -- "  ${RED}✗${RST} $*" }
warn() { WARNINGS+=("$*"); print -r -- "  ${YEL}!${RST} $*" }
ok()   { print -r -- "  ${GRN}✓${RST} $*" }
info() { print -r -- "  ${CYN}·${RST} $*" }
step() { print; print -r -- "${B}==> $*${RST}" }
todo() { print -r -- "  ${YEL}→${RST} $*" }
die()  { print -r -- "${RED}${B}error:${RST} $*" >&2; exit 1 }

STAMP=$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d -t modern-cli) || die "mktemp failed"
trap 'command rm -rf -- "$TMP"' EXIT

# Work out which .zshrc is really yours. Terminal shell integrations (Ghostty, kitty,
# VS Code, Terax, …) point ZDOTDIR at a throwaway wrapper directory that then sources
# your real config, so $ZDOTDIR in this shell can't be trusted. A clean zsh started
# without it reads ~/.zshenv — where a custom ZDOTDIR is normally set — and tells us.
if (( $#o_zshrc )); then
  ZSHRC=${o_zshrc[-1]:a}
  ZDOT=${ZSHRC:h}
else
  ZDOT=$(env -u ZDOTDIR zsh -c 'print -r -- "${ZDOTDIR:-$HOME}"' </dev/null 2>/dev/null | tail -1)
  [[ -d $ZDOT ]] || ZDOT=$HOME
  ZSHRC=$ZDOT/.zshrc
fi

# ---------------------------------------------------------------------------
# Preflight: system
# ---------------------------------------------------------------------------
step "System"

[[ $OSTYPE == darwin* ]] || die "this script targets macOS (the trash/mtr/Trash wiring is mac-specific)"
ok "macOS $(sw_vers -productVersion) on $(uname -m)"

command -v brew >/dev/null || die "Homebrew isn't installed: https://brew.sh"
BREW_PREFIX=$(brew --prefix)
ok "Homebrew $(brew --version | head -1 | awk '{print $2}') at $BREW_PREFIX"

if [[ $(uname -m) == arm64 && $BREW_PREFIX == /usr/local ]]; then
  warn "Homebrew is the Intel/Rosetta install on an Apple Silicon Mac; binaries will run under Rosetta"
fi

if xcode-select -p >/dev/null 2>&1; then ok "Xcode Command Line Tools present"
else err "Xcode Command Line Tools missing — run: xcode-select --install"; fi

if [[ -w $BREW_PREFIX/bin ]]; then ok "$BREW_PREFIX/bin is writable"
else err "$BREW_PREFIX/bin isn't writable by $USER (fix ownership of the Homebrew prefix)"; fi

free_gb=$(( $(df -k "$BREW_PREFIX" | awk 'NR==2 {print $4}') / 1024 / 1024 ))
if (( free_gb < 5 )); then warn "only ${free_gb} GB free on the Homebrew volume (ffmpeg + imagemagick alone pull in ~1.5 GB of deps)"
else ok "${free_gb} GB free"; fi

brew_idx=${path[(ie)$BREW_PREFIX/bin]}
if (( brew_idx > $#path )); then err "$BREW_PREFIX/bin isn't on your PATH — add: eval \"\$($BREW_PREFIX/bin/brew shellenv)\""
else ok "$BREW_PREFIX/bin is on PATH (position $brew_idx)"; fi

if [[ ${SHELL:t} == zsh ]]; then ok "login shell is zsh"
else warn "login shell is $SHELL; the aliases are written for zsh"; fi

# ---------------------------------------------------------------------------
# Preflight: formulae
# ---------------------------------------------------------------------------
step "Formulae"

if (( ! $#o_noupdate )); then
  info "refreshing Homebrew's index (brew update)…"
  brew update --quiet >/dev/null 2>&1 || warn "brew update failed; using the cached index"
fi

typeset -a WANT=($FORMULAE)
(( $#o_noextras )) || WANT+=($EXTRAS)

# Ask brew info about exactly these names. `brew formulae` can't be used to test
# existence: in API mode it only lists formulae from locally tapped repos.
# brew info fails outright if any name is unknown, so drop the ones it names and retry.
typeset -a PRESENT=($WANT) MISSING
integer tries
for (( tries = 1; tries <= 15; tries++ )); do
  (( $#PRESENT )) || break
  brew info --json=v2 --formula -- "${PRESENT[@]}" > $TMP/info.json 2>$TMP/info.err && break
  typeset -a unknown=(${(f)"$(grep -oE 'formulae? (with the name|named) "[^"]+"' $TMP/info.err | sed -E 's/.*"([^"]+)"/\1/')"})
  if (( ! $#unknown )); then
    warn "brew info failed: $(head -3 $TMP/info.err)"
    print -r -- '{"formulae":[]}' > $TMP/info.json
    break
  fi
  MISSING+=($unknown)
  PRESENT=(${PRESENT:|unknown})
done
(( $#PRESENT )) || die "brew info didn't recognise any of the formulae — check 'brew info eza' by hand"

brew list --formula -1 > $TMP/installed.txt 2>/dev/null
print -rl -- $PRESENT > $TMP/wanted.txt

# Bottle tag for this Mac, to spot formulae that would compile from source
typeset -A CODENAME=(26 tahoe 15 sequoia 14 sonoma 13 ventura 12 monterey)
mac_major=${$(sw_vers -productVersion)%%.*}
TAG=${CODENAME[$mac_major]:-}
[[ -n $TAG && $(uname -m) == arm64 ]] && TAG=arm64_$TAG

# Parse the JSON with JavaScript for Automation (always present on macOS, unlike jq)
meta=$(osascript -l JavaScript - $TMP/info.json "$TAG" $TMP/installed.txt $TMP/wanted.txt 2>$TMP/jxa.err <<'JXA'
function run(argv) {
  ObjC.import('Foundation');
  const read = p => $.NSString.stringWithContentsOfFileEncodingError(p, $.NSUTF8StringEncoding, null).js || '';
  const data = JSON.parse(read(argv[0]));
  const tag = argv[1];
  const installed = new Set(read(argv[2]).split('\n').filter(Boolean));
  const wanted = new Set(read(argv[3]).split('\n').filter(Boolean));
  // Only report on what we asked for, whatever brew info hands back
  const mine = (data.formulae || []).filter(f =>
    wanted.has(f.name) || wanted.has(f.full_name) || (f.aliases || []).some(a => wanted.has(a)));
  return mine.map(f => {
    const files = (f.bottle && f.bottle.stable && f.bottle.stable.files) || {};
    const bottled = !tag || !!files[tag] || !!files.all;
    const clash = (f.conflicts_with || []).filter(c => installed.has(c));
    const repl = f.deprecation_replacement_formula || f.disable_replacement_formula ||
                 f.deprecation_replacement || f.disable_replacement || '';
    const why = String(f.deprecation_reason || f.disable_reason || '').replace(/\|/g, '/');
    return [f.name, (f.installed || []).length ? 1 : 0, f.outdated ? 1 : 0,
            f.deprecated ? 1 : 0, f.disabled ? 1 : 0, bottled ? 1 : 0,
            clash.join(','), repl, why].join('|');
  }).join('\n');
}
JXA
)

typeset -a TO_INSTALL TO_UPGRADE SEEN
if [[ -z $meta ]]; then
  warn "couldn't parse formula metadata ($(<$TMP/jxa.err)); skipping conflict/deprecation/bottle checks"
  for f in $PRESENT; do grep -qx -- "$f" $TMP/installed.txt || TO_INSTALL+=$f; done
else
  integer n_installed=0 n_seen=0
  for line in ${(f)meta}; do
    IFS='|' read -r name inst outd depr disab bottled clash repl why <<< "$line"
    (( n_seen++ )); SEEN+=$name
    if (( disab )); then err "$name is disabled in Homebrew${why:+ ($why)}${repl:+ — use $repl}"; continue; fi
    (( depr )) && warn "$name is deprecated${why:+ ($why)}${repl:+ — consider $repl}"
    if [[ -n $clash ]]; then
      err "$name conflicts with installed ${clash//,/, } — run: brew uninstall ${clash//,/ }"
    fi
    if (( inst )); then
      (( n_installed++ ))
      (( outd )) && TO_UPGRADE+=$name
    else
      TO_INSTALL+=$name
      (( bottled )) || warn "$name has no prebuilt bottle for $TAG — it will compile from source (slow)"
    fi
  done
  # Anything brew info didn't describe doesn't exist (or isn't installable here)
  MISSING+=(${PRESENT:|SEEN})
  MISSING=(${(u)MISSING})
  for f in $MISSING; do
    if (( ${EXTRAS[(Ie)$f]} )); then warn "$f isn't in Homebrew (optional yazi extra, will skip)"
    else err "$f isn't in Homebrew — drop it from FORMULAE"; fi
  done
  (( $#MISSING )) || ok "all ${#WANT} formulae exist in Homebrew"
  ok "$n_installed already installed, ${#TO_INSTALL} to install, ${#TO_UPGRADE} to upgrade"
fi

for r in $RETIRED; do
  if grep -qx -- "$r" $TMP/installed.txt; then
    warn "retired tool '$r' is installed — run: brew uninstall $r"
  fi
done

# ---------------------------------------------------------------------------
# Preflight: PATH shadowing
# ---------------------------------------------------------------------------
step "PATH shadowing"
integer shadowed=0
for f in $FORMULAE; do
  b=${BIN[$f]}
  [[ -n $b ]] || continue
  for p in ${(f)"$(whence -ap $b 2>/dev/null)"}; do
    [[ $p == $BREW_PREFIX/* ]] && break
    i=${path[(ie)${p:h}]}
    if (( i < brew_idx )); then
      warn "$p comes before Homebrew on PATH, so it will win over brew's $b — remove it or reorder PATH"
      (( shadowed++ ))
      break
    fi
  done
done
(( shadowed )) || ok "no existing binaries will shadow the Homebrew versions"
if [[ -x /usr/bin/trash ]]; then ok "using macOS's built-in /usr/bin/trash for the rm wrapper"
else info "Homebrew's trash is keg-only; the rm wrapper calls it from $BREW_PREFIX/opt/trash/bin"; fi

# ---------------------------------------------------------------------------
# Preflight: shell config
# ---------------------------------------------------------------------------
step "Shell config"

if [[ -n ${ZDOTDIR:-} && ${ZDOTDIR:a} != ${ZDOT:a} && ! $#o_zshrc -gt 0 ]]; then
  info "ignoring ZDOTDIR=${ZDOTDIR/#$HOME/~} (set by your terminal's shell integration); your config lives in ${ZDOT/#$HOME/~}"
fi
if [[ $ZSHRC == */(.cache|shell-integration|Caches)/* ]]; then
  err "$ZSHRC looks like a terminal's generated file, not your config — pass --zshrc ~/.zshrc"
fi

typeset -a RC_FILES=($HOME/.zshenv(N) $ZDOT/.zshenv(N) $ZDOT/.zprofile(N) $ZSHRC(N) $ALIAS_DIR/*.zsh(N))
RC_FILES=(${(u)RC_FILES:#$ALIAS_FILE})

if [[ ! -e $ZSHRC ]]; then info "$ZSHRC doesn't exist yet; it will be created"
elif [[ -L $ZSHRC ]]; then
  warn "$ZSHRC is a symlink to ${ZSHRC:A} (dotfiles manager?) — the block goes into the target; commit it there"
else ok "$ZSHRC found"
fi

if grep -qF -- "$BLOCK_BEGIN" $ZSHRC 2>/dev/null; then info "modern-cli block already in .zshrc; it will be refreshed and moved to the end"; fi

names=${(j:|:)WRAPPED}
integer redefs=0
for rc in $RC_FILES; do
  # Only scan outside our own managed block
  awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '$0==b{s=1} !s{print NR": "$0} $0==e{s=0}' $rc > $TMP/scan.txt
  while IFS= read -r hit; do
    warn "${rc/#$HOME/~}:${hit%%: *} already defines '${${hit#*: }## #}' — the modern-cli block loads later and overrides it"
    (( redefs++ ))
  done < <(grep -E "^[0-9]+: [[:space:]]*(alias[[:space:]]+(-g[[:space:]]+)?($names)=|function[[:space:]]+($names)([[:space:]]|\{|$)|($names)[[:space:]]*\(\))" $TMP/scan.txt)

  while IFS= read -r hit; do
    warn "${rc/#$HOME/~}:${hit%%: *} already initialises a tool the block sets up ('${${hit#*: }## #}') — remove it to avoid double init"
    (( redefs++ ))
  done < <(grep -E "^[0-9]+: .*(zoxide init|atuin init|fzf --zsh|\.fzf\.zsh|broot --print-shell-function|launcher/bash/br|zsh-autosuggestions|zsh-syntax-highlighting|fast-syntax-highlighting|fzf-tab|carapace _carapace|mise activate|direnv hook|herdr completion)" $TMP/scan.txt)

  while IFS= read -r hit; do
    warn "${rc/#$HOME/~}:${hit%%: *} sets '${${hit#*: }## #}' — the modern-cli block sets EDITOR/VISUAL=nvim later and wins"
    (( redefs++ ))
  done < <(grep -E "^[0-9]+: [[:space:]]*(export[[:space:]]+)?(EDITOR|VISUAL)=" $TMP/scan.txt | grep -v 'nvim')
done
(( redefs )) || ok "no existing aliases or init lines clash with the ones being added"

if [[ -n ${ZSH:-} ]] || { (( $#RC_FILES )) && grep -q 'oh-my-zsh.sh' $RC_FILES 2>/dev/null }; then
  info "oh-my-zsh detected: plugins like common-aliases also redefine ls/grep; the modern-cli block loads after them"
fi

if [[ $TERM_PROGRAM == ghostty ]]; then ok "Ghostty has Nerd Font symbols built in, so eza/yazi icons will render"
elif [[ -z $(print -l ~/Library/Fonts/*Nerd*(N) /Library/Fonts/*Nerd*(N)) ]]; then
  warn "no Nerd Font found — eza/yazi icons need one (brew install --cask font-symbols-only-nerd-font)"
fi

# ---------------------------------------------------------------------------
# Preflight: custom config living in terminal wrapper files
# ---------------------------------------------------------------------------
# >>> migrate-functions
# A line counts as the terminal's own plumbing if it mentions any of these
INTEGRATION_RE='terax|shell[-_ ]?integration|zdotdir|\\e\]|\\033\]|\\x1b\]|\\u001b|133;|_integration|term_program|ghostty|kitty|vscode|wezterm|iterm|warp_|(source|\.|builtin)[[:space:]].*\.z(shenv|profile|shrc|login)'

# One entry per chunk found in a wrapper file (parallel arrays)
typeset -a MIG_SRC MIG_DST MIG_FROM MIG_TO MIG_STATUS MIG_NOTE

# scan_wrapper SRC DST — split SRC into chunks (blank-line separated, but keeping
# functions/if-blocks whole) and classify each as integration, present or custom.
scan_wrapper() {
  local src=$1 dst=$2 l t rc code kind note
  local -a lines=("${(@f)$(<$src)}") starts ends
  local -A have
  # A file whose header says it's generated shell integration: any block touching
  # integration code is the terminal's, and only blocks with none of it are yours.
  local generated=0
  [[ ${(L)${(F)lines[1,5]}} =~ '(shell[-_ ]?integration|auto-?generated|generated by|do not edit)' ]] && generated=1
  for rc in $RC_FILES $dst(N); do
    for l in "${(@f)$(<$rc)}"; do
      t=${${l##[[:space:]]#}%%[[:space:]]#}
      [[ -n $t ]] && have[$t]=1
    done
  done

  integer i n=$#lines start=0 depth=0
  for (( i = 1; i <= n; i++ )); do
    l=${lines[i]}
    if [[ -z ${l//[[:space:]]/} ]]; then
      if (( start && depth <= 0 )); then starts+=$start; ends+=$(( i - 1 )); start=0; depth=0; fi
      continue
    fi
    (( start )) || start=i
    # Drop comments (a # at line start or after whitespace) but keep ${#x} and $#
    if [[ ${l##[[:space:]]#} == \#* ]]; then code=; else code=${l%%[[:space:]]\#*}; fi
    (( depth += ${#code//[^\{]/} - ${#code//[^\}]/} ))
    [[ $code =~ '(^|[;[:space:]])(if|case|for|while|until)([[:space:]]|$)' ]] && (( depth++ ))
    [[ $code =~ '(^|[;[:space:]])(fi|esac|done)([[:space:];]|$)' ]] && (( depth-- ))
  done
  (( start )) && { starts+=$start; ends+=$n }

  integer j code_lines integ present
  for (( j = 1; j <= $#starts; j++ )); do
    code_lines=0 integ=0 present=0 note=
    for l in "${(@)lines[starts[j],ends[j]]}"; do
      t=${${l##[[:space:]]#}%%[[:space:]]#}
      [[ -z $t || $t == \#* ]] && continue
      [[ $t =~ '^(fi|done|esac|then|else|do|[{}()]|;;|:|true)[;]?$' ]] && continue   # structure, not content
      (( code_lines++ ))
      [[ ${(L)t} =~ $INTEGRATION_RE ]] && (( integ++ ))
      (( ${+have[$t]} )) && (( present++ ))
    done
    (( code_lines )) || continue
    if   (( integ == code_lines ));   then kind=integration
    elif (( present == code_lines )); then kind=present
    elif (( integ && generated )); then kind=integration
    elif (( integ )); then kind=mixed; note="mixed with terminal integration code — only moved if you confirm it"
    else kind=custom
    fi
    MIG_SRC+=$src MIG_DST+=$dst MIG_FROM+=${starts[j]} MIG_TO+=${ends[j]} MIG_STATUS+=$kind MIG_NOTE+=$note
  done
}

show_chunk() {
  local k=$1; integer i
  local -a L=("${(@f)$(<${MIG_SRC[k]})}")
  for (( i = MIG_FROM[k]; i <= MIG_TO[k]; i++ )); do printf '      %4d │ %s\n' $i "${L[i]}"; done
}

# move_chunks IDX... — append chunks to their real files (above any modern-cli block),
# then delete them from the wrapper. Both sides are backed up first.
move_chunks() {
  local k dst src body ranges
  local -a dsts srcs
  for k in "$@"; do dsts+=${MIG_DST[k]} srcs+=${MIG_SRC[k]}; done

  for dst in ${(u)dsts}; do
    body=
    for k in "$@"; do
      [[ ${MIG_DST[k]} == $dst ]] || continue
      body+="# from ${MIG_SRC[k]/#$HOME/~} (lines ${MIG_FROM[k]}-${MIG_TO[k]})"$'\n'
      # Lines that re-source a startup file would loop once they live in your real config
      body+="$(sed -n "${MIG_FROM[k]},${MIG_TO[k]}p" ${MIG_SRC[k]} |
        awk '{ l = tolower($0) } l ~ /(source|\.|builtin)[ \t].*\.z(shenv|profile|shrc|login)/ { print "# disabled by modern-cli (would re-source your config): " $0; next } { print }')"$'\n\n'
    done
    [[ -e $dst ]] && cp -p -- ${dst:A} $dst.bak.modern-cli-premigrate.$STAMP
    {
      [[ -e $dst ]] && awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '$0==b{s=1} !s{print} $0==e{s=0}' $dst
      print -r -- "# >>> moved from terminal wrapper on ${STAMP%%-*} >>>"
      print -rn -- "$body"
      print -r -- "# <<< moved from terminal wrapper <<<"
      [[ -e $dst ]] && awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '$0==b{s=1} s{print} $0==e{s=0}' $dst
    } > $TMP/mig.new
    cat $TMP/mig.new > $dst && ok "added to ${dst/#$HOME/~} (backup: ${dst:t}.bak.modern-cli-premigrate.$STAMP)"
  done

  for src in ${(u)srcs}; do
    ranges=
    for k in "$@"; do [[ ${MIG_SRC[k]} == $src ]] && ranges+="${MIG_FROM[k]}-${MIG_TO[k]} "; done
    cp -p -- $src $src.bak.modern-cli.$STAMP
    awk -v r="$ranges" 'BEGIN { n = split(r, a, " "); for (i = 1; i <= n; i++) { split(a[i], b, "-"); for (j = b[1]; j <= b[2]; j++) skip[j] = 1 } } !skip[NR]' \
      $src > $TMP/wrap.new && cat $TMP/wrap.new > $src && ok "removed from ${src/#$HOME/~} (backup alongside it)"
  done
}
# <<< migrate-functions

step "Terminal wrapper config"
typeset -a WRAP_DIRS
[[ -n ${ZDOTDIR:-} && ${ZDOTDIR:a} != ${ZDOT:a} ]] && WRAP_DIRS+=${ZDOTDIR:a}
WRAP_DIRS+=($HOME/.cache/*/shell-integration/zsh(N/:a) $HOME/Library/Caches/*/shell-integration/zsh(N/:a))
WRAP_DIRS=(${(u)WRAP_DIRS})
WRAP_DIRS=(${WRAP_DIRS:#${ZDOT:a}})

integer n_custom=0
if (( ! $#WRAP_DIRS )); then
  ok "no terminal shell-integration wrappers found"
else
  for wd in $WRAP_DIRS; do
    for name in .zshenv .zprofile .zshrc .zlogin; do
      [[ -f $wd/$name ]] || continue
      case $name in
        .zshenv) dst=$HOME/.zshenv ;;
        .zshrc)  dst=$ZSHRC ;;
        *)       dst=$ZDOT/$name ;;
      esac
      scan_wrapper $wd/$name $dst
    done
  done
  for (( k = 1; k <= $#MIG_SRC; k++ )); do
    where="${MIG_SRC[k]/#$HOME/~} lines ${MIG_FROM[k]}-${MIG_TO[k]}"
    case ${MIG_STATUS[k]} in
      custom)
        (( n_custom++ ))
        todo "$where is custom → will move to ${MIG_DST[k]/#$HOME/~}"
        show_chunk $k ;;
      mixed)
        (( n_custom++ ))
        warn "$where mixes custom lines with terminal integration code — you'll be asked; --yes leaves it alone"
        show_chunk $k ;;
      present)     info "$where already exists in your config — nothing to move" ;;
      integration) info "$where is the terminal's own integration code — left alone" ;;
    esac
  done
  (( n_custom )) || ok "nothing custom in ${(j:, :)${WRAP_DIRS/#$HOME/~}}"
fi

# ---------------------------------------------------------------------------
# Preflight: git, docker, npm
# ---------------------------------------------------------------------------
step "Git, Docker, npm"

typeset -a GIT_SETTINGS=(
  core.pager                 delta
  interactive.diffFilter     'delta --color-only'
  delta.navigate             true
  diff.colorMoved            default
  merge.conflictStyle        zdiff3
  alias.dft                  '-c diff.external=difft diff'
  alias.dlog                 '-c diff.external=difft log --ext-diff -p'
  alias.dshow                '-c diff.external=difft show --ext-diff'
)

# gitset check|apply key value
gitset() {
  local mode=$1 key=$2 val=$3 cur
  cur=$(git config --global --get "$key" 2>/dev/null)
  [[ $cur == "$val" ]] && { [[ $mode == check ]] || ok "git $key already '$val'"; return 0 }
  if [[ -n $cur && -z $o_force ]]; then
    [[ $mode == check ]] && warn "git $key is '$cur' — will be left alone (--force sets '$val')"
    return 0
  fi
  [[ $mode == apply ]] && git config --global "$key" "$val" && ok "git $key = $val"
}

if (( ! $#o_nogit )); then
  if ! command -v git >/dev/null; then
    warn "git not found; skipping git config"; o_nogit=(--no-git)
  else
    autoload -Uz is-at-least
    gitver=$(git --version | awk '{print $3}')
    if ! is-at-least 2.35 $gitver; then
      warn "git $gitver is older than 2.35; skipping merge.conflictStyle=zdiff3"
      GIT_SETTINGS[(i)merge.conflictStyle]=() GIT_SETTINGS[(i)zdiff3]=()
    fi
    for key val in $GIT_SETTINGS; do gitset check $key $val; done
    ext=$(git config --global --get diff.external 2>/dev/null)
    [[ -n $ext ]] && warn "git diff.external is '$ext', which makes every git diff bypass delta — unset it and use 'git dft' for difftastic"
    ok "git $gitver: delta as pager, difftastic via git dft / dlog / dshow"
  fi
fi

if command -v docker >/dev/null; then ok "docker CLI found for lazydocker/ctop"
else info "no docker CLI — lazydocker and ctop need Docker Desktop, OrbStack or Colima"; fi

if (( ! $#o_nogit )) && command -v git >/dev/null; then
  ce=$(git config --global --get core.editor 2>/dev/null)
  [[ -n $ce && $ce != *nvim* ]] && warn "git core.editor is '$ce', which overrides EDITOR=nvim for commits — unset it to use Neovim"
fi

# ---------------------------------------------------------------------------
# Preflight: Neovim/LazyVim, Node, services
# ---------------------------------------------------------------------------
step "Neovim, Node, services"

NVIM_CFG=${XDG_CONFIG_HOME:-$HOME/.config}/nvim
typeset -a NVIM_DIRS=($NVIM_CFG ${XDG_DATA_HOME:-$HOME/.local/share}/nvim
                      ${XDG_STATE_HOME:-$HOME/.local/state}/nvim ${XDG_CACHE_HOME:-$HOME/.cache}/nvim)
WANT_LAZYVIM=0
if (( $#o_nolazyvim )); then
  info "LazyVim skipped (--no-lazyvim)"
elif [[ -f $NVIM_CFG/lazyvim.json ]] || { [[ -d $NVIM_CFG/lua ]] && grep -rqs 'LazyVim/LazyVim' $NVIM_CFG/lua }; then
  ok "LazyVim is already set up in ${NVIM_CFG/#$HOME/~}"
else
  WANT_LAZYVIM=1
  typeset -a nvim_existing=(${^NVIM_DIRS}(N))
  if (( $#nvim_existing )); then
    todo "existing Neovim files will be moved aside (*.bak.$STAMP): ${(j:, :)${nvim_existing/#$HOME/~}}"
  else
    ok "no existing Neovim config; the LazyVim starter goes in ${NVIM_CFG/#$HOME/~}"
  fi
  if git ls-remote --exit-code https://github.com/LazyVim/starter HEAD >/dev/null 2>&1; then
    ok "github.com/LazyVim/starter is reachable"
  else
    err "can't reach github.com/LazyVim/starter — check network/proxy, or use --no-lazyvim"
  fi
fi

MISE_CFG=${XDG_CONFIG_HOME:-$HOME/.config}/mise/config.toml
WANT_NODE=0
if grep -qsE '^[[:space:]]*node[[:space:]]*=' $MISE_CFG; then
  ok "mise already pins a global Node ($(grep -E '^[[:space:]]*node[[:space:]]*=' $MISE_CFG | head -1 | tr -d ' '))"
else
  WANT_NODE=1
  info "Node LTS will be installed globally with mise (Mason's language servers need npm; Bun can't stand in)"
fi
typeset -a other_node=()
[[ -d ${NVM_DIR:-$HOME/.nvm} ]] && other_node+=nvm
(( $+commands[fnm] )) && other_node+=fnm
{ (( $+commands[volta] )) || [[ -d $HOME/.volta ]] } && other_node+=volta
(( $+commands[asdf] )) && other_node+=asdf
grep -qx node $TMP/installed.txt && other_node+="Homebrew node"
(( $#other_node )) && warn "other Node installs found (${(j:, :)other_node}); mise activates last so its node wins in new shells, but consider removing them"

if (( ! $#o_noextras )); then
  if command -v fkill >/dev/null; then ok "fkill already installed"
  else WANT_FKILL=1; info "fkill (npm-only) will be installed with mise's npm"; fi
fi

if brew services list 2>/dev/null | awk '$1=="pueue" && $2=="started"{f=1} END{exit !f}'; then
  ok "pueue daemon already running"
else
  WANT_PUEUED=1; info "the pueue daemon will be started with brew services (runs at login)"
fi

info "mtr, trip and bandwhich need raw sockets, so their aliases run them through sudo"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------
step "Summary"
print -r -- "  ${#ERRORS} error(s), ${#WARNINGS} warning(s)"

if (( $#o_check )); then
  print -r -- "  --check: nothing was changed."
  (( $#ERRORS )) && exit 1 || exit 0
fi
if (( $#ERRORS && ! $#o_force )); then
  print -r -- "  ${RED}Fix the errors above, or re-run with --force to continue anyway.${RST}"
  exit 1
fi

print
(( $#TO_INSTALL )) && print -r -- "  install:  ${TO_INSTALL[*]}"
(( $#TO_UPGRADE )) && print -r -- "  upgrade:  ${TO_UPGRADE[*]}"
(( WANT_LAZYVIM )) && print -r -- "  neovim:   LazyVim starter in ${NVIM_CFG/#$HOME/~} (existing files backed up)"
(( WANT_NODE )) && print -r -- "  mise:     node@lts as the global Node"
(( ${WANT_FKILL:-0} )) && print -r -- "  npm:      fkill-cli"
(( ${WANT_PUEUED:-0} )) && print -r -- "  service:  brew services start pueue"
(( $#o_nogit )) || print -r -- "  git:      delta pager, difftastic aliases (global config)"
if (( n_custom && ! $#o_nomigrate )); then
  if (( $#o_yes )); then print -r -- "  migrate:  move all $n_custom custom block(s) out of the terminal wrapper"
  else print -r -- "  migrate:  $n_custom custom block(s) from the terminal wrapper (you'll confirm each)"; fi
fi
(( $#o_noaliases )) || print -r -- "  shell:    write ${ALIAS_FILE/#$HOME/~} and source it from ${ZSHRC/#$HOME/~}"

if (( ! $#o_yes )); then
  [[ -t 0 ]] || die "not running in a terminal; re-run with --yes"
  print
  read -q "?Proceed? [y/N] " || { print; exit 0 }
  print
fi

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
step "Installing"

if (( $#TO_INSTALL )); then
  brew install ${TO_INSTALL[@]} || err "brew install reported failures (see output above)"
fi
if (( $#TO_UPGRADE )); then
  brew upgrade ${TO_UPGRADE[@]} || warn "brew upgrade reported failures"
fi
(( $#TO_INSTALL + $#TO_UPGRADE )) || ok "nothing to install"

step "Post-install"
rehash

# Homebrew's zsh dirs must not be group-writable or compinit refuses to load them
chmod -R go-w "$BREW_PREFIX/share/zsh" 2>/dev/null && ok "secured $BREW_PREFIX/share/zsh permissions for compinit"

if (( WANT_NODE )) && (( $+commands[mise] )); then
  mise use -g node@lts && ok "mise global Node set to LTS" || warn "mise use -g node@lts failed; run it manually"
fi
if (( ${WANT_FKILL:-0} )) && (( $+commands[mise] )); then
  mise exec -- npm install -g fkill-cli >/dev/null 2>&1 && ok "fkill installed" || warn "npm install -g fkill-cli failed"
fi

if (( WANT_LAZYVIM )) && (( $+commands[nvim] )); then
  for d in $NVIM_DIRS; do
    [[ -e $d ]] && mv -- $d $d.bak.$STAMP && ok "moved ${d/#$HOME/~} → ${d:t}.bak.$STAMP"
  done
  if git clone --quiet https://github.com/LazyVim/starter $NVIM_CFG; then
    command rm -rf -- "$NVIM_CFG/.git"
    ok "LazyVim starter cloned to ${NVIM_CFG/#$HOME/~}"
    info "installing plugins headlessly (first run can take a minute)…"
    if nvim --headless "+Lazy! sync" +qa >/dev/null 2>&1; then ok "LazyVim plugins installed"
    else warn "plugin sync reported errors; open nvim and run :Lazy"; fi
  else
    err "cloning the LazyVim starter failed"
  fi
fi

if (( ${WANT_PUEUED:-0} )) && (( $+commands[pueued] )); then
  brew services start pueue >/dev/null 2>&1 && ok "pueue daemon started" || warn "brew services start pueue failed"
fi

if (( $+commands[tldr] )); then
  tldr --update >/dev/null 2>&1 && ok "tealdeer page cache downloaded" || warn "tldr --update failed; run it later"
fi
if (( $+commands[broot] )); then
  # Stops broot offering to edit .zshrc itself; br is defined by the alias file instead
  broot --set-install-state installed >/dev/null 2>&1 && ok "broot marked as installed (br comes from the alias file)"
fi
if (( $+commands[atuin] )) && (( ! $#o_noextras )); then
  marker=${XDG_DATA_HOME:-$HOME/.local/share}/atuin/.modern-cli-imported
  if [[ -e $marker ]]; then ok "atuin history import already done"
  elif atuin import auto >/dev/null 2>&1; then
    mkdir -p ${marker:h} && touch $marker
    ok "imported existing zsh history into atuin"
  else warn "atuin import auto failed; run it manually"; fi
fi

if (( ! $#o_nogit )); then
  for key val in $GIT_SETTINGS; do gitset apply $key $val; done
fi

# ---------------------------------------------------------------------------
# Aliases
# ---------------------------------------------------------------------------
if (( n_custom && ! $#o_nomigrate )); then
  step "Moving custom config out of the terminal wrapper"
  typeset -a MOVE
  for (( k = 1; k <= $#MIG_SRC; k++ )); do
    [[ ${MIG_STATUS[k]} == (custom|mixed) ]] || continue
    if (( $#o_yes )) && [[ ${MIG_STATUS[k]} == mixed ]]; then
      warn "${MIG_SRC[k]/#$HOME/~} lines ${MIG_FROM[k]}-${MIG_TO[k]} left in place (mixed with integration code; re-run without --yes to decide)"
      continue
    fi
    if (( ! $#o_yes )); then
      print
      print -r -- "  ${MIG_SRC[k]/#$HOME/~} lines ${MIG_FROM[k]}-${MIG_TO[k]}${MIG_NOTE[k]:+  (${MIG_NOTE[k]})}:"
      show_chunk $k
      if ! read -q "?  Move this to ${MIG_DST[k]/#$HOME/~}? [y/N] "; then print; info "left in the wrapper"; continue; fi
      print
    fi
    MOVE+=$k
  done
  if (( $#MOVE )); then move_chunks $MOVE; else info "nothing moved"; fi
fi

if (( ! $#o_noaliases )); then
  step "Shell wiring"
  mkdir -p $ALIAS_DIR

  cat > $ALIAS_FILE <<'ALIASES'
# modern-cli.zsh — generated by modern-cli-setup.zsh. Re-running that script
# regenerates this file, so put personal tweaks in .zshrc instead.
#
# Escape hatches: `command ls`, `\ls`, `builtin cd` always reach the original.
# Everything here only applies to interactive shells; scripts get the real tools.
#
# Toggles — set them in .zshrc *above* the modern-cli block:
#   MODERN_CLI_GREP=rg|ugrep|off   what `grep` runs              (default rg)
#   MODERN_CLI_CD=zoxide|z         zoxide replaces cd, or z/zi   (default zoxide)
#   MODERN_CLI_RM=trash|off        rm moves to the Trash          (default trash)
#   MODERN_CLI_ATUIN_UP=0|1        atuin also takes the Up arrow (default 0)

(( $+commands[nvim] )) && export EDITOR=nvim VISUAL=nvim

[[ -o interactive ]] || return 0

: ${MODERN_CLI_GREP:=rg} ${MODERN_CLI_CD:=zoxide} ${MODERN_CLI_RM:=trash} ${MODERN_CLI_ATUIN_UP:=0}

_mc_has() { (( $+commands[$1] )) }
# True if any argument before `--` is an option
_mc_opts() { local a; for a in "$@"; do [[ $a == -- ]] && return 1; [[ $a == -?* ]] && return 0; done; return 1 }

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
_mc_has viddy && alias watch='viddy'

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
if _mc_has trip; then
  alias trip="sudo ${commands[trip]}"
  unalias traceroute 2>/dev/null
  function traceroute { if (( $# == 0 )) || _mc_opts "$@"; then command traceroute "$@"; else sudo ${commands[trip]} "$@"; fi }
fi
_mc_has mtr       && alias mtr="sudo ${commands[mtr]}"
_mc_has bandwhich && alias bandwhich="sudo ${commands[bandwhich]}"
_mc_has xh        && alias http='xh'
_mc_has xhs       && alias https='xhs'

# --- diff → difftastic for plain two-file diffs ------------------------------
if _mc_has difft; then
  unalias diff 2>/dev/null
  function diff { if (( $# == 2 )) && ! _mc_opts "$@"; then command difft "$@"; else command diff "$@"; fi }
fi

# --- rm → Trash ---------------------------------------------------------------
_mc_brew=${HOMEBREW_PREFIX:-${commands[brew]:h:h}}
# macOS's own trash first; Homebrew's is keg-only so it's never on PATH
_mc_trash=
for _mc_t in /usr/bin/trash $_mc_brew/opt/trash/bin/trash; do [[ -x $_mc_t ]] && { _mc_trash=$_mc_t; break }; done
if [[ $MODERN_CLI_RM == trash && -n $_mc_trash ]]; then
  unalias rm 2>/dev/null
  # Moves to the macOS Trash (recoverable). -r/-i/etc. are ignored since Trash handles
  # directories itself; -f keeps rm's "ignore missing files" behaviour.
  # `command rm` deletes permanently.
  function rm {
    local -a files; local a endopts=0 force=0
    for a in "$@"; do
      if (( ! endopts )); then
        [[ $a == -- ]] && { endopts=1; continue }
        if [[ $a == -?* ]]; then [[ ( $a == -[^-]* && $a == *f* ) || $a == --force ]] && force=1; continue; fi
      fi
      (( force )) && [[ ! -e $a && ! -L $a ]] && continue
      [[ $a == -* ]] && a="./$a"
      files+=("$a")
    done
    if (( ! $#files )); then
      (( force )) && return 0
      print -u2 "usage: rm FILE... (moves to Trash; 'command rm' deletes permanently)"; return 1
    fi
    $_mc_trash "${files[@]}"
  }
fi

# --- small conveniences ------------------------------------------------------
_mc_has tokei      && alias cloc='tokei'
_mc_has lazygit    && alias lg='lazygit'
_mc_has lazydocker && alias lzd='lazydocker'
_mc_has xcp        && alias cpx='xcp'      # cp's flags differ too much to replace it outright
_mc_has nvim       && alias vim='nvim' vi='nvim'

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

# br: broot that can cd
_mc_has broot && source <(broot --print-shell-function zsh)

# --- completion: extra completions, carapace, fzf-tab -------------------------
fpath=($_mc_brew/share/zsh-completions(N/) $_mc_brew/share/zsh/site-functions(N/) $fpath)
fpath=(${(u)fpath})
autoload -Uz compinit && compinit -i      # (re)scan so the new completion dirs are picked up
zstyle ':completion:*' menu no
zstyle ':completion:*:descriptions' format '[%d]'
if _mc_has carapace; then
  export CARAPACE_BRIDGES=${CARAPACE_BRIDGES:-'zsh,fish,bash,inshellisense'}
  source <(carapace _carapace)
fi
_mc_has herdr && source <(herdr completion zsh)
for _mc_f in $_mc_brew/opt/fzf-tab/share/fzf-tab/fzf-tab.zsh $_mc_brew/share/fzf-tab/fzf-tab.zsh; do
  [[ -r $_mc_f ]] && break
done
if [[ -r $_mc_f ]]; then
  source $_mc_f     # after compinit, before widget wrappers
  _mc_has eza && zstyle ':fzf-tab:complete:(cd|z|zi|__zoxide_z):*' fzf-preview 'eza -1 --color=always --icons=always $realpath'
fi

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
  if [[ $MODERN_CLI_CD == zoxide ]]; then eval "$(zoxide init zsh --cmd cd)"   # cd + cdi
  else eval "$(zoxide init zsh)"; fi                                          # z + zi
fi

# --- these wrap every widget defined above, so they load last ------------------
[[ -r $_mc_brew/share/zsh-autosuggestions/zsh-autosuggestions.zsh ]] &&
  source $_mc_brew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
if [[ -r $_mc_brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ]]; then
  export ZSH_HIGHLIGHT_HIGHLIGHTERS_DIR=$_mc_brew/share/zsh-syntax-highlighting/highlighters
  source $_mc_brew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh   # must be the very last thing
fi
ALIASES

  if zsh -n $ALIAS_FILE; then ok "wrote ${ALIAS_FILE/#$HOME/~}"
  else err "generated alias file has a syntax error: $ALIAS_FILE"; fi

  # Replace (or add) the managed block at the very end of .zshrc
  if [[ -e $ZSHRC ]]; then
    backup=$ZSHRC.bak.modern-cli.$(date +%Y%m%d-%H%M%S)
    cp -p -- ${ZSHRC:A} $backup && ok "backed up .zshrc to ${backup/#$HOME/~}"
  fi
  {
    [[ -e $ZSHRC ]] && awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '$0==b{s=1} !s{print} $0==e{s=0}' $ZSHRC
    print -r -- "$BLOCK_BEGIN"
    print -r -- "# Managed by modern-cli-setup.zsh — keep this as the last thing in .zshrc."
    print -r -- "[[ -r \"$ALIAS_FILE\" ]] && source \"$ALIAS_FILE\""
    print -r -- "$BLOCK_END"
  } > $TMP/zshrc.new
  # Write through any symlink rather than replacing it
  cat $TMP/zshrc.new > $ZSHRC && ok "sourced from ${ZSHRC/#$HOME/~}"

  step "Verifying in a fresh interactive shell"
  cat > $TMP/verify.zsh <<'VERIFY'
{
  for c in ls cat find grep df du ps ping dig diff rm cd vim y br; do
    print -r -- "cmd|$c|$(whence -w $c 2>/dev/null | cut -d' ' -f2)"
  done
  print -r -- "plug|autosuggestions|$(( $+functions[_zsh_autosuggest_start] ))"
  print -r -- "plug|syntax highlighting|$(( ${+ZSH_HIGHLIGHT_VERSION} ))"
  print -r -- "plug|fzf-tab|$(( $+functions[fzf-tab-complete] ))"
  print -r -- "plug|atuin (Ctrl-R)|$(( $+widgets[atuin-search] ))"
  print -r -- "plug|zoxide|$(( $+functions[__zoxide_z] ))"
  print -r -- "plug|mise|$(( $+functions[_mise_hook] ))"
  print -r -- "plug|rm → Trash|$(( ${+_mc_trash} && ${#_mc_trash} ))"
} > "$1"
VERIFY
  # Output goes to a file: the terminal's own prompt hooks print escape codes to stdout
  zsh -i $TMP/verify.zsh $TMP/verify.txt </dev/null >/dev/null 2>$TMP/verify.err
  if [[ ! -s $TMP/verify.txt ]]; then
    warn "couldn't start a test shell: $(head -3 $TMP/verify.err)"
  else
    typeset -a funcs missing_v
    while IFS='|' read -r kind name val; do
      if [[ $kind == cmd ]]; then
        [[ $val == (function|alias) ]] && funcs+=$name || missing_v+=$name
      else
        (( val )) && funcs+=$name || missing_v+=$name
      fi
    done < $TMP/verify.txt
    ok "loaded: ${(j:, :)funcs}"
    (( $#missing_v )) && warn "not active in a new shell: ${(j:, :)missing_v}"
    [[ -s $TMP/verify.err ]] && info "shell startup printed to stderr: $(head -2 $TMP/verify.err)"
  fi
fi

# ---------------------------------------------------------------------------
step "Done"
print -r -- "  ${#ERRORS} error(s), ${#WARNINGS} warning(s)"
(( $#ERRORS )) && for e in $ERRORS; do print -r -- "  ${RED}✗${RST} $e"; done
print -r -- "  Open a new terminal tab (or run: exec zsh) to pick everything up."
(( $#ERRORS )) && exit 1 || exit 0
