#!/usr/bin/env bash
#
# make-seed.sh — build an archcloud seed ISO (volume label ARCHCLOUD).
#
#   tools/make-seed.sh -o seed.iso --hostname web1 --key ~/.ssh/id_ed25519.pub \
#       --set TIMEZONE=UTC --set PASSWORD_HASH='$6$...' [--network static-v6.network] [DIR]
#
#   -o FILE            output ISO (default: seed.iso)
#   --hostname NAME    HOSTNAME= in install.conf
#   --key FILE|STRING  public key appended to authorized_keys (repeatable)
#   --set KEY=VALUE    any install.conf setting (repeatable)
#   --network FILE     systemd-networkd file copied to network/ (repeatable)
#   DIR                optional directory whose contents are included as-is
#
# Attach the ISO as a second CD-ROM (or write it to a USB stick): the live
# environment merges authorized_keys into root's keys before sshd starts, and
# archcloud-install applies install.conf + network/ to the installed system.
# Needs one of: xorrisofs (libisoburn), genisoimage/mkisofs, or hdiutil (macOS).
set -Eeuo pipefail

OUT=seed.iso
SRC_DIR=""
declare -a KEYS=() SETS=() NETS=()
HOSTNAME_OVERRIDE=""

die() { printf 'make-seed: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '3,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while (( $# )); do
  case "$1" in
    -o)         OUT=$2; shift 2 ;;
    --hostname) HOSTNAME_OVERRIDE=$2; shift 2 ;;
    --key)      KEYS+=("$2"); shift 2 ;;
    --set)      SETS+=("$2"); shift 2 ;;
    --network)  NETS+=("$2"); shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    -*)         die "unknown option $1" ;;
    *)          SRC_DIR=$1; shift ;;
  esac
done

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

if [[ -n "$SRC_DIR" ]]; then
  [[ -d "$SRC_DIR" ]] || die "$SRC_DIR is not a directory"
  cp -R "$SRC_DIR"/. "$stage"/
fi

{
  [[ -f "$stage/install.conf" ]] && cat "$stage/install.conf"
  [[ -n "$HOSTNAME_OVERRIDE" ]] && printf 'HOSTNAME="%s"\n' "$HOSTNAME_OVERRIDE"
  for kv in "${SETS[@]}"; do
    [[ "$kv" == *=* ]] || die "--set expects KEY=VALUE, got '$kv'"
    printf '%s="%s"\n' "${kv%%=*}" "${kv#*=}"
  done
} > "$stage/install.conf.new"
if [[ -s "$stage/install.conf.new" ]]; then mv "$stage/install.conf.new" "$stage/install.conf"; else rm -f "$stage/install.conf.new"; fi

for k in "${KEYS[@]}"; do
  if [[ -f "$k" ]]; then cat "$k"; else printf '%s\n' "$k"; fi
done >> "$stage/authorized_keys"
[[ -s "$stage/authorized_keys" ]] || rm -f "$stage/authorized_keys"

if (( ${#NETS[@]} )); then
  mkdir -p "$stage/network"
  for n in "${NETS[@]}"; do [[ -f "$n" ]] || die "network file $n missing"; cp "$n" "$stage/network/"; done
fi

[[ -n "$(ls -A "$stage")" ]] || die "seed would be empty; give --hostname/--key/--set/DIR"

if command -v xorrisofs >/dev/null 2>&1; then
  xorrisofs -quiet -V ARCHCLOUD -J -R -o "$OUT" "$stage"
elif command -v genisoimage >/dev/null 2>&1; then
  genisoimage -quiet -V ARCHCLOUD -J -R -o "$OUT" "$stage"
elif command -v mkisofs >/dev/null 2>&1; then
  mkisofs -quiet -V ARCHCLOUD -J -R -o "$OUT" "$stage"
elif command -v hdiutil >/dev/null 2>&1; then
  hdiutil makehybrid -quiet -iso -joliet -default-volume-name ARCHCLOUD -o "$OUT" "$stage"
else
  die "need xorrisofs, genisoimage, mkisofs or hdiutil"
fi
printf 'make-seed: wrote %s (%s)\n' "$OUT" "$(ls "$stage" | tr '\n' ' ')"
