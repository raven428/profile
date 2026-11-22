#!/usr/bin/env bash
# cspell:ignore ssa epochrealtime cmdline inode inodes pids uptime
# cspell:ignore reattaches sigwinch winch bashpid failglob nullglob nocasematch
# cspell:ignore functrace errtrace sshd logind redirections subshell
# VS Code Remote SSH terminals take SSH_AUTH_SOCK of the extension host of their window:
# a restored terminal leaves the forwarded agent of a closed connection. Reload Window
# keeps the shell, its link of the old connection is moved to the new one on SIGWINCH.
# Sourced by ~/.bashrc and ~/.bash_profile; SSH_AGENT_STABLE=off disables it.
# SSH_AGENT_STABLE_PROC replaces the /proc root, tests use it for a fake process tree;
# SSH_AGENT_STABLE_DONE names a file, the handler of SIGWINCH appends its outcome there.
# Functions of the user may be named like builtins: builtins are called through builtin.
ssa_agent_alive() {
  # $1: socket, $2: time limit in microseconds; ssh-add -l: 0 lists keys, 1 with
  # the exact message is an empty but alive agent; fails with 2 if it does not answer
  local out rc=0 limit
  [[ -S ${1} ]] || return 1
  builtin printf -v limit '%d.%06d' $((${2} / 1000000)) $((${2} % 1000000))
  out=$(builtin command env "SSH_AUTH_SOCK=${1}" timeout -k 0.1 "${limit}" \
    ssh-add -l 2>/dev/null) || rc=$?
  if [[ ${rc} -eq 124 || ${rc} -eq 137 ]]; then
    return 2
  fi
  [[ ${rc} -eq 0 || (${rc} -eq 1 && ${out} == 'The agent has no identities.') ]]
}
ssa_environ_get() {
  # $1: environ file, $2: variable name, $3: name of the variable for the value
  local -a ssa_entries
  local ssa_entry
  builtin mapfile -d '' -t ssa_entries 2>/dev/null <"${1}" || return 1
  for ssa_entry in "${ssa_entries[@]}"; do
    if [[ ${ssa_entry} == "${2}="* ]]; then
      builtin printf -v "${3}" '%s' "${ssa_entry#*=}"
      return 0
    fi
  done
  return 1
}
ssa_has_arg() {
  # $1: cmdline file, $2: argument the process was started with
  local -a ssa_args
  local ssa_arg
  builtin mapfile -d '' -t ssa_args 2>/dev/null <"${1}" || return 1
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
  IFS= builtin read -r line 2>/dev/null <"${1}" || [[ -n ${line} ]] || return 1
  [[ ${line} == *') '* ]] || return 1
  builtin read -r -a rest <<<"${line##*) }"
  ssa_digits "${rest[1]-}" && ssa_digits "${rest[19]-}" || return 1
  ssa_ppid=${rest[1]}
  ssa_start=${rest[19]}
}
ssa_uptime() {
  # $1: name of the variable for the uptime of the /proc root of the caller in 10 ms
  # steps
  local ssa_up='' ssa_whole ssa_part
  builtin read -r ssa_up _ 2>/dev/null <"${proc}/uptime" || :
  [[ ${ssa_up} == *.* ]] || return 1
  ssa_whole=${ssa_up%.*}
  ssa_part=${ssa_up#*.}
  ssa_digits "${ssa_whole}" && [[ ${ssa_part} == [0-9][0-9] ]] || return 1
  builtin printf -v "${1}" '%d' $((10#${ssa_whole} * 100 + 10#${ssa_part}))
}
ssa_now() {
  # $1: name of the variable for the current time in microseconds: EPOCHREALTIME,
  # without it (bash 4) the uptime of the /proc root of the caller in 10 ms steps;
  # EPOCHREALTIME is read once: two reads at a second boundary give a time almost
  # a second back
  local ssa_real=${EPOCHREALTIME-} ssa_s ssa_f ssa_cs
  if [[ ${ssa_real} == *[.,]* ]]; then
    ssa_s=${ssa_real%[.,]*}
    ssa_f=${ssa_real#*[.,]}
    if [[ -n ${ssa_s} && ${#ssa_f} -eq 6 ]] && ssa_digits "${ssa_s}${ssa_f}"; then
      builtin printf -v "${1}" '%s' "${ssa_s}${ssa_f}"
      return 0
    fi
  fi
  ssa_uptime ssa_cs || return 1
  builtin printf -v "${1}" '%d' $((ssa_cs * 10000))
}
ssa_tick() {
  # adds the time since the previous tick to ssa_spent of the caller; a clock that
  # goes back or cannot be read adds nothing, the floors of pauses and timeouts count
  local now
  ssa_now now || return 0
  if [[ -n ${ssa_last-} ]] && ((now > ssa_last)); then
    ssa_spent=$((ssa_spent + now - ssa_last))
  fi
  ssa_last=${now}
}
ssa_pause() {
  # $1: deadline of ssa_spent in microseconds, $2: the longest pause; sleeps till the
  # next check, fails when the deadline has come: no new check after it
  local left floor pause
  ssa_tick
  left=$((${1} - ssa_spent))
  ((left > 0)) || return 1
  if ((left > ${2})); then
    left=${2}
  fi
  floor=$((ssa_spent + left))
  builtin printf -v pause '%d.%06d' $((left / 1000000)) $((left % 1000000))
  builtin command sleep "${pause}"
  # the pause counts even if the clock goes back
  ssa_tick
  if ((ssa_spent < floor)); then
    ssa_spent=${floor}
  fi
  ((ssa_spent < ${1}))
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
  [[ -f ${1} ]] || return 1
  kids=()
  # no descriptor outlives the call: builtin exec {fd}<&- does not close it in bash 5.2;
  # read fails at the end of a list without a newline and at an empty list; a file that
  # vanishes after the test or cannot be read fails at the opening
  { builtin read -r -a kids <"${1}"; } 2>/dev/null || [[ -r ${1} ]]
}
ssa_sockets() {
  # $1: /proc root; adds to owned of the caller the inodes of the sockets bound to
  # the git socket of this terminal; fails if the table of sockets cannot be read
  local inode path
  [[ -f ${1}/net/unix ]] || return 1
  # the loop ends with the status 0, a failed opening gives 1
  while builtin read -r _ _ _ _ _ _ inode path; do
    if ssa_digits "${inode}" && [[ ${path} == "${VSCODE_GIT_IPC_HANDLE}" ]]; then
      owned["socket:[${inode}]"]=1
    fi
  done 2>/dev/null <"${1}/net/unix"
}
ssa_hosts() {
  # $1: /proc root, $2: pid of server-main; sets hosts of the caller to the pids of its
  # extension hosts; fails if a list of its children cannot be read
  local file pid
  local -a kids
  hosts=()
  for file in "${1}/${2}"/task/*/children; do
    ssa_children "${file}" || return 1
    for pid in "${kids[@]}"; do
      ssa_digits "${pid}" || continue
      ssa_has_arg "${1}/${pid}/cmdline" '--type=extensionHost' || continue
      hosts+=("${pid}")
    done
  done
}
ssa_owners() {
  # $1: /proc root; sets mine[pid]=1 of the caller for the extension hosts in hosts
  # listening on the git socket of this terminal, the hosts of the own window, and
  # unknown[pid]=1 for those whose descriptors cannot be read; fails if the table of
  # sockets cannot be read
  local pid fds file
  local -a targets
  local -A owned=()
  [[ -n ${VSCODE_GIT_IPC_HANDLE-} ]] || return 0
  ssa_sockets "${1}" || return 1
  [[ ${#owned[@]} -gt 0 ]] || return 0
  for pid in "${hosts[@]}"; do
    fds=${1}/${pid}/fd
    builtin mapfile -t targets < <(builtin command readlink -- "${fds}"/* 2>/dev/null)
    if [[ ${#targets[@]} -eq 0 ]]; then
      unknown[${pid}]=1
      continue
    fi
    for file in "${targets[@]}"; do
      if [[ -n ${owned[${file}]-} ]]; then
        mine[${pid}]=1
        break
      fi
    done
  done
}
ssa_search() {
  # $1: /proc root, $2: pid of server-main; sets ssa_match=1 if the current
  # SSH_AUTH_SOCK is a live candidate, otherwise ssa_found to a live candidate or '';
  # when an extension host of the own window is found, the candidates of other windows
  # do not count; fails if the list of processes or the git socket owners cannot be read
  local dir=${XDG_RUNTIME_DIR:-/tmp} pid sock i ssa_ppid ssa_start
  local -a hosts ssa_pids=() ssa_starts=() ssa_socks=()
  local -A ssa_alive=() mine=() unknown=()
  ssa_match=0
  ssa_found=''
  ssa_hosts "${1}" "${2}" || return 2
  for pid in "${hosts[@]}"; do
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
  ssa_owners "${1}" || return 2
  if [[ ${#mine[@]} -gt 0 ]]; then
    for i in "${!ssa_pids[@]}"; do
      # the own window is found: a candidate of another window is not checked
      [[ -n ${mine[${ssa_pids[i]}]-} ]] || ssa_alive[${i}]=0
    done
  fi
  if [[ -n ${SSH_AUTH_SOCK-} ]]; then
    for i in "${!ssa_pids[@]}"; do
      if [[ ${ssa_socks[i]} == "${SSH_AUTH_SOCK}" ]] && ssa_check "${i}"; then
        ssa_match=1
        return 0
      fi
    done
  fi
  # the freshest live candidate of the own window; without it the freshest live one,
  # possibly of another window
  for i in "${!ssa_pids[@]}"; do
    # unreadable descriptors: the owner is unknown, the candidate is skipped
    [[ -z ${unknown[${ssa_pids[i]}]-} ]] || continue
    if ssa_check "${i}"; then
      ssa_found=${ssa_socks[i]}
      return 0
    fi
  done
  return 0
}
ssa_vscode() {
  # interactive bash of a VS Code terminal: take the agent of the own window
  local proc=${SSH_AGENT_STABLE_PROC:-/proc} initial server
  local ssa_ppid ssa_start ssa_match ssa_found ssa_last='' ssa_spent=0 waited=0
  local -A ssa_hung=()
  # the fields of /proc are split by read -a and read with several names
  local IFS=$' \t\n'
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
      builtin printf 'ssh-agent-stable: looking for the agent of this VS Code window' >&2
      builtin printf ' for up to 3 seconds\n' >&2
      waited=1
    fi
    ssa_pause 2900000 500000 || break
  done
  if [[ -n ${ssa_found} && ${ssa_found} != "${SSH_AUTH_SOCK-}" ]]; then
    export SSH_AUTH_SOCK=${ssa_found}
    if [[ ${waited} -eq 1 ]]; then
      builtin printf 'ssh-agent-stable: SSH_AUTH_SOCK switched to %s\n' \
        "${SSH_AUTH_SOCK}" >&2
    fi
  elif [[ ${waited} -eq 1 ]]; then
    if [[ ${ssa_match} -eq 1 ]]; then
      builtin printf 'ssh-agent-stable: SSH_AUTH_SOCK kept, it is the agent of this' >&2
      builtin printf ' window\n' >&2
    else
      builtin printf 'ssh-agent-stable: SSH_AUTH_SOCK kept as %s, the agent may not' \
        "${SSH_AUTH_SOCK}" >&2
      builtin printf ' work: open a new terminal\n' >&2
    fi
  fi
  return 0
}
ssa_is_link() {
  # $1: path; a link of Remote SSH: vscode-ssh-auth-sock-<digits> right in the directory
  # dir of the caller
  [[ ${1} == "${dir}/vscode-ssh-auth-sock-"* ]] &&
    ssa_digits "${1#"${dir}/vscode-ssh-auth-sock-"}"
}
ssa_dir_ok() {
  # $1: directory of the link; it is not a symlink and is owned by the user or sticky
  # like /tmp without XDG_RUNTIME_DIR: there a file of another user can be neither
  # replaced by mv nor removed by ln -f
  [[ -d ${1} && ! -L ${1} && (-O ${1} || -k ${1}) ]]
}
ssa_scan() {
  # $1: /proc root, $2: pid of server-main; sets hosts and socks[pid] of the caller to
  # the extension hosts and their SSH_AUTH_SOCK; fails if the hosts cannot be listed
  local pid sock
  ssa_hosts "${1}" "${2}" || return 1
  for pid in "${hosts[@]}"; do
    ssa_environ_get "${1}/${pid}/environ" SSH_AUTH_SOCK sock || continue
    socks[${pid}]=${sock}
  done
}
ssa_find() {
  # $1: /proc root; sets own and own_start of the caller to the freshest extension host
  # in hosts listening on the git socket of this terminal: a hanging old one may hold
  # the same path; fails if there is none
  local pid ssa_ppid ssa_start
  own=''
  own_start=''
  ssa_owners "${1}" || return 1
  for pid in "${!mine[@]}"; do
    ssa_stat "${1}/${pid}/stat" || continue
    if [[ -z ${own} ]] || ((ssa_start > own_start)); then
      own=${pid}
      own_start=${ssa_start}
    fi
  done
  [[ -n ${own} ]]
}
ssa_look() {
  # $1: /proc root, $2: pid of server-main; scans the extension hosts and the owners of
  # the git socket anew, sets hosts, socks, mine, unknown, own and own_start of the
  # caller; fails if the hosts cannot be listed or the window has none
  hosts=()
  socks=()
  mine=()
  unknown=()
  ssa_scan "${1}" "${2}" && ssa_find "${1}"
}
ssa_fresh() {
  # $1: SSH_AUTH_SOCK of an extension host; sets fresh of the caller to the socket of the
  # user behind it if it is a link of Remote SSH. A raw path of an agent is not taken:
  # the host may inherit it from server-main, it does not prove a new connection. Any
  # directory of the socket: since OpenSSH 10.1 sshd puts it in ~/.ssh/agent
  fresh=''
  ssa_is_link "${1}" && [[ -L ${1} ]] || return 1
  fresh=$(builtin command readlink -e -- "${1}" 2>/dev/null) || fresh=''
  if [[ -n ${fresh} && -S ${fresh} && -O ${fresh} ]]; then
    return 0
  fi
  fresh=''
  return 1
}
ssa_settled() {
  # $1: /proc root, $2: pid of server-main; ssa_link already leads to the agent of the
  # own window: a handler of another signal has moved it meanwhile
  local own own_start fresh
  local -a hosts
  local -A socks=() mine=() unknown=()
  ssa_look "${1}" "${2}" && ssa_fresh "${socks[${own}]-}" &&
    [[ ${ssa_link} -ef ${fresh} ]]
}
ssa_move() {
  # $1: socket; points ssa_link to it, sets ssa_result of ssa_winch
  local tmp
  ssa_result=bad-dir
  ssa_dir_ok "${dir}" || return 0
  ssa_result=not-link
  [[ -L ${ssa_link} || ! -e ${ssa_link} ]] || return 0
  ssa_result=same
  [[ ! ${ssa_link} -ef ${1} ]] || return 0
  # logind removes /run/user/<uid> after the last session, the link with it
  ssa_result=created
  [[ ! -L ${ssa_link} ]] || ssa_result=moved
  # BASHPID, not $$: handlers of several signals run at once and share $$; ln -f
  # replaces a leftover of a killed handler with the same pid, in a sticky directory
  # it cannot remove a file of another user; -T does not enter a directory in the place
  tmp=${ssa_link}.winch.${BASHPID}
  if ! { builtin command ln -sfT -- "${1}" "${tmp}" &&
    builtin command mv -Tf -- "${tmp}" "${ssa_link}"; } 2>/dev/null; then
    builtin command rm -f -- "${tmp}" 2>/dev/null
    ssa_result=failed
  fi
}
ssa_foreign() {
  # ssa_link stands in SSH_AUTH_SOCK of a live extension host of another window; uses
  # socks and mine of the caller
  local pid
  for pid in "${!socks[@]}"; do
    if [[ -z ${mine[${pid}]-} && ${socks[${pid}]} == "${ssa_link}" ]]; then
      return 0
    fi
  done
  return 1
}
ssa_heal() {
  # sets ssa_result of ssa_winch to the outcome, see ssa_winch
  local proc=${SSH_AGENT_STABLE_PROC:-/proc} dir=${ssa_link%/*} server pid sock
  local own own_start fresh up young=0 moved_start='' moved_fresh='' deadline
  local ssa_ppid
  local ssa_start ssa_last='' ssa_spent=0
  local IFS=$' \t\n'
  local -a hosts
  local -A socks=() mine=() unknown=() young_of=() spent_of=()
  ssa_result=off
  [[ ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  ssa_result=no-host
  [[ -n ${ssa_link-} ]] || return 0
  ssa_stat "${proc}/${PPID}/stat" || return 0
  server=${ssa_ppid}
  ssa_scan "${proc}" "${server}" || return 0
  # the fast path without forks: the link leads where the link of Remote SSH of a live
  # extension host does, a resize ends here without looking for the window
  ssa_result=fast
  for pid in "${!socks[@]}"; do
    sock=${socks[${pid}]}
    if ssa_is_link "${sock}" && [[ -L ${sock} && ${ssa_link} -ef ${sock} ]]; then
      return 0
    fi
  done
  ssa_result=no-host
  ssa_find "${proc}" || return 0
  # the link of another window, e.g. taken at the start before the extension host of
  # this window opened the git socket, is not moved and nothing is awaited for it
  ssa_result=foreign
  ! ssa_foreign || return 0
  # Remote SSH links <N> of a new connection asynchronously: up to 10 seconds for it
  # while the extension host is younger than 15 seconds, one check without a clock; the
  # handler follows the freshest extension host of this window until the link leads to
  # its agent: a handler of an earlier reload must not leave the link at an outdated
  # connection, and a quick exit of the handler of a later signal relies on it. Every
  # host is awaited up to 10 seconds from its first choice by the handler: ssa_spent
  # counts on, spent_of keeps its value at that choice, a return to an earlier host
  # gets what is left of its own 10 seconds. The age of every host is taken once, at
  # its first choice, and kept for a return to it: a host that grows older than 15
  # seconds meanwhile is still awaited. The last step of every handler is the check
  # after its own move. A host the handler has moved to is chosen again only if its
  # agent is another one than at the last move and the link does not lead to it yet
  # (a reconnection without a reload, a handler of a later signal has moved the link
  # back); an older host is never chosen again. After every look the link of another
  # window ends the handler quietly, it is not moved after that.
  # The loop is finite: a move needs a strictly fresher host or a new agent of the same
  # host, a waiting ends after 10 seconds per host.
  # Field 22 of stat counts clock ticks since the boot, USER_HZ is 100 in the ABI of
  # Linux: the same 10 ms steps as the uptime; an unknown age counts as old
  while :; do
    if [[ -n ${moved_start} ]] && ((own_start < moved_start)); then
      break
    fi
    if [[ -z ${young_of[${own_start}]-} ]]; then
      young_of[${own_start}]=0
      if ssa_uptime up && ((up - own_start < 1500)); then
        young_of[${own_start}]=1
      fi
    fi
    young=${young_of[${own_start}]}
    if ssa_fresh "${socks[${own}]-}"; then
      if [[ -n ${moved_start} && ${own_start} -eq ${moved_start} ]] &&
        [[ ${fresh} == "${moved_fresh}" || ${ssa_link} -ef ${fresh} ]]; then
        break
      fi
      moved_start=${own_start}
      moved_fresh=${fresh}
      ssa_move "${fresh}"
      case ${ssa_result} in moved | created | same) ;; *) break ;; esac
    else
      if [[ ${young} -eq 0 ]]; then
        [[ -n ${moved_start} ]] || ssa_result=stale
        break
      fi
      if [[ -n ${moved_start} && ${own_start} -eq ${moved_start} ]]; then
        break
      fi
      if [[ -z ${spent_of[${own_start}]-} ]]; then
        ssa_tick
        spent_of[${own_start}]=${ssa_spent}
      fi
      deadline=$((${spent_of[${own_start}]} + 9900000))
      if [[ -z ${ssa_last} ]] || ! ssa_pause "${deadline}" 200000; then
        ssa_result=timeout
        if ! ssa_settled "${proc}" "${server}"; then
          builtin printf 'ssh-agent-stable: no agent of this VS Code window after a' >&2
          builtin printf ' reload, SSH_AUTH_SOCK may not work: open a new terminal\n' >&2
        fi
        break
      fi
    fi
    if ! ssa_look "${proc}" "${server}"; then
      [[ -n ${moved_start} ]] || ssa_result=no-host
      break
    fi
    if ssa_foreign; then
      [[ -n ${moved_start} ]] || ssa_result=foreign
      break
    fi
  done
  if [[ ${ssa_result} == 'failed' && ${young} -eq 1 ]] &&
    ! ssa_settled "${proc}" "${server}"; then
    builtin printf 'ssh-agent-stable: %s is not moved to the agent of this window,' \
      "${ssa_link}" >&2
    builtin printf ' SSH_AUTH_SOCK may not work: open a new terminal\n' >&2
  fi
  return 0
}
ssa_winch() {
  builtin trap - DEBUG && builtin set +T
  # The handler of SIGWINCH in a background copy of the shell. Reload Window reattaches
  # the shell and sends the signal a few seconds after the new extension host starts:
  # the link kept in ssa_link is moved to the agent of the new connection of this
  # window, every terminal and process holding it keeps working; the links of other
  # windows and SSH_AUTH_SOCK of the shell are not touched. The first line stops the
  # DEBUG trap inherited with set -T: its forks would run before every command here.
  # Limits:
  # - Reload after a lost connection gives the window a new storage <id>-1 and another
  #   git socket: the window is not found, the terminal is not healed, the handler
  #   quits silently; another sign of the window is needed for it;
  # - a signal that comes when the extension host is older than 15 seconds and its <N>
  #   is not linked yet (a very slow reload) does not wait: the next signal heals;
  # - a terminal with a link dead for good takes the full path with forks on every
  #   resize, in the background, the prompt does not wait;
  # - a reconnection without a reload is healed only by a signal after it, unverified.
  # The outcome for SSH_AGENT_STABLE_DONE, one line per handler: off, fast, no-host,
  # foreign, stale (no agent of an old host, no waiting), timeout (no agent of a young
  # host after the waiting), bad-dir, not-link, same, moved, created or failed.
  local ssa_result=''
  # the copy has the options of the shell: no globs that fail or vanish, no case-blind
  # comparisons, no stop on errors or unset variables, no inherited ERR and RETURN
  builtin trap - ERR RETURN
  builtin shopt -u failglob nullglob nocasematch
  builtin set +e +u +f +E
  ssa_heal
  if [[ -n ${SSH_AGENT_STABLE_DONE-} ]]; then
    { builtin printf '%s\n' "${ssa_result}" >>"${SSH_AGENT_STABLE_DONE}"; } 2>/dev/null
  fi
}
ssa_arm() {
  # interactive bash of a VS Code terminal: set the trap of Reload Window for the link of
  # Remote SSH of this terminal, kept in ssa_link for the life of the shell
  local proc=${SSH_AGENT_STABLE_PROC:-/proc} dir=${XDG_RUNTIME_DIR:-/tmp}
  [[ ${TERM_PROGRAM-} == 'vscode' && ${SSH_AGENT_STABLE-} != 'off' ]] || return 0
  ssa_has_arg "${proc}/${PPID}/cmdline" '--type=ptyHost' || return 0
  # a trap of SIGWINCH set before, e.g. in ~/.bashrc_local, is kept
  [[ -z $(builtin trap -p WINCH) ]] || return 0
  [[ -n ${VSCODE_GIT_IPC_HANDLE-} ]] || return 0
  ssa_is_link "${SSH_AUTH_SOCK-}" && ssa_dir_ok "${dir}" || return 0
  ssa_link=${SSH_AUTH_SOCK}
  # The handler runs in a background copy of the shell, not in the shell itself:
  # - shell integration of VS Code marks the start of a command by its DEBUG trap while
  #   __vsc_in_command_execution=0; any simple command, [[ ]] or (( )) of a trap at the
  #   prompt calls it, the marks 633;E and 633;C go out and the next real command gets
  #   none: VS Code gives its output to a phantom command. DEBUG is not called before
  #   ( ... ), even with redirections, and is not inherited inside without set -T;
  # - stdin from /dev/null: the copy lives in the process group of the finished subshell,
  #   its parent is init; neither it nor its commands read the input of the user; with
  #   stty tostop a message to stderr may not reach the terminal;
  # - stdout to /dev/null: with set -T the copies call DEBUG, and preexec of VS Code
  #   prints the marks to stdout; the messages of the handler go to stderr;
  # - & inside: the prompt does not wait even for 10 seconds; $!, $_, $?, IFS and
  #   BASH_REMATCH of the interrupted code are kept, no job runs or stops; a signal
  #   during a command leaves a finished ( ... ) in jobs till the next prompt, which
  #   removes it without a notice like any finished foreground command.
  # A caught SIGWINCH interrupts the builtin wait of an interactive shell with the status
  # 156: so bash does for a trap of any signal, it cannot be fixed.
  builtin trap '( ssa_winch & ) </dev/null >/dev/null' WINCH
}
ssa_opts_save() {
  # the start runs in the shell itself: the options that change globs and comparisons or
  # stop the run are reset, eval of ssa_opts restores them; read without forks
  local opt
  ssa_opts=''
  for opt in nocasematch failglob nullglob; do
    if builtin shopt -q "${opt}"; then
      ssa_opts+="builtin shopt -s ${opt}; "
    fi
  done
  builtin shopt -u nocasematch failglob nullglob
  for opt in e u f; do
    if [[ $- == *"${opt}"* ]]; then
      ssa_opts+="builtin set -${opt}; "
    fi
  done
  builtin set +e +u +f
}
if [[ $- == *i* && -z ${ssa_done-} ]]; then
  # repeated sourcing in the same shell does nothing
  ssa_done=1
  ssa_opts_save
  ssa_vscode
  ssa_arm
  builtin eval "${ssa_opts}"
  builtin unset -v ssa_opts
fi
