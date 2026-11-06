# Plan: `archcloud` — Arch/CachyOS unattended installer ISO for cloud VMs

**Status (2026-11-06): implemented and verified.** Repo: https://github.com/darkspadez/archcloud.
CI run for `8b46078` is green: lint, builds for generic/v3/v4 (~7 min each), QEMU smoke boots under UEFI
and BIOS for every variant, and the end-to-end unattended install (4m20s) + boot of the installed disk
under UEFI and BIOS + reinstall guard. Every bootstrap step is marked done after the first-boot finisher
(which took under a minute). Caveat: a v4 ISO can only be built on an AVX-512 runner; the CI job skips
itself otherwise and can be re-run.

## Goal

Build an archiso profile (`configs/archcloud/`) that produces an **installer appliance ISO**: boot it on a
KVM/Proxmox/VMware/Hyper-V VM, it brings up sshd with your key, counts down, wipes the target disk, and
installs a CachyOS-kernel Arch system whose end state is `arch-server-bootstrap.sh` (patched to run in
`arch-chroot`) plus the modern-CLI tooling from the Fedora/macOS scripts. Three ISO variants (generic, v3,
v4) are built and released by GitHub Actions and smoke/e2e tested in QEMU.

Acceptance criteria:
- When the ISO boots (UEFI or BIOS) on any of the four platform families, then within ~60 s sshd answers on
  the DHCP address with key-only root login, and tty1/ttyS0 show the installer countdown.
- When no key is pressed and `archcloud.autoinstall=no` is absent, then the installer partitions the chosen
  disk (GPT: BIOS-boot + ESP + btrfs), pacstraps from CachyOS repos at the probed CPU level, runs the
  bootstrap in chroot, and reboots into the installed system without manual input.
- When the installed system boots, then: hostname/user/key/timezone match the config, `uname -r` is
  `linux-cachyos-server`, stock `linux` is a GRUB fallback, root is on btrfs `@` with snapper configured,
  Docker/zram/BBR/ADIOS/sysctls from the bootstrap are active, the zsh wrappers + plugins, login-status
  screen and LazyVim exist for root and the user, and `arch-server-bootstrap --status` shows every step done
  (after the first-boot finisher).
- When the ISO is booted again against an already-installed disk, then it refuses to auto-install.
- When a tag `vYYYY.MM.N` is pushed, then the workflow publishes `archcloud-{generic,v3,v4}-*.iso` +
  `sha256sums` as release assets; nightly runs keep artifacts.

## Context

| Ref | Used for |
|---|---|
| `refs/archiso/` (upstream v92) | Reference only. `configs/releng` is the starting point for the profile; the build uses the **packaged** `archiso` so `mkarchiso` matches the `mkinitcpio-archiso` package it pacstraps. |
| `refs/arch-server-bootstrap.sh` | The installed system's end state. Copied into the profile, patched for chroot + generic naming + new steps. |
| `refs/fedora-cli-setup.sh` | Login-status screen (renderer, root collector, timer, profile.d hook) and the `run_step` fingerprint idea. Ported to pacman. |
| `refs/modern-cli-setup.zsh` | The `ALIASES` heredoc (zsh wrappers with escape hatches) and `GIT_SETTINGS`. Ported minus Homebrew/macOS parts. |

How archiso profiles customise the image (`refs/archiso/docs/README.profile.rst`, `archiso/mkarchiso`):
`profiledef.sh` (name/label/bootmodes/`file_permissions`/`kernel_params_x86_64`), `packages.x86_64`,
`pacman.conf` (build-time; `HookDir` forced to airootfs hooks), `airootfs/` overlay (mode/ownership **not**
preserved → `file_permissions`), `efiboot/`+`syslinux/`+`grub/` menus with `%ARCH%`/`%INSTALL_DIR%`/
`%ARCHISO_UUID%`/`%KERNEL_PARAMS%` substitution. Services are enabled by symlinks under
`airootfs/etc/systemd/system/*.wants/`. `customize_airootfs.sh` is deprecated (mkarchiso:423) → not used.

## Decisions (from 8 grilling rounds)

1. Purpose: installer only; minimal live env (rescue kit kept, `linux-firmware` kept).
2. Platforms: netcup/generic KVM, Proxmox/libvirt, VMware, Hyper-V. **Hetzner dropped** (no custom ISO).
3. Live access: baked SSH public key (from bootstrap tunables), key-only, `PermitRootLogin prohibit-password`,
   root password locked, tty1 + ttyS0 autologin for provider consoles. The baked key lives in
   `/etc/ssh/authorized_keys.d/root` (sshd `AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u .ssh/authorized_keys`);
   seed keys are merged into `/root/.ssh/authorized_keys` at boot by `archcloud-seed.service`.
4. CachyOS in the ISO. Kernel `linux-cachyos-server`. **Corrected during implementation:** the v3/v4/znver4
   repos (`repo/x86_64_v3/cachyos-v3`, `repo/x86_64_v4/cachyos-v4`, `.../cachyos-znver4`) *do* carry the
   kernels, tagged `x86_64_v3`/`x86_64_v4`; the generic `[cachyos]` kernel is built with `CONFIG_GENERIC_CPU=y`,
   `X86_64_VERSION=1` (true baseline x86-64). Variants therefore differ in kernel *and* userland, and the
   rendered `pacman.conf` lists `Architecture = x86_64 x86_64_v3[ x86_64_v4]` explicitly (stock pacman accepts
   the list; CachyOS' patched pacman is not needed on the build host). Installer always probes the target CPU.
5. Trigger: auto on boot, ~30 s countdown, any key / `archcloud-install abort` / Ctrl-C aborts; second boot
   entry "Rescue shell" (`archcloud.autoinstall=no`); sshd is up first.
6. Implementation: custom bash installer (pacstrap) + patched bootstrap **inside arch-chroot**, plus a oneshot
   first-boot finisher that re-runs the idempotent bootstrap once natively (markers skip done steps).
7. Disk: GPT, 1 MiB BIOS-boot (EF02) + 1 GiB ESP (EF00) at `/efi` + btrfs (`@` `@home` `@snapshots`
   `@var_log` `@pkg`; `compress=zstd:1,noatime,space_cache=v2`); `/boot` inside `@`. Hybrid GRUB
   (`i386-pc` + `x86_64-efi --removable`, plus NVRAM entry when booted UEFI). No swap partition (zram).
8. Config: baked `/etc/archcloud/install.conf` < kernel cmdline `archcloud.*` < seed volume labelled
   `ARCHCLOUD` (or `CIDATA`) with `install.conf`, `authorized_keys`, `network/*.network`.
9. Passwords: user hash from seed/cmdline (`password_hash`), empty → locked; root always locked.
10. Target network: systemd-networkd + resolved, DHCPv4 + IPv6 RA on `en*`/`eth*`; seed overrides. No cloud-init.
11. Target tools (all in `extra`): eza fd bat zoxide duf dust yazi(+ffmpeg 7zip poppler imagemagick resvg)
    ripgrep jq go-yq sd choose jaq fx ugrep btop fastfetch procs hyperfine tokei smartmontools nvme-cli doggo
    mtr gping trippy iperf3 nmap tcpdump bandwhich xh rustscan lazygit git-delta difftastic lazydocker ctop
    dive go nodejs npm tree-sitter-cli python-pynvim fzf atuin tealdeer zsh-autosuggestions
    zsh-syntax-highlighting zsh-completions fkill mise direnv uv chezmoi age sops neovim zsh.
    **Removed:** glances. **AUR-only, excluded:** xcp viddy scc hadolint carapace fzf-tab topgrade.
12. Target shell: all modern-cli wrappers **except rm→trash**, for root and the user; zsh plugins; Pure
    prompt; delta/difftastic in `/etc/gitconfig`; login-status screen; LazyVim for root + user.
13. Build/CI: GitHub Actions (tag → release, nightly cron, PR → build generic) in a privileged
    `archlinux:base-devel` container; smoke boot (UEFI+BIOS, all variants) + full install e2e (generic) in
    QEMU with `/dev/kvm`. `build.sh` works locally in Docker as a by-product.
14. Repo: `git init` here; **public GitHub repo created with `gh` during implementation (confirm again
    right before)**. Packaged `archiso` in the container; `refs/` stays as reference.
15. Defaults: hostname `arch-<4 hex of machine-id>`, user `darkspadez`, tz `America/New_York`,
    locale `en_US.UTF-8`, keymap `us`, `disk=auto` (largest non-removable non-ISO disk; refuse if ambiguous),
    keep stock `linux` as fallback kernel. Naming prefix **`archcloud`**, nothing "qops".

## Approach

**Profile.** `configs/archcloud/` starts as a copy of `releng` with hardware-only payload removed
(wifi/iwd, ModemManager, sound, brltty, memtest, clonezilla, archinstall, VPN clients, VirtualBox). The
build-time `pacman.conf` is rendered from `pacman.conf.in` per variant (`[cachyos-v3]`+`[cachyos-core-v3]`+
`[cachyos-extra-v3]` or the v4 set, then `[cachyos]`, then `[core]`/`[extra]`). The live system's own
`airootfs/etc/pacman.conf` carries generic `[cachyos]` + core/extra. `pacman-init.service` (unchanged)
populates every keyring under `/usr/share/pacman/keyrings`, which includes `cachyos` because
`cachyos-keyring` is in the package list. Kernel params add `console=tty0 console=ttyS0,115200n8` so
provider serial consoles work; syslinux gets `SERIAL 0 115200`. Two boot entries: *Install* (default) and
*Rescue shell* (`archcloud.autoinstall=no`).

**Live environment.** sshd enabled via wants-symlink with a drop-in replacing releng's `10-archiso.conf`
(`PasswordAuthentication no`, `KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`).
`/root/.ssh/authorized_keys` baked; `/etc/shadow` has root locked (`root:!:…`). Guest agents enabled:
`qemu-guest-agent`, `vmtoolsd`, `hv_{kvp,vss,fcopy}_daemon` (their `ConditionVirtualization` makes them
no-ops elsewhere). `archcloud-seed.service` (before sshd) mounts the seed volume if present and applies
`authorized_keys` and `hostname` to the live env, so CI can inject an ephemeral key.
`archcloud-install.service` (`After=network-online.target sshd.service`,
`ConditionKernelCommandLine=!archcloud.autoinstall=no`) runs the installer inside a `tmux` session named
`archcloud`; root's `.zlogin` on tty1/ttyS0 attaches to that session when it exists (replacing releng's
`.automated_script.sh` call; the `script=` hook is kept for ad-hoc use). SSH users run
`tmux attach -t archcloud` or `archcloud-install abort`.

**Installer `archcloud-install`** (bash, `set -Eeuo pipefail`, logs to `/run/archcloud/install.log` and
copies it to `/var/log/archcloud-install.log` on the target). Phases:
1. *config* — defaults from `/etc/archcloud/install.conf`; `archcloud.<key>=` from `/proc/cmdline`; seed by
   label (`blkid -L ARCHCLOUD` / `CIDATA`) mounted read-only. Keys: `hostname disk fs_label user
   password_hash ssh_pubkey timezone locale keymap cachyos_level(auto|generic|v3|v4|znver4) autoinstall
   reboot keep_stock_kernel install_lazyvim`.
2. *preflight* — root, network (`curl -fsI https://archlinux.org`), firmware (`/sys/firmware/efi`),
   virtualisation (`systemd-detect-virt`), disk selection (`lsblk -dnpo NAME,TYPE,RM,SIZE,TRAN`, exclude the
   archiso device and removable; auto = largest, refuse if >1 candidate without `disk=`), **re-install guard**
   (refuse auto mode if any candidate carries btrfs label `archcloud` or GPT partlabel `archcloud-root`
   unless `archcloud.force=yes`), CPU level probe (`/lib/ld-linux-x86-64.so.2 --help` for v3/v4; znver4 via
   `/proc/cpuinfo` family 0x19/0x1a — same outcome as the bootstrap's `gcc -march=native` probe without gcc
   on the ISO).
3. *countdown* — prints the plan (disk, size, hostname, user, key fingerprint, level, firmware) and counts
   down 30 s; abort on keypress, `/run/archcloud/abort`, or SIGINT.
4. *partition/format* — `sgdisk --zap-all`, EF02 1M, EF00 1G, 8300 rest (partlabel `archcloud-root`);
   `mkfs.fat -F32 -n ESP`; `mkfs.btrfs -f -L archcloud`; subvolumes; mounts under `/mnt` (ESP at `/mnt/efi`).
5. *pacstrap* — target `pacman.conf` rendered with the probed level (same shape as the CachyOS
   `install-*-repo.awk` output); `pacstrap -C /run/archcloud/pacman.conf /mnt <pkgs>` **without `-K`** so the
   live ISO's populated keyring (archlinux + cachyos) is copied (pacstrap `-K` only runs `pacman-key --init`,
   no populate — verified in `pacstrap.in`). Package set: `base base-devel linux-cachyos-server
   linux-cachyos-server-headers linux linux-firmware btrfs-progs grub efibootmgr dosfstools mkinitcpio sudo
   openssh zsh git curl jq tmux cachyos-settings cachyos-keyring cachyos-mirrorlist cachyos-v3-mirrorlist
   cachyos-v4-mirrorlist cachyos-rate-mirrors pacman-contrib` + ucode by CPU vendor + guest agent by
   `systemd-detect-virt`. The tool list stays in the bootstrap (single source of the end state).
6. *configure* — `genfstab -U`; hostname + `/etc/hosts`; `locale.gen`/`locale.conf`/`vconsole.conf`;
   timezone symlink + `hwclock --systohc`; copy `20-wired.network` + seed `network/*`; `resolv.conf` stub
   symlink; `systemctl --root=/mnt enable systemd-networkd systemd-resolved systemd-timesyncd sshd` + agent;
   `/etc/mkinitcpio.conf.d/archcloud.conf` with `MODULES+=(virtio_blk virtio_scsi virtio_pci virtio_net
   vmw_pvscsi vmxnet3 hv_vmbus hv_storvsc hv_netvsc)` (portable across hypervisors); `/etc/default/grub`
   (`GRUB_CMDLINE_LINUX_DEFAULT` with the console params, `GRUB_TERMINAL="console serial"`,
   `GRUB_SERIAL_COMMAND`, `GRUB_DISABLE_OS_PROBER=true`, `GRUB_TIMEOUT=3`); `grub-install` for `i386-pc` and
   `x86_64-efi --efi-directory=/efi --removable` (+ non-removable with NVRAM when booted UEFI); `passwd -R
   /mnt -l root`; `arch-chroot /mnt ssh-keygen -A`.
7. *bootstrap in chroot* — install the patched script to `/mnt/usr/local/sbin/arch-server-bootstrap` and
   its templates to `/mnt/usr/local/lib/arch-server-bootstrap/`; run
   `arch-chroot /mnt env ARCHCLOUD_CHROOT=1 CREATE_USER=… SSH_PUBKEY=… PASSWORD_HASH=… HOSTNAME=…
   KEEP_STOCK_KERNEL=… arch-server-bootstrap --unattended`. Its `cachyos_repo`/`kernel`/`upgrade` steps see
   repos active and packages present and mark done; `grub_default` runs `grub-mkconfig` + pins
   `linux-cachyos-server`.
8. *finish* — enable `arch-server-bootstrap-finish.service` (oneshot, `After=network-online.target`,
   `ConditionPathExists=!/var/lib/arch-server-bootstrap/.finished`; runs the script natively once, LazyVim
   headless sync as each user, writes `.finished`, disables itself); copy log; `umount -R /mnt`; reboot
   unless `reboot=no`.

**Patched bootstrap (`arch-server-bootstrap.sh` → profile copy).** Changes, each small and reviewable:
- Tunables become `${VAR:-default}`; new `PASSWORD_HASH`, `--unattended` (no prompts; `useradd -p`).
- `in_chroot()` = `ARCHCLOUD_CHROOT=1` or `systemd-detect-virt -r -q`; in chroot: `snapper --no-dbus`, skip
  `mount -o remount`, skip `cachyos-rate-mirrors` (left unmarked → finisher runs it), `hostnamectl` fallback
  already exists.
- `ssh-keygen -A` before `sshd -t` (otherwise the key-only drop-in is silently removed).
- Generic names: state `/var/lib/arch-server-bootstrap`, `/etc/sudoers.d/10-wheel`,
  `99-bbr.conf`, `61-adios.rules`, `adios-scheduler.service`, journald/zram files unchanged.
- `glances` step removed; `qol_tools` list replaced by decision 11; `informant` from `extra` (no Shelly
  fallback); `shelly` step kept.
- New steps/groups: `guest_agents` (enable per `systemd-detect-virt`), `modern_cli` (installs
  `/etc/zsh/modern-cli.zsh` + the merged `/etc/zsh/zshrc`, `/etc/gitconfig`), `login_status` (renderer,
  collector, timer, `profile.d` hook, `/etc/login-status.conf`), `lazyvim` (clone starter for root and UID
  1000 when absent; `Lazy! sync` only when not in chroot), and `--list-groups` updated.
- `zsh_config` writes the merged zshrc: terminfo fallback, Go PATH, Pure, then sources `modern-cli.zsh`.

**Ported templates** (`airootfs/usr/local/lib/archcloud/templates/`, installed by the bootstrap so re-runs
converge):
- `modern-cli.zsh`: the `ALIASES` heredoc with Homebrew paths → `/usr/share/zsh/plugins/...`,
  `/usr/share/zsh/site-functions`, `fzf --zsh`; drop trash/broot/herdr/carapace/fzf-tab/viddy/xcp blocks;
  keep every wrapper's option-detection fallback and `MODERN_CLI_*` toggles; `watch` alias dropped.
- `gitconfig`: `GIT_SETTINGS` as a system config.
- `login-status` / `login-status-collect`: `dnf check-upgrade` → `checkupdates` (exit 2 = none);
  reboot-needed = `/usr/lib/modules/$(uname -r)` missing; `hostname -s` → `/etc/hostname`; rows for
  docker/failed units/SSH fails/crowdsec/netbird kept conditional.
- `20-wired.network`, `mkinitcpio-archcloud.conf`, `default-grub`, `arch-server-bootstrap-finish.service`,
  `install.conf` (defaults).

**Build & CI.** `build.sh [--level generic|v3|v4] [--all]`: if not on Arch, re-execs in
`docker run --privileged -v "$PWD":/work archlinux:base-devel`; inside: `pacman -Syu archiso`,
`tools/cachyos-host-setup.sh` (adds the vendored CachyOS public key `keys/cachyos-F3B607488DB35A47.asc`
with `pacman-key --add/--lsign-key`, resolves `cachyos-keyring`/mirrorlist/`pacman` filenames from
`cachyos.db` like the bootstrap does, `pacman -U`, `pacman-key --populate cachyos`), renders
`pacman.conf`, runs `mkarchiso -v -m iso -w work/<level> -o out configs/archcloud`, writes `out/sha256sums`.
Workflow `.github/workflows/build.yml`: `build` matrix (3 levels, privileged container, artifacts);
`smoke` (ubuntu runner, `qemu-system-x86 ovmf`, `/dev/kvm`, `tools/boot-test.sh` UEFI+BIOS with a seed
carrying an ephemeral key, asserts `ssh root@localhost -p 2222 archcloud-install --version`); `e2e`
(generic only, `tools/install-test.sh`: blank 20 GiB qcow2 + seed `autoinstall=yes hostname=citest
password_hash=…`, QEMU `-no-reboot`, then boot the disk under UEFI and BIOS and assert hostname, btrfs
subvols, `uname -r`, `systemctl is-active sshd docker`, `arch-server-bootstrap --status` all done);
`release` on tags with `softprops/action-gh-release`; `schedule` nightly; `concurrency` per ref.

Rejected: archinstall (less control of CachyOS repos/btrfs layout, config format churn); first-boot-only
bootstrap (user wants the machine finished before reboot); cloud-init on target (second source of truth);
vendored `mkarchiso` (version drift vs `mkinitcpio-archiso`); keyserver fetch of the CachyOS key in CI
(flaky → vendored key).

## Files to create / modify

```
.gitignore  README.md  build.sh  keys/cachyos-F3B607488DB35A47.asc
.github/workflows/build.yml
tools/cachyos-host-setup.sh  tools/make-seed.sh  tools/boot-test.sh  tools/install-test.sh
configs/archcloud/
  profiledef.sh  packages.x86_64  pacman.conf.in  (pacman.conf generated, gitignored)
  efiboot/loader/loader.conf  efiboot/loader/entries/{01-archcloud-install,02-archcloud-rescue}.conf
  syslinux/*.cfg (from releng, 2 entries, SERIAL)  grub/{grub.cfg,loopback.cfg}
  airootfs/etc/{hostname,locale.conf,motd,passwd,shadow,pacman.conf,localtime,resolv.conf}
  airootfs/etc/archcloud/install.conf
  airootfs/etc/ssh/sshd_config.d/10-archcloud.conf
  airootfs/etc/mkinitcpio.conf.d/archiso.conf
  airootfs/etc/systemd/{journald.conf.d,logind.conf.d,network/20-ethernet.network,networkd.conf.d,resolved.conf.d}
  airootfs/etc/systemd/system/{pacman-init,choose-mirror,archcloud-seed,archcloud-install}.service
  airootfs/etc/systemd/system/{getty@tty1,serial-getty@ttyS0}.service.d/autologin.conf
  airootfs/etc/systemd/system/multi-user.target.wants/{sshd,systemd-networkd,systemd-resolved,qemu-guest-agent,vmtoolsd,hv_*,archcloud-seed,archcloud-install,pacman-init,choose-mirror}.service (symlinks)
  airootfs/etc/pacman.d/hooks/{uncomment-mirrors,zzzz99-remove-custom-hooks-from-airootfs}.hook
  airootfs/root/{.zlogin,.ssh/authorized_keys,.automated_script.sh}
  airootfs/usr/local/bin/{archcloud-install,choose-mirror}
  airootfs/usr/local/lib/archcloud/{lib.sh,arch-server-bootstrap.sh,templates/...}
```
`refs/` is untouched.

## Reuse

- `refs/archiso/configs/releng/*` — profile skeleton, `pacman-init.service`, `choose-mirror`, network
  files, autologin drop-in, hooks, syslinux/efiboot templates, `.automated_script.sh` (`script=` hook).
- `refs/archiso/scripts/run_archiso.sh` — QEMU invocation reference (`-c` for a seed ISO) for `tools/boot-test.sh`.
- `refs/archiso/.gitlab/ci/build_archiso.sh` — CI build reference (deps list, metrics).
- `refs/arch-server-bootstrap.sh` — whole script (patched copy); `cachyos_repo` step's `cachyos.db` index
  logic reused in `tools/cachyos-host-setup.sh`; `configure_wheel_sudo`; `grub_default` pinning.
- `refs/fedora-cli-setup.sh` — `write_login_status_renderer/collector/units/hook/conf`, `write_alias_file`
  structure, `run_as`.
- `refs/modern-cli-setup.zsh` — `ALIASES` heredoc, `GIT_SETTINGS`, verify-in-fresh-shell snippet (for the
  bootstrap's `modern_cli` step self-check).

## Steps

All nine steps below are done (see the status line at the top and the implementation notes at the end).

Plan:
1. **Scaffold repo + profile skeleton** — `git init`, `.gitignore` (`work/ out/ *.iso configs/*/pacman.conf`),
   `README.md`, copy `refs/archiso/configs/releng` → `configs/archcloud`, strip hardware-only files/symlinks
   (iwd, ModemManager, cloud-init wants, livecd-*, vbox, pcscd, brltty, wlan/wwan networks).
   Check: `tree configs/archcloud`, `shellcheck` passes on copied scripts.
2. **Profile definition** — `profiledef.sh` (`iso_name="archcloud-${ARCHCLOUD_LEVEL:-generic}"`,
   `kernel_params_x86_64` console args, `file_permissions` for `/root/.ssh`, installer binaries, `/etc/shadow`),
   `packages.x86_64` (decision 1 list + `linux-cachyos-server` + cachyos keyring/mirrorlists + tmux),
   `pacman.conf.in`, boot entries (install/rescue), syslinux `SERIAL`.
   Check: `./build.sh --level generic` inside Docker builds `out/archcloud-generic-*.iso`.
3. **Build tooling** — `build.sh`, `tools/cachyos-host-setup.sh`, `keys/cachyos-*.asc` (exported from the
   `cachyos-keyring` package; fingerprint recorded in README), `pacman.conf` rendering per level.
   Check: generic + v3 builds succeed; `sha256sums` written; v3 build's package DB lists `cachyos-v3` packages.
4. **Live environment config** — sshd drop-in, baked `authorized_keys`, locked root, hostname/motd,
   wants-symlinks for sshd/networkd/resolved/timesyncd/agents, tty1 + ttyS0 autologin, journald volatile,
   `archcloud-seed.service`, live `/etc/pacman.conf`.
   Check: `tools/boot-test.sh` boots the ISO (UEFI and BIOS) under QEMU with `-serial`, seed key logs in over
   SSH, `systemctl --failed` is empty, `pacman-key --list-keys` shows CachyOS.
5. **Patched bootstrap** — copy `refs/arch-server-bootstrap.sh` to
   `airootfs/usr/local/lib/archcloud/arch-server-bootstrap.sh` and apply the patch list above (env tunables,
   `--unattended`, chroot awareness, `ssh-keygen -A`, generic names, tool list, remove glances, new steps).
   Check: `shellcheck`, `bash -n`, `--list-groups`/`--status` run in a container; diff against `refs/` is
   limited to the described hunks.
6. **Templates** — `modern-cli.zsh`, merged `zshrc`, `gitconfig`, `login-status*` (pacman port), units,
   `20-wired.network`, `mkinitcpio-archcloud.conf`, `default-grub`, finisher unit, `install.conf`.
   Check: `zsh -n` on zsh files, `shellcheck` on bash, `systemd-analyze verify` on units inside the container,
   a throwaway Arch container runs `bootstrap --only modern_cli,login_status` and a fresh `zsh -i` reports the
   wrappers active (verify snippet from the macOS script).
7. **Installer** — `archcloud-install` + `lib.sh` (phases 1–8), `archcloud-install.service` (tmux), `.zlogin`
   attach, `abort`/`--version`/`--dry-run`/`--no-reboot`, re-install guard.
   Check: `--dry-run` in the live env prints the plan without touching disks; `tools/install-test.sh` passes
   locally or in CI (step 9).
8. **Seed + test tools** — `tools/make-seed.sh` (FAT image or ISO labelled `ARCHCLOUD` from a directory),
   `tools/boot-test.sh`, `tools/install-test.sh` (QEMU, `-no-reboot`, SSH asserts).
   Check: `make-seed.sh` output is detected by `blkid -L ARCHCLOUD` in the live env; both test scripts exit 0
   against a locally built ISO.
9. **GitHub repo + workflow + README** — confirm, then `gh repo create <name> --public --source . --push`;
   `.github/workflows/build.yml` (build matrix → smoke → e2e → release; nightly cron); README with provider
   notes (netcup boot order, Proxmox OVMF, VMware firmware, Hyper-V Gen2 Secure Boot off) and seed/cmdline docs.
   Check: push tag `v2026.11.0`; workflow green; release holds 3 ISOs + sums; one ISO booted manually on
   Proxmox or netcup installs end-to-end and `arch-server-bootstrap --status` is all `[x]` after first boot.

## Verification

- Static: `shellcheck -s bash` on every bash script; `zsh -n` on zsh; `systemd-analyze verify` on units.
- Build: `./build.sh --all` (Docker locally or CI) → three ISOs, sizes recorded in `out/metrics.txt`.
- Boot smoke (per variant, UEFI + BIOS): sshd reachable with the seed key, `archcloud-install --version`,
  `systemctl --failed` empty, serial console shows the countdown.
- Install e2e (generic): blank disk + seed → unattended install → VM exits → disk boots under UEFI and BIOS →
  asserts: hostname, `findmnt -t btrfs` subvols, `uname -r` contains `cachyos`, GRUB has a `linux` fallback
  entry, `systemctl is-active sshd docker systemd-networkd`, zram active, `sysctl net.ipv4.tcp_congestion_control`
  = bbr, user has NOPASSWD sudo and the key, root locked, `arch-server-bootstrap --status` all done after the
  finisher, `login-status` renders, `nvim --headless +q` exits 0 for the user.
- Guard: boot the ISO again against the installed disk → installer refuses auto mode and drops to the shell.
- Manual: one real install on netcup/Proxmox from the release ISO.

## Risks

- **CachyOS kernel CPU baseline.** Resolved: the generic `[cachyos]` kernel's `.config` has
  `CONFIG_GENERIC_CPU=y` / `CONFIG_X86_64_VERSION=1`, so the generic ISO boots on any x86-64 CPU; the v3/v4
  ISOs ship v3/v4-tagged kernels and userland and need a matching CPU.
- **Privileged container in GitHub Actions.** `mkarchiso`/`pacstrap` need mount namespaces; `container:
  options: --privileged` is required. Fallback: run the build on the runner host after `pacman`-bootstrapping
  via the `archlinux` container with `docker run --privileged` directly. Handled in step 3/9.
- **`/dev/kvm` on runners.** Available on standard Linux runners; the workflow `chmod 666 /dev/kvm` and falls
  back to TCG (slow) only for the smoke job.
- **Reboot loop with the ISO still attached.** The re-install guard refuses auto mode on an already-installed
  disk; README tells users to fix boot order/eject. Handled.
- **Unattended wipe of the wrong disk.** `disk=auto` refuses when ambiguous; countdown prints the device; CI
  e2e covers the single-disk path only. Residual risk accepted by decision 5.
- **CachyOS mirror/keyring availability during nightly builds.** Vendored key removes the keyserver dependency;
  mirror outages fail the nightly loudly (no release). Accepted.
- **`snapper --no-dbus` in chroot + `/.snapshots` pre-mounted** — the installer mounts `@snapshots` before the
  chroot so the bootstrap's "Case A" path runs; e2e asserts the snapper config exists. Handled.
- **Secure Boot.** archiso is unsigned; Hyper-V Gen2 and some VMware templates need Secure Boot off. Documented.
- **Hyper-V Gen1 vs Gen2** both covered by hybrid boot; Hyper-V serial is a named pipe (console params harmless).
- **Size/time.** Three variants with `linux-firmware` ≈ 1.3–1.6 GB each; CI ~30 min build + ~20 min tests.
  Accepted.

## Out of scope

Hetzner Cloud (no custom ISO), netboot/kexec artifacts, aarch64, cloud-init on the target, Secure Boot
signing, AUR packages (fzf-tab, carapace, topgrade, viddy, scc, hadolint, xcp) and any custom package repo,
flow/sshs (bootstrap option stays off), interactive TUI installer, multi-disk/RAID/LUKS layouts, rm→trash,
pueue, modifying `refs/`.

## Open questions

- Repo name for `gh repo create` (default proposal: `archcloud`); I will ask once more right before creating it.

## Implementation notes (2026-11-06)

- `pacstrap -K` only runs `pacman-key --init` in the target (verified in `pacstrap.in`); the installer
  therefore calls `pacstrap` without `-K` so the live ISO's populated keyring (archlinux + cachyos, via
  `pacman-init.service`) is copied into the target.
- Local builds on Apple Silicon run the amd64 container under emulation; pacman's download sandbox fails
  there (`error restricting syscalls via seccomp`), so `tools/cachyos-host-setup.sh` probes with a real
  `pacman -Sy` and sets `DisableSandbox` on the build host + in the rendered profile `pacman.conf`.
  mkarchiso's work dir is a Docker named volume because a macOS bind mount cannot hold capability xattrs.
- The first local build of `archcloud-generic` succeeded (1.0 GB ISO) before any QEMU test; boot and
  install tests run in CI (`tools/boot-test.sh`, `tools/install-test.sh`).
- Found by CI and fixed: `hostname` binary absent (inetutils added); systemd 262's `systemd-loop@` fails
  on the El Torito boot medium (masked in the live env only — the udev rule targets the *boot* disk, so
  installed systems are unaffected); the serial getty can log in before the installer's tmux session
  exists (login hook now waits; the installer writes `ARCHCLOUD_INSTALL_OK/FAILED` to `/dev/console`
  so harnesses do not depend on tmux-rendered text); v3/v4 package hooks execute v3/v4 binaries during
  pacstrap, so such variants need a capable build host (`build.sh` refuses otherwise, CI skips per
  runner); some GitHub runners hold the dpkg lock for 20+ minutes at boot (killed before apt).
- The CachyOS v4 mirror at cdn77 returned 404 for a few `x86_64_v4` packages during one install;
  pacman fell back to other mirrors automatically (the installer ranks mirrors first, bounded to 4 min).
