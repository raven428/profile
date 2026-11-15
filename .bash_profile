#!/usr/bin/env bash
# cspell:ignore authsock scrrr
#shellcheck disable=1091
test -f /etc/bashrc && source /etc/bashrc

set_mux_env() {
  # stable SSH_AUTH_SOCK and DISPLAY from ~/.config/bash/ssh-agent-stable.sh
  if declare -F ssa_mux_env >/dev/null; then
    ssa_mux_env
  fi
}

scrrr() {
  set_mux_env
  /usr/bin/env screen -wipe
  /usr/bin/env screen -D -RR
  exit
}

tmx() {
  set_mux_env
  /usr/bin/env tmux -u new-session -AD -s "${USER}-0"
  exit
}

# disable history purging
export HISTSIZE=
export HISTFILESIZE=
# append to the history file, don't overwrite it
shopt -s histappend
# modifications of PROMPT_COMMAND:
PROMPT_COMMAND='true'
# write and read new history after each command
PROMPT_COMMAND+='; history -a'

# forcing ssh-dss keys support
/usr/bin/env ssh -Q key >/dev/null 2>&1
res=$?
/usr/bin/env mkdir -vp ~/.ssh
ssh_dir=${HOME}/.ssh
/usr/bin/env rm -f "${ssh_dir}/config"
if [[ "${res}" = "0" ]]; then
  /usr/bin/env ln -s "${ssh_dir}/config-new" "${ssh_dir}/config"
else
  /usr/bin/env ln -s "${ssh_dir}/config-old" "${ssh_dir}/config"
fi

#shellcheck disable=1090
/usr/bin/env test -f ~/.bash_profile_local && source ~/.bash_profile_local

# stable SSH_AUTH_SOCK and DISPLAY, sourced last to keep values set above
#shellcheck disable=1090
if [[ -r ~/.config/bash/ssh-agent-stable.sh ]]; then
  source ~/.config/bash/ssh-agent-stable.sh
fi
