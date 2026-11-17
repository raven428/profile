#!/usr/bin/env bash
# cspell:ignore ssa epochrealtime cmdline inode inodes pids uptime
# VS Code Remote SSH terminals take SSH_AUTH_SOCK of the extension host of their window:
# a restored terminal leaves the forwarded agent of a closed connection.
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
ssa_stat() {
  # $1: stat file; sets ssa_ppid and ssa_start, fields 4 and 22 of proc(5)
  local line=''
  local -a rest
  IFS= read -r line 2>/dev/null <"${1}" || [[ -n ${line} ]] || return 1
  [[ ${line} == *') '* ]] || return 1
  read -r -a rest <<<"${line##*) }"
  [[ ${rest[1]-} =~ ^[0-9]+$ && ${rest[19]-} =~ ^[0-9]+$ ]] || return 1
  ssa_ppid=${rest[1]}
  ssa_start=${rest[19]}
}
ssa_now() {
  # $1: name of the variable for the current time in microseconds: EPOCHREALTIME,
  # without it (bash 4) the uptime of the /proc root of ssa_vscode in 10 ms steps
  local up=''
  if [[ ${EPOCHREALTIME-} =~ ^([0-9]+)[.,]([0-9]{6})$ ]]; then
    printf -v "${1}" '%s' "${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    return 0
  fi
  read -r up _ 2>/dev/null <"${proc}/uptime" || :
  [[ ${up} =~ ^([0-9]+)\.([0-9]{2})$ ]] || return 1
  printf -v "${1}" '%d' \
    $((10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 10000))
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
ssa_search() {
  # $1: /proc root, $2: pid of server-main; sets ssa_match=1 if the current
  # SSH_AUTH_SOCK is a live candidate, otherwise ssa_found to a live candidate or '';
  # fails if the list of processes or the git socket owners cannot be read
  local dir=${XDG_RUNTIME_DIR:-/tmp} file pid sock i inode path ssa_ppid ssa_start fd
  local -a kids targets ssa_pids=() ssa_starts=() ssa_socks=()
  local -A ssa_alive=() owned=()
  ssa_match=0
  ssa_found=''
  for file in "${1}/${2}"/task/*/children; do
    # a file that vanishes after the test also fails at the opening
    [[ -f ${file} ]] || return 2
    { exec {fd}<"${file}"; } 2>/dev/null || return 2
    kids=()
    read -r -a kids <&"${fd}" 2>/dev/null || :
    exec {fd}<&-
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
    [[ -f ${1}/net/unix ]] || return 2
    { exec {fd}<"${1}/net/unix"; } 2>/dev/null || return 2
    while read -r _ _ _ _ _ _ inode path; do
      if [[ ${inode} =~ ^[0-9]+$ && ${path} == "${VSCODE_GIT_IPC_HANDLE}" ]]; then
        owned["socket:[${inode}]"]=1
      fi
    done 2>/dev/null <&"${fd}"
    exec {fd}<&-
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
if [[ $- == *i* && -z ${ssa_done-} ]]; then
  # repeated sourcing in the same shell does nothing
  ssa_done=1
  ssa_vscode
fi
