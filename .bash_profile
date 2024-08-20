#
# $Id: .bash_profile,v 1.18 2023/10/03 05:56:03 raven Exp $
#

# load defaults
test -f /etc/bashrc && source /etc/bashrc

set_mux_env() {
 if [[
  -n "${SSH_AUTH_SOCK}" &&
  -e "${SSH_AUTH_SOCK}"
 ]]; then
  SSH_AUTH_SOCK_REAL="$(readlink -f ${SSH_AUTH_SOCK})"
  if [[ -S "${SSH_AUTH_SOCK_REAL}" ]]; then
   SSH_AUTH_SOCK_NEW="${HOME}/.ssh/authsock-${HOSTNAME%%.*}"
   /usr/bin/env rm -f "${SSH_AUTH_SOCK_NEW}"
   /usr/bin/env ln -sf "${SSH_AUTH_SOCK_REAL}" "${SSH_AUTH_SOCK_NEW}"
   export SSH_AUTH_SOCK="${SSH_AUTH_SOCK_NEW}"
  fi
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
 /usr/bin/env tmux new-session -AD -s ${USER}-0
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
/usr/bin/env rm -f ${ssh_dir}/config
if [[ "x$res" = "x0" ]]; then
 /usr/bin/env ln -s ${ssh_dir}/config-new ${ssh_dir}/config
else
 /usr/bin/env ln -s ${ssh_dir}/config-old ${ssh_dir}/config
fi

# load local
/usr/bin/env test -f ~/.bash_profile_local && source ~/.bash_profile_local
