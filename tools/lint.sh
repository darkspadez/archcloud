#!/usr/bin/env bash
# lint.sh — shellcheck every bash script, zsh -n every zsh file, bash -n the rest.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

AIROOTFS=configs/archcloud/airootfs
BASH_SCRIPTS=(
  build.sh tools/*.sh
  configs/archcloud/profiledef.sh
  "$AIROOTFS"/usr/local/bin/archcloud-install
  "$AIROOTFS"/usr/local/bin/archcloud-seed
  "$AIROOTFS"/usr/local/bin/choose-mirror
  "$AIROOTFS"/usr/local/lib/archcloud/lib.sh
  "$AIROOTFS"/usr/local/lib/archcloud/arch-server-bootstrap.sh
  "$AIROOTFS"/usr/local/lib/archcloud/templates/limine-update
  "$AIROOTFS"/usr/local/lib/archcloud/templates/login-status
  "$AIROOTFS"/usr/local/lib/archcloud/templates/login-status-collect
  "$AIROOTFS"/root/.automated_script.sh
)
SH_SCRIPTS=("$AIROOTFS"/usr/local/lib/archcloud/templates/zz-login-status.sh)
ZSH_FILES=(
  "$AIROOTFS"/usr/local/lib/archcloud/templates/zshrc
  "$AIROOTFS"/usr/local/lib/archcloud/templates/modern-cli.zsh
  "$AIROOTFS"/root/.zlogin
)

rc=0
echo "==> shellcheck (bash)"
shellcheck -S warning -s bash -x -P SCRIPTDIR "${BASH_SCRIPTS[@]}" || rc=1
echo "==> shellcheck (sh)"
shellcheck -S warning -s sh "${SH_SCRIPTS[@]}" || rc=1
echo "==> bash -n"
for f in "${BASH_SCRIPTS[@]}"; do bash -n "$f" || rc=1; done
if command -v zsh >/dev/null; then
  echo "==> zsh -n"
  for f in "${ZSH_FILES[@]}"; do zsh -n "$f" || { echo "zsh syntax error: $f"; rc=1; }; done
else
  echo "==> zsh not installed; skipping zsh -n"
fi
echo "==> pacman.conf.in placeholders"
for ph in @ARCHITECTURE@ @CACHYOS_REPOS@ @DISABLE_SANDBOX@; do
  grep -q "$ph" configs/archcloud/pacman.conf.in || { echo "missing $ph"; rc=1; }
done
(( rc == 0 )) && echo "lint OK" || echo "lint FAILED"
exit $rc
