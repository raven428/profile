#!/usr/bin/env bash
# cspell:ignore ssa epochrealtime cmdline inode inodes pids uptime
# cspell:ignore reattaches sigwinch winch
# VS Code Remote SSH terminals take SSH_AUTH_SOCK of the extension host of their window:
# a restored terminal leaves the forwarded agent of a closed connection. Reload Window
# keeps the shell, its link of the old connection is moved to the new one on SIGWINCH.
# Sourced by ~/.bashrc and ~/.bash_profile; SSH_AGENT_STABLE=off disables it.
# SSH_AGENT_STABLE_PROC replaces the /proc root, tests use it for a fake process tree.
ssa_agent_alive() {
  # $1: socket, $2: time limit in microseconds; ssh-add -l: 0 lists keys, 1 with
  # the exact message is an empty but alive agent; fails with 2 if it does not answer
  local out rc=0 limit
  [[ -S ${1} ]] || return 1
  printf -v limit '%d.%06d' $((${2} / 1000000)) $((${2} % 1000000))
  out=$(SSH_AUTH_SOCK=${1} command timeout -k 0.1 "${limit}" ssh-add -l 2>/dev/null) ||
    rc=$?
  if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
    return 2
  fi
  [[ ${rc} -eq 0 || (${rc} -eq 1 && ${out} == 'The agent has no identities.') ]]
}
ssa_environ_get() {
  # $1: environ file, $2: variable name, $3: name of the variable for the value
  local -a ssa_entries
  local ssa_entry
  mapfile -d '' -t ssa_entries 2>/dev/null <"${1}" || return 1
  for ssa_entry in "${ssa_entries[@]}"; do
    if [[ ${ssa_entry} == "${2}="* ]]; then
      printf -v "${3}" '%s' "${ssa_entry#*=}"
      return 0
    fi
  done
  return 1
}
ssa_has_arg() {
  # $1: cmdline file, $2: argument the process was started with
  local -a ssa_args
  local ssa_arg
  mapfile -d '' -t ssa_args 2>/dev/null <"${1}" || return 1
  for ssa_arg in "${ssa_args[@]}"; do
    if [[ ${ssa_arg} == "${2}" ]]; then
      return 0
    fi
  done
  return 1
}
ssa_digits() {
  # $1: a non-empty string of digits; a pattern, not =~: BASH_REMATCH of the code
  # interrupted by the trap of SIGWINCH stays as it was
  [[ -n ${1} && ${1} != *[!0-9]* ]]
}
ssa_stat() {
  # $1: stat file; sets ssa_ppid and ssa_start, fields 4 and 22 of proc(5)
  local line=''
  local -a rest
  IFS= read -r line 2>/dev/null <"${1}" || [[ -n ${line} ]] || return 1
  [[ ${line} == *') '* ]] || return 1
  read -r -a rest <<<"${line##*) }"
  ssa_digits "${rest[1]-}" && ssa_digits "${rest[19]-}" || return 1
  ssa_ppid=${rest[1]}
  ssa_start=${rest[19]}
}
ssa_now() {
  # $1: name of the variable for the current time in microseconds: EPOCHREALTIME,
  # without it (bash 4) the uptime of the /proc root of ssa_vscode in 10 ms steps
  local up='' sec frac
  if [[ ${EPOCHREALTIME-} == *[.,]* ]]; then
    sec=${EPOCHREALTIME%[.,]*}
    frac=${EPOCHREALTIME#*[.,]}
    if ssa_digits "${sec}" && [[ ${frac} == [0-9][0-9][0-9][0-9][0-9][0-9] ]]; then
      printf -v "${1}" '%s' "${sec}${frac}"
      return 0
    fi
  fi
  read -r up _ 2>/dev/null <"${proc}/uptime" || :
  [[ ${up} == *.* ]] || return 1
  sec=${up%.*}
  frac=${up#*.}
  ssa_digits "${sec}" && [[ ${frac} == [0-9][0-9] ]] || return 1
  printf -v "${1}" '%d' $((10#${sec} * 1000000 + 10#${frac} * 10000))
}
ssa_tick() {
  # adds the time since the previous tick to ssa_spent of ssa_vscode; a clock that
  # goes back or cannot be read adds nothing, the floors of pauses and timeouts count
  local now
  ssa_now now || return 0
  if [[ -n ${ssa_last-} ]] && ((now > ssa_last)); then
    ssa_spent=$((ssa_spent + now - ssa_last))
  fi
  ssa_last=${now}
}
ssa_check() {
  # $1: index of a candidate of ssa_search; each agent is checked once per search,
  # an agent that did not answer is not checked again; a check takes up to 2 s,
  # with 0.1 s for the kill of ssh-add it fits in the rest of 2.9 s of ssa_vscode
  local rc=0 limit=2000000 floor sock=${ssa_socks[${1}]}
  if [[ -z ${ssa_alive[${1}]-} ]]; then
    ssa_alive[${1}]=0
    [[ -z ${ssa_hung[${sock}]-} ]] || return 1
    ssa_tick
    if ((2800000 - ssa_spent < limit)); then
      limit=$((2800000 - ssa_spent))
    fi
    # less than 10 ms is left: no check starts
    ((limit >= 10000)) || return 1
    floor=$((ssa_spent + limit + 100000))
    ssa_agent_alive "${sock}" "${limit}" || rc=$?
    if [[ ${rc} -eq 0 ]]; then
      ssa_alive[${1}]=1
    elif [[ ${rc} -eq 2 ]]; then
      ssa_hung[${sock}]=1
    fi
    # a check that did not answer takes the whole limit even if the clock went back
    ssa_tick
    if [[ ${rc} -eq 2 ]] && ((ssa_spent < floor)); then
      ssa_spent=${floor}
    fi
  fi
  [[ ${ssa_alive[${1}]} -eq 1 ]]
}
ssa_children() {
  # $1: file of children; sets kids of the caller to its list of pids;
  # fails if the file cannot be opened
  local fd
  # a file that vanishes after the test also fails at the opening
  [[ -f ${1} ]] || return 1
  { exec {fd}<"${1}"; } 2>/dev/null || return 1
  kids=()
  read -r -a kids <&"${fd}" 2>/dev/null || :
  exec {fd}<&-
}
ssa_sockets() {
  # $1: /proc root; adds to owned of the caller the inodes of the sockets bound to
  # the git socket of this terminal; fails if the table of sockets cannot be read
  local fd inode path
  [[ -f ${1}/net/unix ]] || return 1
  { exec {fd}<"${1}/net/unix"; } 2>/dev/null || return 1
  while read -r _ _ _ _ _ _ inode path; do
    if ssa_digits "${inode}" && [[ ${path} == "${VSCODE_GIT_IPC_HANDLE}" ]]; then
      owned["socket:[${inode}]"]=1
    fi
  done 2>/dev/null <&"${fd}"
  exec {fd}<&-
}
ssa_search() {
  # $1: /proc root, $2: pid of server-main; sets ssa_match=1 if the current
  # SSH_AUTH_SOCK is a live candidate, otherwise ssa_found to a live candidate or '';
  # fails if the list of processes or the git socket owners cannot be read
  local dir=${XDG_RUNTIME_DIR:-/tmp} file pid sock i ssa_ppid ssa_start
  local -a kids targets ssa_pids=() ssa_starts=() ssa_socks=()
  local -A ssa_alive=() owned=()
  ssa_match=0
  ssa_found=''
  for file in "${1}/${2}"/task/*/children; do
    ssa_children "${file}" || return 2
    for pid in "${kids[@]}"; do
      [[ ${pid} =~ ^[0-9]+$ ]] || continue
      ssa_has_arg "${1}/${pid}/cmdline" '--type=extensionHost' || continue
      ssa_environ_get "${1}/${pid}/environ" SSH_AUTH_SOCK sock || continue
      [[ ${sock} == "${dir}/vscode-ssh-auth-sock-"* ]] || continue
      [[ ${sock#"${dir}/vscode-ssh-auth-sock-"} != */* ]] || continue
      ssa_stat "${1}/${pid}/stat" || continue
      # candidates are sorted by start time, the freshest first
      i=${#ssa_pids[@]}
      while ((i > 0 && ssa_starts[i - 1] < ssa_start)); do
        ssa_pids[i]=${ssa_pids[i - 1]}
        ssa_starts[i]=${ssa_starts[i - 1]}
        ssa_socks[i]=${ssa_socks[i - 1]}
        i=$((i - 1))
      done
      ssa_pids[i]=${pid}
      ssa_starts[i]=${ssa_start}
      ssa_socks[i]=${sock}
    done
  done
  if [[ -n ${SSH_AUTH_SOCK-} ]]; then
    for i in "${!ssa_pids[@]}"; do
      if [[ ${ssa_socks[i]} == "${SSH_AUTH_SOCK}" ]] && ssa_check "${i}"; then
        ssa_match=1
        return 0
      fi
    done
  fi
  # usual path: the extension host listening on the git socket of this terminal
  if [[ -n ${VSCODE_GIT_IPC_HANDLE-} ]]; then
    ssa_sockets "${1}" || return 2
    if [[ ${#owned[@]} -gt 0 ]]; then
      for i in "${!ssa_pids[@]}"; do
        mapfile -t targets < <(command readlink -- "${1}/${ssa_pids[i]}"/fd/* 2>/dev/null)
        if [[ ${#targets[@]} -eq 0 ]]; then
          # unreadable descriptors: the owner is unknown, the candidate is skipped
          ssa_alive[${i}]=0
          continue
        fi
        for file in "${targets[@]}"; do
          if [[ -n ${owned[${file}]-} ]]; then
            if ssa_check "${i}"; then
              ssa_found=${ssa_socks[i]}
              return 0
            fi
            break
          fi
        done
      done
    fi
  fi
  # fallback: the freshest live candidate, possibly of another window
  for i in "${!ssa_pids[@]}"; do
    if ssa_check "${i}"; then
      ssa_found=${ssa_socks[i]}
      return 0
    fi
  done
  return 0
}
ssa_vscode() {
  # interactive bash of a VS Code terminal: take the agent of the own window
  local proc=${SSH_AGENT_STABLE_PROC:-/proc} initial server left floor pause
  local ssa_ppid ssa_start ssa_match ssa_found ssa_last='' ssa_spent=0 waited=0
  local -A ssa_hung=()
  [[ ${TERM_PROGRAM-} == 'vscode' && ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  if [[ -n ${SSH_AUTH_SOCK-} ]]; then
    ssa_environ_get "${proc}/$$/environ" SSH_AUTH_SOCK initial || return 0
    [[ ${SSH_AUTH_SOCK} == "${initial}" ]] || return 0
  fi
  ssa_has_arg "${proc}/${PPID}/cmdline" '--type=ptyHost' || return 0
  ssa_stat "${proc}/${PPID}/stat" || return 0
  server=${ssa_ppid}
  # 3 seconds from the first search: 2.9 s of spent time, 0.1 s for the jitter of sleep;
  # nothing is done without a clock
  ssa_tick
  [[ -n ${ssa_last} ]] || return 0
  while :; do
    if ! ssa_search "${proc}" "${server}"; then
      [[ ${waited} -eq 1 ]] || return 0
      break
    fi
    if [[ ${ssa_match} -eq 1 || -n ${ssa_found} ]]; then
      break
    fi
    # the extension host of a restored terminal may start after the shell
    [[ ${SSH_AUTH_SOCK-} == */vscode-ssh-auth-sock-* ]] || return 0
    # the message comes before the deadline test: a slow first search also reports
    if [[ ${waited} -eq 0 ]]; then
      printf 'ssh-agent-stable: looking for the agent of this VS Code window' >&2
      printf ' for up to 3 seconds\n' >&2
      waited=1
    fi
    ssa_tick
    left=$((2900000 - ssa_spent))
    if [[ ${left} -le 0 ]]; then
      break
    fi
    if [[ ${left} -gt 500000 ]]; then
      left=500000
    fi
    floor=$((ssa_spent + left))
    printf -v pause '%d.%06d' $((left / 1000000)) $((left % 1000000))
    command sleep "${pause}"
    # no new search after the deadline; the pause counts even if the clock goes back
    ssa_tick
    if [[ ${ssa_spent} -lt ${floor} ]]; then
      ssa_spent=${floor}
    fi
    if [[ ${ssa_spent} -ge 2900000 ]]; then
      break
    fi
  done
  if [[ -n ${ssa_found} && ${ssa_found} != "${SSH_AUTH_SOCK-}" ]]; then
    export SSH_AUTH_SOCK=${ssa_found}
    if [[ ${waited} -eq 1 ]]; then
      printf 'ssh-agent-stable: SSH_AUTH_SOCK switched to %s\n' "${SSH_AUTH_SOCK}" >&2
    fi
  elif [[ ${waited} -eq 1 ]]; then
    if [[ ${ssa_match} -eq 1 ]]; then
      printf 'ssh-agent-stable: SSH_AUTH_SOCK kept, it is the agent of this window\n' >&2
    else
      printf 'ssh-agent-stable: SSH_AUTH_SOCK kept as %s, the agent may not work:' \
        "${SSH_AUTH_SOCK}" >&2
      printf ' open a new terminal\n' >&2
    fi
  fi
  return 0
}
ssa_owner() {
  # $1: /proc root, $2: pid of server-main; sets ssa_owner_pid and ssa_owner_start to
  # the freshest extension host listening on the git socket of this terminal
  local file pid path ssa_ppid ssa_start
  local -a kids targets
  local -A owned=()
  ssa_owner_pid=''
  ssa_owner_start=''
  [[ -n ${VSCODE_GIT_IPC_HANDLE-} ]] || return 1
  ssa_sockets "${1}" || return 1
  [[ ${#owned[@]} -gt 0 ]] || return 1
  for file in "${1}/${2}"/task/*/children; do
    ssa_children "${file}" || continue
    for pid in "${kids[@]}"; do
      ssa_digits "${pid}" || continue
      ssa_has_arg "${1}/${pid}/cmdline" '--type=extensionHost' || continue
      ssa_stat "${1}/${pid}/stat" || continue
      # the freshest owner wins: a hanging old one may hold the same path
      [[ -z ${ssa_owner_pid} ]] || ((ssa_start > ssa_owner_start)) || continue
      mapfile -t targets < <(command readlink -- "${1}/${pid}"/fd/* 2>/dev/null)
      for path in "${targets[@]}"; do
        if [[ -n ${owned[${path}]-} ]]; then
          ssa_owner_pid=${pid}
          ssa_owner_start=${ssa_start}
          break
        fi
      done
    done
  done
  [[ -n ${ssa_owner_pid} ]]
}
ssa_host_alive() {
  # $1: /proc root; the remembered extension host still runs: a resize, not a reload
  local ssa_ppid ssa_start
  [[ -n ${ssa_host-} ]] || return 1
  ssa_has_arg "${1}/${ssa_host}/cmdline" '--type=extensionHost' || return 1
  ssa_stat "${1}/${ssa_host}/stat" || return 1
  [[ ${ssa_start} == "${ssa_host_start-}" ]]
}
ssa_claim() {
  # $1: SSH_AUTH_SOCK of an extension host; the link of this terminal is its own, kept
  # in ssa_link, if its path is the same string: a link of another window is not, even
  # if it leads to the same agent
  [[ -n ${SSH_AUTH_SOCK-} && -n ${1} && ${SSH_AUTH_SOCK} == "${1}" ]] || return 0
  ssa_link=${SSH_AUTH_SOCK}
}
ssa_winch() {
  # the trap of SIGWINCH: Reload Window reattaches the shell and sends it a few seconds
  # after the new extension host starts; the own link of this window is moved to the
  # agent of the new connection, every terminal and process holding it keeps working,
  # the links of other windows are not touched
  local proc=${SSH_AGENT_STABLE_PROC:-/proc} dir=${XDG_RUNTIME_DIR:-/tmp}
  local reload=0 found=0 sock fresh='' tmp left floor pause ssa_ppid ssa_start
  local ssa_owner_pid ssa_owner_start ssa_last='' ssa_spent=0
  local IFS=$' \t\n' c='[A-Za-z0-9]'
  local forwarded="/tmp/ssh-${c}${c}${c}${c}${c}${c}${c}${c}${c}${c}/agent."
  [[ ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  ssa_host_alive "${proc}" && return 0
  if [[ -n ${ssa_host-} ]]; then
    reload=1
  fi
  ssa_host=''
  ssa_host_start=''
  # Remote SSH links the fresh <N> asynchronously: up to 3 seconds for it, one search
  # without a clock
  ssa_tick
  while :; do
    if ssa_stat "${proc}/${PPID}/stat" && ssa_owner "${proc}" "${ssa_ppid}"; then
      sock=''
      ssa_environ_get "${proc}/${ssa_owner_pid}/environ" SSH_AUTH_SOCK sock || :
      fresh=$(command readlink -e -- "${sock}" 2>/dev/null) || fresh=''
      if [[ ${fresh} == ${forwarded}* && -S ${fresh} ]] &&
        ssa_digits "${fresh#*/agent.}"; then
        found=1
        break
      fi
    fi
    [[ -n ${ssa_last} ]] || break
    ssa_tick
    left=$((2900000 - ssa_spent))
    ((left > 0)) || break
    if ((left > 200000)); then
      left=200000
    fi
    floor=$((ssa_spent + left))
    printf -v pause '%d.%06d' $((left / 1000000)) $((left % 1000000))
    command sleep "${pause}"
    # no new search after the deadline; the pause counts even if the clock goes back
    ssa_tick
    if ((ssa_spent < floor)); then
      ssa_spent=${floor}
    fi
    ((ssa_spent < 2900000)) || break
  done
  if [[ ${found} -eq 0 ]]; then
    # a resize of a window without a known extension host searches silently
    if [[ ${reload} -eq 1 ]]; then
      printf 'ssh-agent-stable: no agent of this VS Code window after a reload,' >&2
      printf ' SSH_AUTH_SOCK may not work: open a new terminal\n' >&2
    fi
    return 0
  fi
  [[ -n ${ssa_link-} ]] || ssa_claim "${sock}"
  # the own link is not the current agent now: the next signal searches again
  [[ -z ${ssa_link-} || ${SSH_AUTH_SOCK-} == "${ssa_link}" ]] || return 0
  ssa_host=${ssa_owner_pid}
  ssa_host_start=${ssa_owner_start}
  # only the own link of Remote SSH is moved, an explicit value is kept
  [[ -n ${ssa_link-} ]] || return 0
  [[ ${SSH_AUTH_SOCK-} == "${dir}/vscode-ssh-auth-sock-"* ]] || return 0
  [[ ${SSH_AUTH_SOCK#"${dir}/vscode-ssh-auth-sock-"} != */* ]] || return 0
  [[ -L ${SSH_AUTH_SOCK} && ! ${SSH_AUTH_SOCK} -ef ${fresh} ]] || return 0
  tmp=${SSH_AUTH_SOCK}.winch.$$
  if ! { command ln -sfn -- "${fresh}" "${tmp}" &&
    command mv -Tf -- "${tmp}" "${SSH_AUTH_SOCK}"; } 2>/dev/null; then
    command rm -f -- "${tmp}"
    # the next signal searches and moves the link again
    ssa_host=''
    ssa_host_start=''
    if [[ ${reload} -eq 1 ]]; then
      printf 'ssh-agent-stable: %s is not moved to the agent of this window,' \
        "${SSH_AUTH_SOCK}" >&2
      printf ' SSH_AUTH_SOCK may not work: open a new terminal\n' >&2
    fi
  fi
  return 0
}
ssa_arm() {
  # interactive bash of a VS Code terminal: set the trap of Reload Window and remember
  # the extension host of the own window if it is found
  local proc=${SSH_AGENT_STABLE_PROC:-/proc} ssa_ppid ssa_start sock=''
  local ssa_owner_pid ssa_owner_start
  [[ ${TERM_PROGRAM-} == 'vscode' && ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  ssa_has_arg "${proc}/${PPID}/cmdline" '--type=ptyHost' || return 0
  # a trap of SIGWINCH set before, e.g. in ~/.bashrc_local, is kept
  [[ -z $(trap -p WINCH) ]] || return 0
  ssa_host=''
  ssa_host_start=''
  ssa_link=''
  if ssa_stat "${proc}/${PPID}/stat" && ssa_owner "${proc}" "${ssa_ppid}"; then
    ssa_host=${ssa_owner_pid}
    ssa_host_start=${ssa_owner_start}
    ssa_environ_get "${proc}/${ssa_owner_pid}/environ" SSH_AUTH_SOCK sock || :
    ssa_claim "${sock}"
  fi
  trap ssa_winch WINCH
}
if [[ $- == *i* && -z ${ssa_done-} ]]; then
  # repeated sourcing in the same shell does nothing
  ssa_done=1
  ssa_vscode
  ssa_arm
fi
