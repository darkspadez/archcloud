# installed by arch-server-bootstrap (archcloud) — status screen on interactive login.
# zsh reads this through /etc/zsh/zprofile -> /etc/profile. Skip per user: touch ~/.hushlogin
case $- in
  *i*)
    if [ -t 1 ] && [ -z "${LOGIN_STATUS_SHOWN:-}" ] && [ -z "${SUDO_USER:-}" ] &&
       [ ! -e "$HOME/.hushlogin" ] && [ -x /usr/local/bin/login-status ]; then
      LOGIN_STATUS_SHOWN=1; export LOGIN_STATUS_SHOWN
      /usr/local/bin/login-status
    fi
    ;;
esac
