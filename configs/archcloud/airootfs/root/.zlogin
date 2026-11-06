# archcloud: on the physical/serial console, attach to the installer's tmux
# session so the plan, countdown and progress are visible there. The getty may
# log in before archcloud-install.service has created the session, so wait a
# little for it; fall through to a normal shell when there is none.
# ~/.automated_script.sh keeps archiso's script=<url> hook working.
case "$(tty)" in
  /dev/tty1|/dev/ttyS0)
    if [[ -z "$TMUX" ]] && ! grep -q 'archcloud.autoinstall=no' /proc/cmdline; then
      for _i in {1..90}; do
        if tmux -L archcloud has-session -t archcloud 2>/dev/null; then
          exec tmux -L archcloud attach-session -t archcloud
        fi
        sleep 1
      done
      echo "[archcloud] no installer session appeared; see: systemctl status archcloud-install"
    fi
    ;;
esac
~/.automated_script.sh
