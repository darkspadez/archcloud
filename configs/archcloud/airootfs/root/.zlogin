# archcloud: on the physical/serial console, attach to the installer's tmux
# session when it exists; otherwise fall through to a normal shell.
# ~/.automated_script.sh keeps archiso's script=<url> hook working.
case "$(tty)" in
  /dev/tty1|/dev/ttyS0)
    if [[ -z "$TMUX" ]] && tmux -L archcloud has-session -t archcloud 2>/dev/null; then
      exec tmux -L archcloud attach-session -t archcloud
    fi
    ;;
esac
~/.automated_script.sh
