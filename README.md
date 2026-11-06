# archcloud

An [archiso](https://gitlab.archlinux.org/archlinux/archiso) profile that produces an **unattended
Arch Linux / CachyOS installer ISO for cloud VMs** (netcup and other KVM VPS, Proxmox/libvirt,
VMware, Hyper-V).

Boot it, and after a 30-second countdown it wipes the VM's disk and installs a server whose end
state is `arch-server-bootstrap.sh` (CachyOS kernel + tuning, Docker, zram/oomd/BBR/ADIOS, btrfs
snapshots, key-only SSH, passwordless sudo) plus a modern CLI toolkit (eza, bat, fd, ripgrep, fzf,
zoxide, atuin, btop, lazygit, delta, difftastic, yazi, mise, ... with zsh wrappers), a login status
screen and LazyVim for root and the primary user. Then it reboots into the finished system.

Three variants are published per release, differing in the CachyOS repo level the ISO *itself* is
built from (the installer always probes the target CPU and picks generic/v3/v4/znver4 for the
installed system):

| ISO | boots on | live kernel/userland |
|---|---|---|
| `archcloud-generic-*.iso` | any x86-64 | `[cachyos]` (generic x86-64 kernel) |
| `archcloud-v3-*.iso` | x86-64-v3 (AVX2) CPUs | `[cachyos-v3]` + generic |
| `archcloud-v4-*.iso` | x86-64-v4 (AVX-512) CPUs | `[cachyos-v4]` + generic |
| `archcloud-znver4-*.iso` | AMD Zen 4 / Zen 5 (AVX-512 incl. BF16) | `[cachyos-znver4]` + generic |

When in doubt use **generic**.

Zen 5 has no repo of its own (CachyOS publishes none); Zen 5 CPUs run the znver4 build.

Building a v3/v4/znver4 ISO needs a build host whose CPU can *execute* v3/v4 code: pacstrap runs the
installed packages' hooks inside the chroot. GitHub's runners all have AVX2 but only some have
AVX-512, so the CI v4 job skips itself (with a warning) when it lands on an unsuitable machine;
re-run that job (`gh run rerun <id> --job <job-id>`) or trigger the workflow with
`levels='["v4"]'` to try another runner. A release lists which variants it contains.

## Quick start

1. Download the ISO and `sha256sums` from the latest release; verify the checksum.
2. Attach the ISO to the VM (netcup: upload under "Media"; Proxmox: ISO storage; VMware/Hyper-V: CD
   drive). Hyper-V Gen2 and some VMware templates need **Secure Boot off** (archiso is unsigned).
3. Boot. The default menu entry starts the installer; `rescue shell` boots without installing.
4. Within a minute sshd is up with your baked key (`root@<dhcp address>`), and the console shows
   the plan + countdown in a tmux session. Press any key on the console, or run
   `archcloud-install abort` over SSH, to stop it.
5. The VM reboots into the installed system. Make sure the disk boots before the ISO (eject it or
   change the boot order). If the ISO boots again it **refuses** to reinstall over an existing
   archcloud disk unless `archcloud.force=yes` is given.

Login afterwards: `ssh <user>@<host>` with the same key; `sudo` needs no password; root's password is
locked. The first boot runs `arch-server-bootstrap-finish.service` once to finish steps that need a
live system (mirror ranking, LazyVim plugin sync); `sudo arch-server-bootstrap --status` shows the
step markers.

## Configuring an install

Defaults live in [`configs/archcloud/airootfs/etc/archcloud/install.conf`](configs/archcloud/airootfs/etc/archcloud/install.conf)
and can be overridden, highest priority first:

1. **Seed volume** — any disk/CD/USB labelled `ARCHCLOUD` (or `CIDATA`) containing
   `install.conf`, `authorized_keys` (extra keys for live root *and* the target user) and
   `network/*.network` (copied into the installed system, e.g. static IPv6). Build one with
   `tools/make-seed.sh -o seed.iso --hostname web1 --key ~/.ssh/id_ed25519.pub --set TIMEZONE=UTC`.
2. **Kernel command line** — edit the boot entry in the console: `archcloud.hostname=web1
   archcloud.disk=/dev/vdb archcloud.level=v3 archcloud.autoinstall=no archcloud.force=yes ...`
   (any `install.conf` key, lower-cased).
3. **The baked file** in the ISO.

| key | default | meaning |
|---|---|---|
| `HOSTNAME` | `arch-<4 hex>` | target hostname |
| `DISK` | `auto` | target disk; `auto` = the single largest non-removable disk, refuses when ambiguous |
| `USER` / `SSH_PUBKEY` | `darkspadez` / baked key | primary user (UID 1000, wheel, zsh) and its key(s) |
| `PASSWORD_HASH` | empty (locked) | crypt(3) hash for the user: `openssl passwd -6` / `mkpasswd -m sha-512` |
| `TIMEZONE` / `LOCALE` / `KEYMAP` | `America/New_York` / `en_US.UTF-8` / `us` | |
| `CACHYOS_LEVEL` | `auto` | repo level for the installed system: `auto\|generic\|v3\|v4\|znver4` |
| `KEEP_STOCK_KERNEL` | `true` | keep `linux` as a GRUB fallback next to `linux-cachyos-server` |
| `INSTALL_LAZYVIM` | `true` | LazyVim starter for root + user |
| `COUNTDOWN` / `REBOOT` / `AUTOINSTALL` / `FORCE` | `30` / `yes` / `yes` / `no` | installer behaviour |

Manual use from the rescue shell or over SSH: `archcloud-install --dry-run`, `archcloud-install
--disk /dev/vdb --hostname web1 --yes`, `archcloud-install status`.

## What the installer does

GPT: 1 MiB BIOS boot partition, 1 GiB ESP mounted at `/efi`, btrfs root (`@`, `@home`,
`@snapshots`, `@var_log`, `@pkg`; `compress=zstd:1,noatime`). `/boot` lives inside `@` so
snapshots include kernels. Hybrid GRUB for BIOS **and** UEFI, serial console enabled.
`pacstrap` from the CachyOS repos at the probed level (`linux-cachyos-server` + headers, stock
`linux` fallback, `linux-firmware`, guest agent for the detected hypervisor, snapper/grub-btrfs,
zram-generator, ...). systemd-networkd (DHCPv4 + IPv6 RA on `en*`/`eth*`) + systemd-resolved.
Then [`arch-server-bootstrap.sh`](configs/archcloud/airootfs/usr/local/lib/archcloud/arch-server-bootstrap.sh)
runs inside `arch-chroot` (chroot-aware patch of `refs/arch-server-bootstrap.sh`: services are
enabled but not started, `snapper --no-dbus`, SSH host keys generated before `sshd -t`, all tunables
from the environment), and a oneshot finisher re-runs it natively on first boot. The script stays on
the box as `/usr/local/sbin/arch-server-bootstrap` for later re-runs (`--status`, `--only ...`).

## Building

Requires Docker/Podman on any host, or root on Arch Linux:

```sh
./build.sh --level generic      # or --all; ISOs + sha256sums land in out/
```

`build.sh` re-executes itself in a privileged `archlinux:base-devel` container, runs
`tools/cachyos-host-setup.sh` (trusts the vendored CachyOS key in `keys/`, installs the CachyOS
keyring + mirrorlists), installs the packaged `archiso`, renders `configs/archcloud/pacman.conf`
from `pacman.conf.in` for the variant and runs `mkarchiso`. On Apple Silicon the amd64 container
runs under emulation: it works but takes a long time, and pacman's download sandbox is disabled
automatically.

CI (`.github/workflows/build.yml`) lints, builds the variants, smoke-boots every ISO under UEFI and
BIOS in QEMU (`tools/boot-test.sh`), runs a full unattended install + boot of the result + the
reinstall guard for the generic ISO (`tools/install-test.sh`), publishes releases on `v*` tags and
rebuilds nightly.

## Repository layout

```
build.sh                      container-aware build entry point
tools/                        cachyos-host-setup, make-seed, boot-test, install-test, lint
keys/cachyos-keyring.asc      CachyOS signing key (fpr 882DCFE48E2051D48E2562ABF3B607488DB35A47)
configs/archcloud/            the archiso profile
  profiledef.sh packages.x86_64 pacman.conf.in efiboot/ syslinux/ grub/
  airootfs/etc/archcloud/install.conf          baked defaults
  airootfs/usr/local/bin/archcloud-install     the installer
  airootfs/usr/local/bin/archcloud-seed        seed volume helper
  airootfs/usr/local/lib/archcloud/lib.sh      installer library
  airootfs/usr/local/lib/archcloud/arch-server-bootstrap.sh   patched bootstrap
  airootfs/usr/local/lib/archcloud/templates/  zshrc, modern-cli.zsh, gitconfig, login-status*, units
refs/                         upstream references (archiso, the original scripts); untouched
PLAN.md                       design + decisions log
```

## Rescue

Boot the ISO with the `rescue shell` entry (or `archcloud.autoinstall=no`), SSH in as root, then:

```sh
mount -o subvol=@ /dev/disk/by-label/archcloud /mnt
mount /dev/disk/by-partlabel/esp /mnt/efi    # plus @home etc. as needed
arch-chroot /mnt
```
