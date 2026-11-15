#!/usr/bin/env bash
# cspell:ignore authsock ssa
# Stable SSH_AUTH_SOCK and DISPLAY for VS Code terminals and tmux/screen panes.
# Sourced by ~/.bashrc and ~/.bash_profile, executed by ~/.ssh/rc with --publish.
# SSH_AGENT_STABLE=off disables both the export and the publication.
ssa_host() {
  local host=${HOSTNAME%%.*}
  [[ ${host} =~ ^[A-Za-z0-9_-]+$ ]] || return 1
  printf '%s\n' "${host}"
}
ssa_agent_alive() {
  # ssh-add -l: 0 lists keys, 1 with the exact message is an empty but alive agent
  local out rc=0
  [[ -S ${1} ]] || return 1
  out=$(SSH_AUTH_SOCK=${1} command timeout -k 1 2 ssh-add -l 2>/dev/null) || rc=$?
  [[ ${rc} -eq 0 || (${rc} -eq 1 && ${out} == 'The agent has no identities.') ]]
}
ssa_display_valid() {
  [[ ${1} =~ ^[A-Za-z0-9._-]*:[0-9]{1,4}(\.[0-9]+)?$ ]]
}
ssa_display_alive() {
  # sshd X11 forwarding listens on TCP port 6000+N of the display host
  # shellcheck disable=SC2016
  local host port probe='exec 3<>"/dev/tcp/${1}/${2}"'
  [[ ${1} =~ ^([A-Za-z0-9._-]*):([0-9]{1,4})(\.[0-9]+)?$ ]] || return 1
  host=${BASH_REMATCH[1]}
  [[ ${host} != 'unix' ]] || return 1
  port=$((6000 + 10#${BASH_REMATCH[2]}))
  if [[ -z ${host} || ${host} == 'localhost' ]]; then # DevSkim: ignore DS162092
    host='127.0.0.1'                                  # DevSkim: ignore DS162092
  fi
  command timeout -k 1 1 "${BASH}" -c "${probe}" _ "${host}" "${port}" 2>/dev/null
}
ssa_initial() {
  # value of variable $1 in the initial environment of this shell process
  local entry
  [[ -r /proc/$$/environ ]] || return 2
  while IFS= read -r -d '' entry; do
    if [[ ${entry} == "${1}="* ]]; then
      printf '%s\n' "${entry#*=}"
      return 0
    fi
  done </proc/$$/environ
  return 1
}
ssa_untouched() {
  # variable $1 is empty or still equals the value inherited by this shell
  local initial
  [[ -n ${!1-} ]] || return 0
  initial=$(ssa_initial "${1}") || return 1
  [[ ${!1} == "${initial}" ]]
}
ssa_display_read() {
  local host file value
  host=$(ssa_host) || return 1
  file=${HOME}/.ssh/display-${host}
  [[ -f ${file} && ! -L ${file} ]] || return 1
  IFS= read -r value <"${file}" || return 1
  ssa_display_valid "${value}" || return 1
  printf '%s\n' "${value}"
}
ssa_target() {
  # canonical live agent socket behind $1, never the link $2 or a local ssh-agent
  local real local_agent='/ssh-[A-Za-z0-9]{12}/agent\.[0-9]+$'
  real=$(command readlink -e -- "${1}") || return 1
  [[ ${real} != "${2}" && -S ${real} && -O ${real} ]] || return 1
  [[ ! ${real} =~ ${local_agent} ]] || return 1
  ssa_agent_alive "${real}" || return 1
  printf '%s\n' "${real}"
}
ssa_link_alive() {
  # the stable link $1 is publishable: live user socket, not a local ssh-agent
  ssa_target "${1}" "${1}" >/dev/null
}
ssa_publish() (
  # $1: agent socket for the stable link, $2: display for the display file
  local host link file real tmp fd rc=0
  [[ ${SSH_AGENT_STABLE-} != 'off' ]] || return 1
  host=$(ssa_host) || return 1
  link=${HOME}/.ssh/authsock-${host}
  file=${HOME}/.ssh/display-${host}
  [[ -d ${HOME}/.ssh && -O ${HOME}/.ssh && ! -L ${HOME}/.ssh ]] || return 1
  [[ ! -L ${link}.lock ]] || return 1
  umask 077
  exec {fd}>>"${link}.lock" || return 1
  command flock -w 3 "${fd}" || return 1
  tmp=$(command mktemp -d -- "${HOME}/.ssh/.authsock.XXXXXXXX") || return 1
  trap 'command rm -rf -- "${tmp}"' EXIT
  trap 'exit 1' HUP INT TERM
  if [[ -n ${1} ]]; then
    if [[ -L ${link} || ! -e ${link} ]] && real=$(ssa_target "${1}" "${link}"); then
      if command ln -s -- "${real}" "${tmp}/link"; then
        command mv -Tf -- "${tmp}/link" "${link}" || rc=1
      else
        rc=1
      fi
    else
      rc=1
    fi
  fi
  if [[ -n ${2} ]]; then
    if ssa_display_valid "${2}" && [[ ! -L ${file} && ! -d ${file} ]]; then
      if printf '%s\n' "${2}" >"${tmp}/display"; then
        command mv -Tf -- "${tmp}/display" "${file}" || rc=1
      else
        rc=1
      fi
    else
      rc=1
    fi
  fi
  return "${rc}"
)
ssa_start() {
  # interactive shell start: switch inherited values to the stable ones
  local host link value shared=0
  [[ ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  host=$(ssa_host) || return 0
  link=${HOME}/.ssh/authsock-${host}
  if [[ -n ${TMUX-} || -n ${STY-} || ${TERM_PROGRAM-} == 'vscode' ]]; then
    shared=1
  fi
  if [[ ${SSH_AUTH_SOCK-} != "${link}" ]] && ssa_untouched SSH_AUTH_SOCK; then
    if [[ ${shared} -eq 1 || -z ${SSH_AUTH_SOCK-} ]] && ssa_link_alive "${link}"; then
      export SSH_AUTH_SOCK=${link}
    fi
  fi
  if ssa_untouched DISPLAY && value=$(ssa_display_read); then
    if [[ ${value} != "${DISPLAY-}" ]] && ssa_display_alive "${value}"; then
      if [[ ${shared} -eq 1 || -z ${DISPLAY-} ]] || ! ssa_display_alive "${DISPLAY}"; then
        export DISPLAY=${value}
      fi
    fi
  fi
  return 0
}
ssa_mux_env() {
  # before tmux/screen: publish own live values, then export the live stable ones
  local host link value sock='' display='' agent=0
  [[ ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  host=$(ssa_host) || return 1
  link=${HOME}/.ssh/authsock-${host}
  if [[ ${SSH_AUTH_SOCK-} == "${link}" ]]; then
    agent=1
  elif ssa_untouched SSH_AUTH_SOCK; then
    agent=1
    sock=${SSH_AUTH_SOCK-}
  fi
  value=$(ssa_display_read) || value=''
  if ssa_untouched DISPLAY || [[ -n ${value} && ${DISPLAY-} == "${value}" ]]; then
    if [[ -n ${DISPLAY-} ]] && ssa_display_alive "${DISPLAY}"; then
      if [[ ${DISPLAY} != "${value}" ]]; then
        display=${DISPLAY}
      fi
    elif [[ -n ${value} ]] && ssa_display_alive "${value}"; then
      export DISPLAY=${value}
    fi
  fi
  if [[ -n ${sock} || -n ${display} ]]; then
    ssa_publish "${sock}" "${display}" || :
  fi
  if [[ ${agent} -eq 1 ]] && ssa_link_alive "${link}"; then
    export SSH_AUTH_SOCK=${link}
  fi
  return 0
}
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  # executed by ~/.ssh/rc with the environment prepared by sshd
  [[ ${1-} == '--publish' ]] || exit 2
  if [[ -n ${SSH_AUTH_SOCK-} || -n ${DISPLAY-} ]]; then
    ssa_publish "${SSH_AUTH_SOCK-}" "${DISPLAY-}" || :
  fi
  exit 0
elif [[ $- == *i* ]]; then
  ssa_start
fi
