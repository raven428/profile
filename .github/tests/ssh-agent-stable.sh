#!/usr/bin/env bash
# cspell:ignore authsock scrrr tmx keygen pids setsid SIGTTIN SHIMS SCREENDIR cmdline
# cspell:ignore epochrealtime inode inodes uptime sigwinch winch
# cspell:ignore bashpid failglob nocasematch nullglob functrace sshd
# Scenarios for .config/bash/ssh-agent-stable.sh and set_mux_env in an isolated HOME,
# VS Code server processes are emulated by a fake /proc tree.
# shellcheck disable=SC2016
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
if ! tmp=$(mktemp -d -p /var/tmp ssh-agent-stable.XXXXXXXX); then
  printf 'mktemp -d -p /var/tmp ssh-agent-stable.XXXXXXXX failed\n' >&2
  exit 1
fi
home=${tmp}/home
run=${tmp}/run
pids=()
failed=()
passed=0
fwd=''
sticky=()
ro=${tmp}/ro
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null
  done
  wait 2>/dev/null
  if [[ -d ${ro} ]]; then
    chmod 700 "${ro}"
  fi
  rm -rf -- "${tmp}"
  if [[ -n ${fwd-} ]]; then
    rm -rf -- "${fwd}"
  fi
  if [[ ${#sticky[@]} -gt 0 ]]; then
    rm -f -- "${sticky[@]}"
  fi
}
trap cleanup EXIT
check() {
  # $1: scenario name, $2: expected value, $3: actual value
  if [[ ${2} == "${3}" ]]; then
    passed=$((passed + 1))
  else
    failed+=("${1}: expected '${2}', got '${3}'")
  fi
}
wait_for() {
  # $1: test operator, $2: path; waits up to 5 seconds
  local i
  for ((i = 0; i < 50; i++)); do
    if test "${1}" "${2}"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}
start_agent() {
  # $1: socket path; the agent pid is appended to pids
  ssh-agent -D -a "${1}" >/dev/null 2>&1 &
  pids+=("$!")
  if ! wait_for -S "${1}"; then
    printf 'ssh-agent did not start on %s\n' "${1}" >&2
    exit 1
  fi
}
mkdir -p "${home}/.ssh" "${home}/.config/bash" "${tmp}/bin" "${run}" "${tmp}/screen"
chmod 700 "${home}/.ssh" "${run}" "${tmp}/screen"
cp "${repo}/.bashrc" "${repo}/.bash_profile" "${home}/"
cp "${repo}/.config/bash/ssh-agent-stable.sh" "${home}/.config/bash/"
profile_local() {
  # login profiles of some hosts set XDG_RUNTIME_DIR in /etc/profile.d, $1: extra line
  printf 'export XDG_RUNTIME_DIR=%s\n%s\n' "${run}" "${1-}" >"${home}/.bash_profile_local"
}
profile_local
cat >"${tmp}/bin/tmux" <<'EOF'
#!/bin/sh
printf 'tmux|%s|%s\n' "${SSH_AUTH_SOCK-}" "$*" >>"${MUX_LOG:?}"
EOF
cat >"${tmp}/bin/screen" <<'EOF'
#!/bin/sh
printf 'screen|%s|%s\n' "${SSH_AUTH_SOCK-}" "$*" >>"${MUX_LOG:?}"
EOF
cat >"${tmp}/bin/ssh-add" <<'EOF'
#!/bin/sh
printf '%s\n' "${SSH_AUTH_SOCK-}" >>"${SSH_ADD_LOG:?}"
# the agents behind the links 197 and 198 accept the connection and do not answer,
# the agents behind the links 195 and 196 answer with an error in 1.5 seconds,
# the agents behind the links 193 and 194 refuse at once
case "${SSH_AUTH_SOCK-}" in
*-197 | *-198) exec sleep 10 ;;
*-193 | *-194) exit 2 ;;
*-195 | *-196)
  sleep 1.5
  exit 2
  ;;
esac
exec "${REAL_SSH_ADD:?}" "$@"
EOF
# emulates the pty host: exec keeps the pid and the parent pid of the shell
cat >"${tmp}/pty.sh" <<'EOF'
#!/bin/sh
# $1: fake /proc root, $2: type of the parent process or none, the rest: bash arguments
fake=$1
type=$2
shift 2
if [ "${type}" != none ]; then
  mkdir -p "${fake}/$$" "${fake}/${PPID}"
  env -0 >"${fake}/$$/environ"
  printf '%s\0' node bootstrap-fork "--type=${type}" >"${fake}/${PPID}/cmdline"
  printf '%s (a b) c) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 50 0 0\n' "${PPID}" \
    "${SERVER_PID:?}" >"${fake}/${PPID}/stat"
fi
exec bash "$@"
EOF
# a DEBUG trap with set -T like shell integration of VS Code: copies of the shell print
# a mark to stdout
cat >"${tmp}/copy-mark" <<'EOF'
copy_mark() {
  if [[ ${BASHPID} != "$$" ]]; then
    builtin printf 'COPY:%s\n' "${BASHPID}"
  fi
}
set -T
builtin trap copy_mark DEBUG
EOF
chmod 755 "${tmp}/bin/tmux" "${tmp}/bin/screen" "${tmp}/bin/ssh-add" "${tmp}/pty.sh"
: >"${tmp}/mux.log"
: >"${tmp}/ssh-add.log"
: >"${tmp}/baseline-plain"
: >"${tmp}/baseline-login"
server=5000000
# login shells reset PATH in /etc/profile, so mux scenarios prepend SHIMS after it
# setsid drops the controlling terminal: interactive bash must not stop on SIGTTIN
base=(setsid -w env -i "HOME=${home}" "PATH=${tmp}/bin:${PATH}" "SHIMS=${tmp}/bin"
  "USER=tester" "TERM=dumb" "XDG_RUNTIME_DIR=${run}" "TMUX_TMPDIR=${run}"
  "SCREENDIR=${tmp}/screen" "MUX_LOG=${tmp}/mux.log" "SSH_ADD_LOG=${tmp}/ssh-add.log"
  "REAL_SSH_ADD=$(command -v ssh-add)" "SERVER_PID=${server}")
host=$(env -i bash -c 'printf "%s" "${HOSTNAME%%.*}"')
link=${home}/.ssh/authsock-${host}
fake_new() {
  # $1: name; creates an empty fake /proc root with server-main of two threads
  fake=${tmp}/proc-${1}
  mkdir -p "${fake}/${server}/task/${server}" "${fake}/${server}/task/$((server + 1))" \
    "${fake}/net"
  printf '%s\0' node server-main.js >"${fake}/${server}/cmdline"
  printf 'Num       RefCount Protocol Flags    Type St Inode Path\n' >"${fake}/net/unix"
  printf '0000000000000000: 00000003 00000000 00000000 0001 03 777\n' >>"${fake}/net/unix"
  : >"${fake}/${server}/task/${server}/children"
  : >"${fake}/${server}/task/$((server + 1))/children"
  # the clock of bash without EPOCHREALTIME
  ln -s /proc/uptime "${fake}/uptime"
}
listen() {
  # $1: socket inode, $2: socket path, as a line of /proc/net/unix
  printf '0000000000000000: 00000002 00000000 00010000 0001 01 %s %s\n' "${1}" "${2}" \
    >>"${fake}/net/unix"
}
child() {
  # $1: pid, $2: start time, $3: process type, $4: SSH_AUTH_SOCK or -,
  # the rest: inodes of sockets held by the process
  local dir=${fake}/${1} inode fd=20 thread list
  mkdir -p "${dir}/fd"
  printf '%s\0' node bootstrap-fork "--type=${3}" --transformURIs >"${dir}/cmdline"
  printf '%s (a b) c) S %s 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' "${1}" \
    "${server}" "${2}" >"${dir}/stat"
  if [[ ${4} == '-' ]]; then
    printf 'HOME=/home/x\0' >"${dir}/environ"
  else
    printf 'HOME=/home/x\0SSH_AUTH_SOCK=%s\0LANG=C\0' "${4}" >"${dir}/environ"
  fi
  ln -s /dev/null "${dir}/fd/0"
  ln -s 'pipe:[11]' "${dir}/fd/1"
  for inode in "${@:5}"; do
    ln -s "socket:[${inode}]" "${dir}/fd/${fd}"
    fd=$((fd + 1))
  done
  # children of server-main are spread over its threads, the list is replaced atomically
  thread=$((server + ${1} % 2))
  list=$(cat "${fake}/${server}/task/${thread}/children")
  printf '%s%s ' "${list}" "${1}" >"${fake}/children.tmp"
  mv -f "${fake}/children.tmp" "${fake}/${server}/task/${thread}/children"
}
now_ms() {
  printf '%s\n' "$((${EPOCHREALTIME/[.,]/} / 1000))"
}
stamp() {
  # prefixes each line with the time of its arrival in milliseconds,
  # gives up after 40 seconds of silence
  local line
  while IFS= read -r -t 40 line; do
    printf '%s %s\n' "$((${EPOCHREALTIME/[.,]/} / 1000))" "${line}"
  done
}
# the command of the shell under test
result_cmd='builtin printf "RESULT:%s\n" "${SSH_AUTH_SOCK-}"'
shell_cmd=${result_cmd}
vscode_shell() {
  # $1: fake /proc root, $2: plain or login, $3: parent process type or none,
  # the rest: extra environment; sets result, said, last, noise, elapsed and gap (ms),
  # gap is the time between the first and the last message
  local flags=(-i) begin
  local -a times
  if [[ ${2} == 'login' ]]; then
    flags=(-l -i)
  fi
  begin=$(now_ms)
  # stdout goes to the file, stderr to stamp through the pipe
  timeout -k 1 30 "${base[@]}" "SSH_AGENT_STABLE_PROC=${1}" TERM_PROGRAM=vscode \
    "${@:4}" sh "${tmp}/pty.sh" "${1}" "${3}" "${flags[@]}" \
    -c "${shell_cmd}" </dev/null 2>&1 >"${tmp}/out" |
    stamp >"${tmp}/err"
  elapsed=$(($(now_ms) - begin))
  # a shell that exits before the command gives a result that no scenario expects
  if grep -q '^RESULT:' "${tmp}/out"; then
    result=$(sed -n 's/^RESULT://p' "${tmp}/out")
  else
    result='<no RESULT line>'
  fi
  sed 's/^[0-9]* //' "${tmp}/err" >"${tmp}/err.text"
  said=$(grep -c '^ssh-agent-stable: ' "${tmp}/err.text")
  last=$(grep '^ssh-agent-stable: ' "${tmp}/err.text" | tail -n 1)
  mapfile -t times < <(sed -n 's/^\([0-9]*\) ssh-agent-stable: .*/\1/p' "${tmp}/err")
  gap=0
  if [[ ${#times[@]} -gt 1 ]]; then
    gap=$((times[-1] - times[0]))
  fi
  # output that the profile prints without the logic is in the baseline
  noise=$({
    grep -v -e '^RESULT:' -e '^TRAP:' -e '^TRAPS:' -e '^DONE_MS:' -e '^DONE_LINES:' \
      -e '^DEBUG:' -e '^STATE_AFTER:' -e '^BG_AFTER:' -e '^OPTS:' "${tmp}/out"
    grep -v '^ssh-agent-stable: ' "${tmp}/err.text"
  } | grep -v -e 'cannot set terminal process group' -e 'no job control in this shell' |
    grep -cvxF -f "${tmp}/baseline-${2}")
}
quiet() {
  # $1: scenario name; no messages, no other output, no waiting
  check "${1}: no messages" '0' "${said}"
  check "${1}: no other output" '0' "${noise}"
  check "${1}: no waiting" 'yes' \
    "$(if ((elapsed < 2000)); then echo yes; else echo no; fi)"
}
target() {
  readlink "${link}" 2>/dev/null || printf 'none'
}
leftovers() {
  compgen -G "${home}/.ssh/.authsock*" | wc -l
}
# agents: with a key and empty ones, a socket without listener
ssh-keygen -q -t ed25519 -N '' -C test -f "${tmp}/key"
start_agent "${tmp}/a1.sock"
start_agent "${tmp}/a2.sock"
start_agent "${tmp}/a3.sock"
SSH_AUTH_SOCK=${tmp}/a1.sock ssh-add -q "${tmp}/key" 2>/dev/null
a1=$(readlink -e "${tmp}/a1.sock")
a2=$(readlink -e "${tmp}/a2.sock")
python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()' "${tmp}/dead.sock"
dead=$(readlink -e "${tmp}/dead.sock")
# links of Remote SSH: OLD is the link of a previous connection, still alive
OLD=${run}/vscode-ssh-auth-sock-100
L1=${run}/vscode-ssh-auth-sock-101
L2=${run}/vscode-ssh-auth-sock-102
L3=${run}/vscode-ssh-auth-sock-103
LS=${run}/vscode-ssh-auth-sock-198
LS2=${run}/vscode-ssh-auth-sock-197
LE=${run}/vscode-ssh-auth-sock-196
LE2=${run}/vscode-ssh-auth-sock-195
LR=${run}/vscode-ssh-auth-sock-194
LR2=${run}/vscode-ssh-auth-sock-193
LD=${run}/vscode-ssh-auth-sock-199
LL=${run}/vscode-ssh-auth-sock-104
ln -s "${tmp}/a1.sock" "${OLD}"
ln -s "${tmp}/a1.sock" "${L1}"
ln -s "${tmp}/a2.sock" "${L2}"
ln -s "${tmp}/a3.sock" "${L3}"
ln -s "${tmp}/a3.sock" "${LS}"
ln -s "${tmp}/a3.sock" "${LS2}"
ln -s "${tmp}/a3.sock" "${LE}"
ln -s "${tmp}/a3.sock" "${LE2}"
ln -s "${tmp}/a3.sock" "${LR}"
ln -s "${tmp}/a3.sock" "${LR2}"
ln -s "${tmp}/gone/agent.1" "${LD}"
mkdir "${tmp}/other"
ln -s "${tmp}/a2.sock" "${tmp}/other/vscode-ssh-auth-sock-7"
G1=${run}/vscode-git-1111111111.sock
G2=${run}/vscode-git-2222222222.sock
windows() {
  # $1: name, $2 and $3: start times of the extension hosts of windows 1 and 2
  fake_new "${1}"
  child 5000010 200 fileWatcher "${L3}"
  listen 9101 "${G1}"
  child 5000011 "${2}" extensionHost "${L1}" 9101
  listen 9102 "${G2}"
  child 5000012 "${3}" extensionHost "${L2}" 9102
}
# baseline output of the profile without the logic
windows baseline 110 120
for mode in plain login; do
  vscode_shell "${fake}" "${mode}" ptyHost SSH_AGENT_STABLE=off "SSH_AUTH_SOCK=${OLD}"
  {
    grep -v '^RESULT:' "${tmp}/out"
    cat "${tmp}/err.text"
  } >"${tmp}/baseline-${mode}"
done
check 'off keeps the value' "${OLD}" "${result}"
# new terminals
windows new 110 120
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${L1}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'new terminal keeps the agent of its window' "${L1}" "${result}"
quiet 'new terminal'
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${L1}"
check 'new terminal without git socket keeps its agent' "${L1}" "${result}"
quiet 'new terminal without git socket'
# the live link of another window with the git socket of window 1: the agent of the own
# window is taken
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'link of another window is replaced by the own one' "${L1}" "${result}"
quiet 'link of another window'
# restored terminals, usual path
: >"${tmp}/ssh-add.log"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'restored terminal leaves a live old link' "${L1}" "${result}"
quiet 'restored terminal'
check 'agents are checked by ssh-add' 'yes' \
  "$(if [[ -s ${tmp}/ssh-add.log ]]; then echo yes; else echo no; fi)"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G2}"
check 'restored terminal of the fresher window' "${L2}" "${result}"
windows older 130 120
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G2}"
check 'restored terminal of the older window' "${L2}" "${result}"
vscode_shell "${fake}" login ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G2}"
check 'login restored terminal' "${L2}" "${result}"
quiet 'login restored terminal'
profile_local 'source ~/.bashrc'
vscode_shell "${fake}" login ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G2}"
profile_local
check 'sourced twice' "${L2}" "${result}"
check 'sourced twice: no messages' '0' "${said}"
# two extension hosts on one git socket path: the freshest live one
fake_new same-git
listen 9101 "${G1}"
child 5000011 110 extensionHost "${L1}" 9101
listen 9103 "${G1}"
child 5000013 130 extensionHost "${L3}" 9103
listen 9104 "${G1}"
child 5000014 140 extensionHost "${LD}" 9104
listen 9102 "${G2}"
child 5000012 150 extensionHost "${L2}" 9102
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'one git socket path: the freshest live extension host' "${L3}" "${result}"
quiet 'one git socket path'
# the git socket is held by a hanging extension host with a dead link: the window is
# found, the candidate of another window is not taken, the value is kept after 3 s
fake_new hanging
listen 9190 "${G1}"
child 5000090 90 extensionHost "${LD}" 9190
child 5000012 120 extensionHost "${L2}" 9102
child 5000013 130 extensionHost "${L3}"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'hanging owner keeps the value' "${OLD}" "${result}"
check 'hanging owner: start and result messages' '2' "${said}"
check 'hanging owner: result message names the value' 'yes' \
  "$(if [[ ${last} == *"${OLD}"* ]]; then echo yes; else echo no; fi)"
check 'hanging owner: no other output' '0' "${noise}"
windows no-git 110 120
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'restored terminal without git socket: the freshest candidate' "${L2}" "${result}"
quiet 'restored terminal without git socket'
# extension hosts without a link of Remote SSH are skipped
fake_new foreign
child 5000011 110 extensionHost "${L1}"
child 5000015 150 extensionHost "${tmp}/a2.sock"
child 5000016 160 extensionHost -
child 5000017 170 extensionHost "${tmp}/other/vscode-ssh-auth-sock-7"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'foreign SSH_AUTH_SOCK of extension hosts is skipped' "${L1}" "${result}"
quiet 'foreign SSH_AUTH_SOCK of extension hosts'
# unreadable files: an extension host is skipped, process lists or sockets do nothing
windows unreadable 110 120
child 5000018 180 extensionHost "${L3}" 9101
rm -f -- "${fake}/5000018/environ"
mkdir "${fake}/5000018/environ"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'unreadable environ skips the extension host' "${L1}" "${result}"
quiet 'unreadable environ'
rm -f -- "${fake}/net/unix"
mkdir "${fake}/net/unix"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'unreadable net/unix keeps the value' "${OLD}" "${result}"
quiet 'unreadable net/unix'
windows no-children 110 120
rm -f -- "${fake}/${server}/task/$((server + 1))/children"
mkdir "${fake}/${server}/task/$((server + 1))/children"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'unreadable children keep the value' "${OLD}" "${result}"
quiet 'unreadable children'
windows no-fd 120 110
rm -rf -- "${fake}/5000011/fd"
: >"${fake}/5000011/fd"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'unreadable descriptors skip the extension host' "${L2}" "${result}"
quiet 'unreadable descriptors'
fake_new empty
vscode_shell "${fake}" plain ptyHost
check 'empty SSH_AUTH_SOCK without candidates' '' "${result}"
quiet 'empty SSH_AUTH_SOCK without candidates'
# the start of bash without the search, the reference for the shells below:
# the fastest of three shells, a delay of one of them does not raise it
startup=''
for i in 1 2 3; do
  vscode_shell "${fake}" plain ptyHost SSH_AGENT_STABLE=off
  if [[ -z ${startup} ]] || ((elapsed < startup)); then
    startup=${elapsed}
  fi
done
ready() {
  # $1: scenario name, $2: limit in ms, 3000 by default; the shell is ready in the limit
  # after the start of bash
  check "${1}: shell ready in ${2:-3000} ms" 'yes' \
    "$(if ((elapsed - startup < ${2:-3000})); then echo yes; else echo no; fi)"
}
after_message() {
  # in the background: waits up to 5 seconds for the first message of the shell under
  # test, 0.8 seconds more and runs $1
  local i
  for ((i = 0; i < 50; i++)); do
    if grep -q ' ssh-agent-stable: ' "${tmp}/err" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  sleep 0.8
  eval "${1}"
}
# race: the extension host of the window appears about a second after the shell started
fake_new race
child 5000090 90 extensionHost "${LD}" 9190
rm -f -- "${tmp}/err"
after_message 'listen 9191 "${G1}"; child 5000091 300 extensionHost "${L1}" 9191' &
racer=$!
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
wait "${racer}"
check 'race: switched to the late extension host' "${L1}" "${result}"
check 'race: start and result messages' '2' "${said}"
check 'race: result message names the value' 'yes' \
  "$(if [[ ${last} == *"${L1}"* ]]; then echo yes; else echo no; fi)"
check 'race: no other output' '0' "${noise}"
check 'race: within 3 seconds' 'yes' \
  "$(if ((gap < 3000)); then echo yes; else echo no; fi)"
ready 'race'
# the extension host never appears
fake_new never
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'no extension host keeps the value' "${OLD}" "${result}"
check 'no extension host: start and result messages' '2' "${said}"
check 'no extension host: result message names the value' 'yes' \
  "$(if [[ ${last} == *"${OLD}"* ]]; then echo yes; else echo no; fi)"
check 'no extension host: no other output' '0' "${noise}"
check 'no extension host: waits up to 3 seconds' 'yes' \
  "$(if ((gap >= 2000 && gap < 3000)); then echo yes; else echo no; fi)"
ready 'no extension host'
# the extension host of the window is found, but Remote SSH has not linked its <N> yet,
# while the agent of window 2 is alive: it is not taken; the own link that appears in
# 3 seconds is taken, otherwise the value is kept
own_late() {
  # $1: name
  fake_new "${1}"
  listen 9101 "${G1}"
  child 5000011 300 extensionHost "${LL}" 9101
  listen 9102 "${G2}"
  child 5000012 120 extensionHost "${L2}" 9102
}
own_late own-never
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'own link never appears: the value is kept' "${OLD}" "${result}"
check 'own link never appears: start and result messages' '2' "${said}"
check 'own link never appears: result message names the value' 'yes' \
  "$(if [[ ${last} == *"${OLD}"* ]]; then echo yes; else echo no; fi)"
check 'own link never appears: no other output' '0' "${noise}"
ready 'own link never appears'
own_late own-late
rm -f -- "${tmp}/err"
after_message 'ln -s "${tmp}/a3.sock" "${LL}"' &
racer=$!
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
wait "${racer}"
rm -f -- "${LL}"
check 'own link appears late: it is taken' "${LL}" "${result}"
check 'own link appears late: start and result messages' '2' "${said}"
check 'own link appears late: no other output' '0' "${noise}"
ready 'own link appears late'
# an agent that does not answer is checked once, the wait still ends in 3 seconds
fake_new silent
child 5000095 100 extensionHost "${LS}"
: >"${tmp}/ssh-add.log"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'silent agent keeps the value' "${OLD}" "${result}"
check 'silent agent is checked once' '1' "$(grep -c -e '-198$' "${tmp}/ssh-add.log")"
check 'silent agent: start and result messages' '2' "${said}"
check 'silent agent: waits up to 3 seconds' 'yes' \
  "$(if ((gap < 3000)); then echo yes; else echo no; fi)"
# the check of the silent agent is a part of 3 seconds
ready 'silent agent'
# two silent agents: the second check is cut by the rest of 3 seconds
fake_new silent-two
child 5000095 100 extensionHost "${LS}"
child 5000096 90 extensionHost "${LS2}"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'two silent agents keep the value' "${OLD}" "${result}"
check 'two silent agents: start and result messages' '2' "${said}"
ready 'two silent agents'
# two agents that answer with an error in 1.5 seconds, each search checks them again
fake_new slow-error
child 5000097 100 extensionHost "${LE}"
child 5000098 90 extensionHost "${LE2}"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'slow errors keep the value' "${OLD}" "${result}"
check 'slow errors: start and result messages' '2' "${said}"
ready 'slow errors'
# bash without EPOCHREALTIME (bash 4): the clock is the uptime of /proc
printf 'unset EPOCHREALTIME\n' >"${home}/.bashrc_local"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'uptime: slow errors keep the value' "${OLD}" "${result}"
check 'uptime: slow errors: start and result messages' '2' "${said}"
ready 'uptime: slow errors'
fake_new silent-two-uptime
child 5000095 100 extensionHost "${LS}"
child 5000096 90 extensionHost "${LS2}"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'uptime: two silent agents keep the value' "${OLD}" "${result}"
check 'uptime: two silent agents: start and result messages' '2' "${said}"
ready 'uptime: two silent agents'
fake_new never-uptime
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'uptime: no extension host keeps the value' "${OLD}" "${result}"
check 'uptime: no extension host: start and result messages' '2' "${said}"
ready 'uptime: no extension host'
# agents that refuse at once take no time: the older live candidate is found
fake_new refused-uptime
child 5000099 300 extensionHost "${LR}"
child 5000100 200 extensionHost "${LR2}"
child 5000101 100 extensionHost "${L3}"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'uptime: refusing agents are passed' "${L3}" "${result}"
# no clock at all: nothing is done
rm -f -- "${fake}/uptime"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}"
check 'no clock keeps the value' "${OLD}" "${result}"
quiet 'no clock'
rm -f -- "${home}/.bashrc_local"
# shells that are not started by the pty host and missing /proc
windows nested 110 120
vscode_shell "${fake}" plain fileWatcher "SSH_AUTH_SOCK=${OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'parent is not the pty host' "${OLD}" "${result}"
quiet 'parent is not the pty host'
vscode_shell "${tmp}/no-proc" plain none "SSH_AUTH_SOCK=${OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'missing /proc keeps the value' "${OLD}" "${result}"
quiet 'missing /proc'
# explicit values are kept and not checked
windows explicit 110 120
printf 'export SSH_AUTH_SOCK=%s/explicit.sock\n' "${tmp}" >"${home}/.bashrc_local"
: >"${tmp}/ssh-add.log"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${home}/.bashrc_local"
check 'explicit value from the profile is kept' "${tmp}/explicit.sock" "${result}"
check 'explicit value: ssh-add is not called' '0' "$(wc -l <"${tmp}/ssh-add.log")"
quiet 'explicit value'
# IFS of the user without a space, set before the logic is sourced: the start reads
# /proc as usual and keeps IFS
nl=$'\n'
k=0
for ifs in ':' "${nl}"; do
  k=$((k + 1))
  name="IFS ${ifs/${nl}/newline}"
  printf 'IFS=%q\n' "${ifs}" >"${home}/.bashrc_local"
  windows "ifs-start-${k}" 110 120
  shell_cmd='builtin printf "IFS_AFTER:%q\n" "${IFS}"
'${result_cmd}
  vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" \
    "VSCODE_GIT_IPC_HANDLE=${G1}"
  shell_cmd=${result_cmd}
  rm -f -- "${home}/.bashrc_local"
  check "${name} of the user: the start switches" "${L1}" "${result}"
  check "${name} of the user is kept" "$(printf '%q' "${ifs}")" \
    "$(sed -n 's/^IFS_AFTER://p' "${tmp}/out")"
done
# functions of the user named like builtins and options that change globs, comparisons
# and the run, set before the logic is sourced: the start searches and switches as
# usual and leaves the options as they were
user_env='shopt -s failglob nocasematch
set -u -f
read() { return 1; }
mapfile() { return 1; }
printf() { return 1; }
command() { return 1; }
exec() { return 1; }
trap() { return 1; }
shopt() { return 1; }
set() { return 1; }'
printf '%s\n' "${user_env}" >"${home}/.bashrc_local"
windows user-env 110 120
shell_cmd='o=
for x in failglob nocasematch nullglob; do
  if builtin shopt -q "${x}"; then
    o+="${x} "
  fi
done
builtin printf "OPTS:%s|%s\n" "${-//[!fu]/}" "${o}"
'${result_cmd}
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
shell_cmd=${result_cmd}
rm -f -- "${home}/.bashrc_local"
check 'functions and options of the user: the start switches' "${L1}" "${result}"
check 'functions and options of the user: the options are kept' \
  'fu|failglob nocasematch ' "$(sed -n 's/^OPTS://p' "${tmp}/out")"
quiet 'functions and options of the user'
# tmux pane and ssh login keep their values at shell start
vscode_shell "${fake}" plain ptyHost TERM_PROGRAM=tmux 'TMUX=/tmp/tmux-1/default,1,0' \
  "SSH_AUTH_SOCK=${tmp}/a2.sock" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'tmux pane keeps its agent' "${tmp}/a2.sock" "${result}"
login='SSH_CONNECTION=1 2 3 4'
out=$("${base[@]}" "${login}" "SSH_AUTH_SOCK=${tmp}/a2.sock" \
  bash -l -i -c 'printf "RESULT:%s\n" "${SSH_AUTH_SOCK-}"' \
  </dev/null 2>/dev/null | sed -n 's/^RESULT://p')
check 'ssh login keeps its agent' "${tmp}/a2.sock" "${out}"
check 'shell start does not create the link' 'none' "$(target)"
# Reload Window: the trap of SIGWINCH starts a handler in a background copy of the shell
# that moves the link kept at the start to the agent of the new connection; sshd before
# OpenSSH 10.1 puts the agent in /tmp/ssh-XXXXXXXXXX, a newer one in ~/.ssh/agent
if ! fwd=$(mktemp -d /tmp/ssh-XXXXXXXXXX); then
  printf 'mktemp -d /tmp/ssh-XXXXXXXXXX failed\n' >&2
  exit 1
fi
mkdir -p "${home}/.ssh/agent"
start_agent "${fwd}/agent.1"
start_agent "${home}/.ssh/agent/s.0123.sshd.4567"
fresh=$(readlink -e "${fwd}/agent.1")
fresh2=$(readlink -e "${home}/.ssh/agent/s.0123.sshd.4567")
RL_OLD=${run}/vscode-ssh-auth-sock-300
RL_NEW=${run}/vscode-ssh-auth-sock-301
RL_LATE=${run}/vscode-ssh-auth-sock-302
RL_NEW2=${run}/vscode-ssh-auth-sock-304
RL_FILE=${run}/vscode-ssh-auth-sock-305
RL_OVER1=${run}/vscode-ssh-auth-sock-306
RL_OVER2=${run}/vscode-ssh-auth-sock-307
RL_DELAY1=${run}/vscode-ssh-auth-sock-308
RL_DELAY2=${run}/vscode-ssh-auth-sock-309
RL_CHAIN1=${run}/vscode-ssh-auth-sock-312
RL_CHAIN2=${run}/vscode-ssh-auth-sock-313
RL_CHAIN3=${run}/vscode-ssh-auth-sock-314
RL_CHAIN4=${run}/vscode-ssh-auth-sock-315
RL_FAST1=${run}/vscode-ssh-auth-sock-320
RL_FAST2=${run}/vscode-ssh-auth-sock-321
RL_BUD1=${run}/vscode-ssh-auth-sock-322
RL_BUD2=${run}/vscode-ssh-auth-sock-323
RL_AGE=${run}/vscode-ssh-auth-sock-324
RL_AGE2=${run}/vscode-ssh-auth-sock-325
RL_AGE3=${run}/vscode-ssh-auth-sock-326
RL_K12A=${run}/vscode-ssh-auth-sock-327
RL_K12B=${run}/vscode-ssh-auth-sock-328
RL_K13=${run}/vscode-ssh-auth-sock-329
RL_K14=${run}/vscode-ssh-auth-sock-330
RL_TO=${run}/vscode-ssh-auth-sock-331
RO_OLD=${ro}/vscode-ssh-auth-sock-310
RO_NEW=${ro}/vscode-ssh-auth-sock-311
: >"${fwd}/agent.2"
ln -s "${fresh}" "${RL_NEW}"
ln -s "${fresh2}" "${RL_NEW2}"
ln -s "${fwd}/agent.2" "${RL_FILE}"
# start times of extension hosts against the uptime of 1000 seconds of the fake /proc:
# a second and 20 seconds ago
young=99900
aged=98000
# the shell under test marks that it is ready, waits for the go mark up to 5 seconds,
# runs WINCH_EVAL and sends SIGWINCH to itself WINCH_TIMES times, with WINCH_GO2 it
# waits for the mark go<n> up to 20 seconds before the signal <n>, WINCH_EVAL2 runs
# before the second and the next signals; it reports the time of each signal in ms,
# then runs WINCH_END, waits up to WINCH_WAIT ms till each handler has added its line
# to SSH_AGENT_STABLE_DONE and reports that time, the trap of SIGWINCH and
# SSH_AUTH_SOCK. With WINCH_COUNT a DEBUG trap counts its calls for kill -0 and for
# kill -WINCH. With WINCH_IFS the signal comes from outside while a command of a
# function with that IFS runs, after a reaped background job, a successful =~ and
# with the status 3, and the state of the interrupted code is reported after the trap
winch_cmd='sig_inside() {
  local IFS=${WINCH_IFS}
  { sleep 0 & } 2>/dev/null
  wait "$!"
  bg=$!
  jobs >/dev/null
  jobs -p -r >"${WINCH_DIR}/jobs0"
  jobs -p -s >>"${WINCH_DIR}/jobs0"
  sh -c "(sleep 0.1; kill -s WINCH \$1) &" _ "${1}"
  [[ abc-123 =~ ^([a-z]+)-([0-9]+)$ ]]
  sh -c "sleep 0.3; exit 3" _ last-word
  builtin printf "STATE_AFTER:%s|%s|%s|%s|%s|%q\n" "$?" "$_" "${BASH_REMATCH[0]}" \
    "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${IFS}"
  builtin printf "BG_AFTER:%s|%s\n" "${bg}" "$!"
  jobs -p -r >"${WINCH_DIR}/jobs"
  jobs -p -s >>"${WINCH_DIR}/jobs"
}
: >"${WINCH_DIR}/ready"
for ((n = 0; n < 100; n++)); do
  if [[ -e ${WINCH_DIR}/go ]]; then
    break
  fi
  sleep 0.05
done
eval "${WINCH_EVAL-}"
for ((n = 0; n < ${WINCH_TIMES:-1}; n++)); do
  if [[ -n ${WINCH_GO2-} && ${n} -gt 0 ]]; then
    for ((m = 0; m < 400; m++)); do
      if [[ -e ${WINCH_DIR}/go${n} ]]; then
        break
      fi
      sleep 0.05
    done
  fi
  if [[ ${n} -gt 0 ]]; then
    eval "${WINCH_EVAL2-}"
  fi
  t0=${EPOCHREALTIME/[.,]/}
  if [[ -n ${WINCH_IFS+x} ]]; then
    sig_inside $$
  elif [[ -n ${WINCH_COUNT-} ]]; then
    builtin trap "n_dbg=\$((n_dbg + 1))" DEBUG
    n_dbg=0
    kill -0 $$
    d0=${n_dbg}
    n_dbg=0
    kill -WINCH $$
    d1=${n_dbg}
    builtin trap - DEBUG
    builtin printf "DEBUG:%s|%s\n" "${d0}" "${d1}"
  else
    kill -WINCH $$
  fi
  t1=${EPOCHREALTIME/[.,]/}
  if [[ -z ${WINCH_IFS+x} ]]; then
    builtin printf "TRAP:%s\n" "$(((t1 - t0) / 1000))"
  fi
done
eval "${WINCH_END-}"
lines=()
for ((w = 0; ; w++)); do
  if [[ -f ${SSH_AGENT_STABLE_DONE} ]]; then
    builtin mapfile -t lines <"${SSH_AGENT_STABLE_DONE}"
  fi
  if ((${#lines[@]} >= ${WINCH_TIMES:-1} || w * 50 >= ${WINCH_WAIT:-15000})); then
    break
  fi
  sleep 0.05
done
t2=${EPOCHREALTIME/[.,]/}
if [[ $(builtin trap -p WINCH) != *ssa_winch* ]] ||
  ((${#lines[@]} >= ${WINCH_TIMES:-1})); then
  builtin printf "DONE_MS:%s\n" "$(((t2 - t1) / 1000))"
fi
builtin printf "DONE_LINES:%s|%s\n" "${#lines[@]}" "${WINCH_TIMES:-1}"
builtin printf "TRAPS:%s\n" "$(builtin trap -p WINCH)"
builtin printf "RESULT:%s\n" "${SSH_AUTH_SOCK-}"'
fake_winch() {
  # $1: name; a fake /proc whose uptime stands at 1000 seconds
  fake_new "winch-${1}"
  rm -f -- "${fake}/uptime"
  printf '1000.00 1.00\n' >"${fake}/uptime"
}
winch_windows() {
  # $1: name, $2: late if the extension host of window 1 does not hold its git socket
  # yet, none if there is no extension host of window 1; window 1 with the link RL_OLD
  # of a live old connection, window 2
  fake_winch "${1}"
  case ${2-} in
  late) child 5000011 110 extensionHost "${RL_OLD}" ;;
  none) ;;
  *)
    listen 9101 "${G1}"
    child 5000011 110 extensionHost "${RL_OLD}" 9101
    ;;
  esac
  listen 9102 "${G2}"
  child 5000012 120 extensionHost "${L2}" 9102
  ln -sfn "${tmp}/a1.sock" "${RL_OLD}"
}
new_host() {
  # $1: SSH_AUTH_SOCK of the new extension host of window 1, $2: its start time, young
  # by default; the old one is gone
  rm -rf -- "${fake}/5000011"
  listen 9111 "${G1}"
  child 5000021 "${2:-${young}}" extensionHost "${1}" 9111
}
# a fresher extension host of window 1 that comes besides the old one
host_new='listen 9111 "${G1}"; child 5000021 "${young}" extensionHost "${RL_NEW}" 9111'
host_late='listen 9111 "${G1}"; child 5000021 "${young}" extensionHost "${RL_LATE}" 9111'
reload() {
  # in the background: waits for the ready mark of the shell up to 10 seconds, runs $1,
  # sets the go mark and runs $2
  local i
  for ((i = 0; i < 100; i++)); do
    if [[ -e ${tmp}/ready ]]; then
      break
    fi
    sleep 0.1
  done
  eval "${1}"
  : >"${tmp}/go"
  eval "${2}"
}
after_done() {
  # $1: number of lines of the handlers to wait for up to 15 seconds, $2: command to run
  # then; sets the mark go$1 for the signal $1 of the shell under test
  local i
  for ((i = 0; i < 150; i++)); do
    if [[ -f ${tmp}/done ]] && (($(wc -l <"${tmp}/done") >= ${1})); then
      break
    fi
    sleep 0.1
  done
  eval "${2}"
  : >"${tmp}/go${1}"
}
outcomes='off|fast|no-host|foreign|stale|timeout'
outcomes+='|bad-dir|not-link|same|moved|created|failed'
winch_run() {
  # $1: command that changes the fake /proc before the signals, $2: command after the go
  # mark, the rest: extra environment; sets trap_ms (the slowest signal), traps, results
  # (the lines of the handlers in the order of their end) and done_ms (from the last
  # signal till the shell under test has seen all lines)
  rm -f -- "${tmp}/ready" "${tmp}/go" "${tmp}/go1" "${tmp}/go2" "${tmp}/mid" \
    "${tmp}/done" "${tmp}/jobs0" "${tmp}/jobs"
  reload "${1}" "${2}" &
  racer=$!
  shell_cmd=${winch_cmd}
  vscode_shell "${fake}" plain ptyHost "WINCH_DIR=${tmp}" \
    "SSH_AGENT_STABLE_DONE=${tmp}/done" "${@:3}"
  shell_cmd=${result_cmd}
  wait "${racer}"
  trap_ms=$(sed -n 's/^TRAP://p' "${tmp}/out" | sort -n | tail -n 1)
  traps=$(sed -n 's/^TRAPS://p' "${tmp}/out")
  done_ms=$(sed -n 's/^DONE_MS://p' "${tmp}/out")
  results=$(paste -s -d ' ' "${tmp}/done" 2>/dev/null)
  check "${fake##*/}: the shell under test runs to the end" 'yes' \
    "$(if [[ -n ${done_ms} ]]; then echo yes; else echo no; fi)"
  if [[ ${traps} == *ssa_winch* ]]; then
    done_lines=$(sed -n 's/^DONE_LINES://p' "${tmp}/out")
    check "${fake##*/}: a line of every handler by the end of the wait" \
      "${done_lines#*|} lines" "$(wc -l 2>/dev/null <"${tmp}/done" || echo 0) lines"
    check "${fake##*/}: the lines are known outcomes" '' \
      "$(grep -vxE "${outcomes}" "${tmp}/done" 2>/dev/null)"
  fi
  if [[ -n ${trap_ms} ]]; then
    check "${fake##*/}: the signal returns at once" 'yes' \
      "$(if ((trap_ms < 200)); then echo yes; else echo no; fi)"
  fi
}
sorted() {
  # $1: outcomes of the handlers; sorted, the order of the ends is not defined
  tr ' ' '\n' <<<"${1}" | sort | paste -s -d ' '
}
silent() {
  # $1: scenario name; no messages, no other output
  check "${1}: no messages" '0' "${said}"
  check "${1}: no other output" '0' "${noise}"
}
soon() {
  # $1: scenario name; the handler ends without waiting
  check "${1}: no waiting" 'yes' \
    "$(if ((done_ms < 1000)); then echo yes; else echo no; fi)"
}
kept() {
  # $1: scenario name; the link RL_OLD still leads to the old agent
  check "${1}: the link is kept" "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
}
moved_to() {
  # $1: scenario name, $2: socket; the link RL_OLD leads to it
  check "${1}: the link is moved" "${2}" "$(readlink "${RL_OLD}")"
}
no_tmp_names() {
  # $1: scenario name, $2: directory of the links, run by default
  check "${1}: no temporary names" '0' "$(compgen -G "${2:-${run}}/*.winch.*" | wc -l)"
}
# a resize: the link leads where the link of a live extension host does
winch_windows resize
winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'resize: the trap is set' \
  "trap -- '( ssa_winch & ) </dev/null >/dev/null' SIGWINCH" "${traps}"
check 'resize: the fast path' 'fast' "${results}"
check 'resize keeps the value' "${RL_OLD}" "${result}"
kept 'resize'
silent 'resize'
soon 'resize'
# a resize with a fresher extension host of the window that holds the git socket: the
# link still leads where the link of the old live one does
winch_windows resize-fresher
winch_run "${host_new}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'resize with a fresher host: the fast path' 'fast' "${results}"
kept 'resize with a fresher host'
silent 'resize with a fresher host'
# reload: the old extension host is gone, the new one has the link of the new connection
winch_windows reload
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'reload: moved' 'moved' "${results}"
check 'reload keeps the value' "${RL_OLD}" "${result}"
moved_to 'reload' "${fresh}"
check 'reload keeps the new link' "${fresh}" "$(readlink "${RL_NEW}")"
check 'reload keeps the link of another window' "${tmp}/a2.sock" "$(readlink "${L2}")"
SSH_AUTH_SOCK=${RL_OLD} ssh-add -l >/dev/null 2>&1
check 'reload: the old link reaches the new agent' '1' "$?"
silent 'reload'
no_tmp_names 'reload'
# shell integration of VS Code: a signal adds no call of the DEBUG trap of the shell,
# trap ssa_winch WINCH would add one
winch_windows count-resize
winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_COUNT=1
check 'DEBUG, resize: no extra call' '2|2' "$(sed -n 's/^DEBUG://p' "${tmp}/out")"
check 'DEBUG, resize: the fast path' 'fast' "${results}"
winch_windows count-reload
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_COUNT=1
check 'DEBUG, reload: no extra call' '2|2' "$(sed -n 's/^DEBUG://p' "${tmp}/out")"
check 'DEBUG, reload: moved' 'moved' "${results}"
moved_to 'DEBUG, reload' "${fresh}"
# set -T: the copies call the DEBUG trap that prints a mark to stdout like shell
# integration does, no mark reaches the output of the shell
for kind in resize reload; do
  winch_windows "functrace-${kind}"
  change=:
  outcome=fast
  if [[ ${kind} == 'reload' ]]; then
    change="new_host ${RL_NEW}"
    outcome=moved
  fi
  winch_run "${change}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" \
    'WINCH_EVAL=source "${WINCH_DIR}/copy-mark"' \
    'WINCH_END=builtin trap - DEBUG; set +T'
  check "set -T, ${kind}: no marks of the copies" '0' \
    "$(grep -c '^COPY:' "${tmp}/out")"
  check "set -T, ${kind}: ${outcome}" "${outcome}" "${results}"
done
moved_to 'set -T, reload' "${fresh}"
# the signal comes inside a function with another IFS after a reaped background job,
# =~ and a failure: $!, $_, $?, BASH_REMATCH and IFS of the interrupted code are kept,
# the trap adds no running or stopped job; the finished ( ... ) stays in jobs till the
# next prompt, there is none in bash -c
interrupted_state() {
  # $1: scenario name, $2: expected IFS as %q
  local bg
  check "${1}: \$?, \$_, BASH_REMATCH and IFS are kept" \
    "3|last-word|abc-123|abc|123|${2}" "$(sed -n 's/^STATE_AFTER://p' "${tmp}/out")"
  bg=$(sed -n 's/^BG_AFTER://p' "${tmp}/out")
  check "${1}: \$! is kept" 'yes' \
    "$(if [[ -n ${bg%|*} && ${bg%|*} == "${bg#*|}" ]]; then echo yes; else echo no; fi)"
  check "${1}: no running or stopped job" \
    "$(cat "${tmp}/jobs0" 2>/dev/null || echo none)" \
    "$(cat "${tmp}/jobs" 2>/dev/null || echo missing)"
}
nl=$'\n'
k=0
for ifs in ':' "${nl}"; do
  k=$((k + 1))
  name="IFS ${ifs/${nl}/newline}"
  winch_windows "ifs-resize-${k}"
  winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" "WINCH_IFS=${ifs}"
  check "resize, ${name}: the fast path" 'fast' "${results}"
  silent "resize, ${name}"
  interrupted_state "resize, ${name}" "$(printf '%q' "${ifs}")"
  winch_windows "ifs-reload-${k}"
  winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
    "VSCODE_GIT_IPC_HANDLE=${G1}" "WINCH_IFS=${ifs}"
  check "reload, ${name}: moved" 'moved' "${results}"
  moved_to "reload, ${name}" "${fresh}"
  silent "reload, ${name}"
  interrupted_state "reload, ${name}" "$(printf '%q' "${ifs}")"
done
# the link of the new connection appears 4 seconds after the signal, as ln of Remote
# SSH may do: the handler of a young extension host waits for it quietly
winch_windows late
rm -f -- "${RL_LATE}"
winch_run "new_host ${RL_LATE}" "sleep 4; ln -s ${fresh} ${RL_LATE}" \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'late link: moved' 'moved' "${results}"
moved_to 'late link' "${fresh}"
silent 'late link'
check 'late link: the handler waits for it' 'yes' \
  "$(if ((done_ms >= 3000 && done_ms < 10000)); then echo yes; else echo no; fi)"
# no agent of the new connection: a young extension host is awaited up to 10 seconds,
# then one message; an old one is not awaited, the handler is quiet
winch_windows young-none
rm -f -- "${RL_LATE}"
winch_run "new_host ${RL_LATE}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'young host without agent: timeout' 'timeout' "${results}"
kept 'young host without agent'
check 'young host without agent: one message' '1' "${said}"
check 'young host without agent: open a new terminal' 'yes' \
  "$(if [[ ${last} == *'open a new terminal' ]]; then echo yes; else echo no; fi)"
check 'young host without agent: no other output' '0' "${noise}"
check 'young host without agent: waits up to 10 seconds' 'yes' \
  "$(if ((done_ms >= 9000 && done_ms < 11500)); then echo yes; else echo no; fi)"
winch_windows old-none
rm -f -- "${RL_LATE}"
winch_run "new_host ${RL_LATE} ${aged}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'old host without agent: stale' 'stale' "${results}"
kept 'old host without agent'
silent 'old host without agent'
soon 'old host without agent'
# the new extension host does not hold the git socket of the terminal: the window is
# not found, the handler quits
winch_windows no-host
host_lost='rm -rf -- "${fake}/5000011"
child 5000021 "${young}" extensionHost "${RL_NEW}"'
winch_run "${host_lost}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'no host of the window: no-host' 'no-host' "${results}"
kept 'no host of the window'
silent 'no host of the window'
soon 'no host of the window'
# the shell starts before the extension host of its window opens the git socket and
# sees no resize before the reload: the reload moves its link
winch_windows late-owner late
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'late git socket: moved' 'moved' "${results}"
moved_to 'late git socket' "${fresh}"
silent 'late git socket'
# a hanging old extension host of the window holds the git socket too, with another
# link: the freshest one wins
winch_windows freshest
hanging_host='listen 9113 "${G1}"; child 5000013 200 extensionHost "${RL_NEW2}" 9113'
winch_run "new_host ${RL_NEW}; ${hanging_host}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'freshest owner: moved' 'moved' "${results}"
moved_to 'freshest owner' "${fresh}"
silent 'freshest owner'
# reconnection without a reload: the same extension host, Remote SSH points its link to
# the socket of the new connection; the terminal has survived a reload before, its link
# is not the one of the host
winch_windows reconnect
winch_run "new_host ${RL_NEW} ${aged}" "after_done 1 'ln -sfn ${fresh2} ${RL_NEW}'" \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 WINCH_GO2=1
check 'reconnect: moved twice' 'moved moved' "${results}"
moved_to 'reconnect' "${fresh2}"
silent 'reconnect'
ln -sfn "${fresh}" "${RL_NEW}"
# the link of the host leads to a dead socket at first: nothing changes, the next signal
# after a live socket appears moves the link
winch_windows reconnect-dead
steps="after_done 1 'ln -sfn ${tmp}/gone.sock ${RL_NEW}'"
steps+="; after_done 2 'readlink ${RL_OLD} >${tmp}/mid; ln -sfn ${fresh2} ${RL_NEW}'"
winch_run "new_host ${RL_NEW} ${aged}" "${steps}" "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=3 WINCH_GO2=1
check 'reconnect, dead socket: moved, stale, moved' 'moved stale moved' "${results}"
check 'reconnect, dead socket: the link is kept meanwhile' "${fresh}" \
  "$(cat "${tmp}/mid")"
moved_to 'reconnect, dead socket' "${fresh2}"
silent 'reconnect, dead socket'
ln -sfn "${fresh}" "${RL_NEW}"
# a raw path of an agent in environ of the new extension host and a link to a file that
# is not a socket are not taken
winch_windows raw
winch_run "new_host ${fresh} ${aged}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'raw path: stale' 'stale' "${results}"
kept 'raw path'
silent 'raw path'
winch_windows regular-file
winch_run "new_host ${RL_FILE} ${aged}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'regular file target: stale' 'stale' "${results}"
kept 'regular file target'
silent 'regular file target'
# a socket outside /tmp, as sshd of OpenSSH 10.1 and newer has it, is taken
winch_windows outside-tmp
winch_run "new_host ${RL_NEW2}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'socket in ~/.ssh/agent: moved' 'moved' "${results}"
moved_to 'socket in ~/.ssh/agent' "${fresh2}"
silent 'socket in ~/.ssh/agent'
# the kept link removed after the start is created again, a regular file in its place
# is not touched
winch_windows removed-link
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" 'WINCH_EVAL=rm -f -- "${SSH_AUTH_SOCK}"'
check 'removed link: created' 'created' "${results}"
moved_to 'removed link' "${fresh}"
silent 'removed link'
winch_windows file-link
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" \
  'WINCH_EVAL=rm -f -- "${SSH_AUTH_SOCK}"; : >"${SSH_AUTH_SOCK}"'
check 'regular file in place of the link: not-link' 'not-link' "${results}"
check 'regular file in place of the link is kept' 'yes' \
  "$(if [[ -f ${RL_OLD} && ! -L ${RL_OLD} ]]; then echo yes; else echo no; fi)"
silent 'regular file in place of the link'
rm -f -- "${RL_OLD}"
# the shell starts with the link of window 2 before the git socket of window 1 is open,
# then window 1 reloads: the link of window 2 is neither moved nor awaited, whether its
# agent is alive (the fast path) or not
winch_windows foreign-live none
rm -f -- "${RL_LATE}"
winch_run "${host_late}" : "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'link of another window, live agent: fast' 'fast' "${results}"
check 'link of another window, live agent: the value is kept' "${L2}" "${result}"
check 'link of another window, live agent: not moved' "${tmp}/a2.sock" \
  "$(readlink "${L2}")"
silent 'link of another window, live agent'
soon 'link of another window, live agent'
winch_windows foreign-dead none
rm -f -- "${RL_LATE}"
winch_run "${host_late}; ln -sfn ${tmp}/gone.sock ${L2}" : "SSH_AUTH_SOCK=${L2}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'link of another window, dead agent: foreign' 'foreign' "${results}"
check 'link of another window, dead agent: not moved' "${tmp}/gone.sock" \
  "$(readlink "${L2}")"
silent 'link of another window, dead agent'
soon 'link of another window, dead agent'
# the link of window 2 leads to the same agent as the link of window 1 after the reload
winch_windows shared-agent none
ln -sfn "${fresh}" "${L2}"
winch_run "${host_new}" : "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'shared agent: fast' 'fast' "${results}"
check 'shared agent: the link is not moved' "${fresh}" "$(readlink "${L2}")"
silent 'shared agent'
ln -sfn "${tmp}/a2.sock" "${L2}"
# ln or mv fails, here in a directory without the write permission: one message for a
# young extension host, none for an old one, no temporary names are left
if [[ ${EUID} -eq 0 ]]; then
  printf 'SKIP failed move: root writes to a directory without the write permission\n'
else
  mkdir -p "${ro}"
  ln -sfn "${fresh}" "${RO_NEW}"
  for age in young aged; do
    fake_winch "ro-${age}"
    listen 9101 "${G1}"
    child 5000011 110 extensionHost "${RO_OLD}" 9101
    ln -sfn "${tmp}/a1.sock" "${RO_OLD}"
    winch_run "new_host ${RO_NEW} ${!age}; chmod 500 ${ro}" : "SSH_AUTH_SOCK=${RO_OLD}" \
      "VSCODE_GIT_IPC_HANDLE=${G1}" "XDG_RUNTIME_DIR=${ro}"
    chmod 700 "${ro}"
    check "failed move, ${age} host: failed" 'failed' "${results}"
    check "failed move, ${age} host: the link is kept" "${tmp}/a1.sock" \
      "$(readlink "${RO_OLD}")"
    check "failed move, ${age} host: no other output" '0' "${noise}"
    no_tmp_names "failed move, ${age} host" "${ro}"
    if [[ ${age} == 'young' ]]; then
      check 'failed move, young host: one message' '1' "${said}"
      check 'failed move, young host: open a new terminal' 'yes' \
        "$(if [[ ${last} == *'open a new terminal' ]]; then echo yes; else echo no; fi)"
    else
      check 'failed move, old host: no messages' '0' "${said}"
    fi
  done
fi
# several signals during the waiting: one link moved to the right agent, no messages
winch_windows burst
rm -f -- "${RL_LATE}"
winch_run "new_host ${RL_LATE}" "sleep 2; ln -s ${fresh} ${RL_LATE}" \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=3 \
  'WINCH_EVAL2=sleep 0.3'
check 'burst: a line per signal' '3' "$(wc -l <"${tmp}/done")"
check 'burst: each moves the link or finds it moved' '' \
  "$(grep -vx -e moved -e same "${tmp}/done")"
moved_to 'burst' "${fresh}"
silent 'burst'
no_tmp_names 'burst'
# leftovers of killed handlers under the temporary names of the next thousand pids and
# of the pid of the shell: the own one is replaced, the one of the pid of the shell is
# not, a failed ln ends the attempts; on a busy host or at the wrap of pids the pid of
# the handler may fall outside them, then the run is repeated up to 3 times and the
# check of the own one is skipped after the last one
stale_names='echo "$$" >"${WINCH_DIR}/shell-pid"
p=$(sh -c "echo \$\$")
names=("/nonexistent/${SSH_AUTH_SOCK##*/}.winch.$$")
for ((i = p; i < p + 1000; i++)); do
  names+=("/nonexistent/${SSH_AUTH_SOCK##*/}.winch.${i}")
done
ln -s "${names[@]}" "${SSH_AUTH_SOCK%/*}/"'
for attempt in 1 2 3; do
  rm -f -- "${run}"/*.winch.*
  winch_windows "leftover-names-${attempt}"
  winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
    "VSCODE_GIT_IPC_HANDLE=${G1}" "WINCH_EVAL=${stale_names}"
  left=$(compgen -G "${run}/*.winch.*" | wc -l)
  if [[ ${results} != 'moved' || ${left} -ne 1001 ]]; then
    break
  fi
done
check 'leftover names: moved' 'moved' "${results}"
moved_to 'leftover names' "${fresh}"
silent 'leftover names'
shell_pid=$(cat "${tmp}/shell-pid")
check 'leftover names: the one of the pid of the shell is kept' 'yes' \
  "$(if [[ -L ${RL_OLD}.winch.${shell_pid} ]]; then echo yes; else echo no; fi)"
if [[ ${results} == 'moved' && ${left} -eq 1001 ]]; then
  printf 'SKIP leftover names: the pid of the handler fell outside 3 times\n'
else
  check 'leftover names: the own one is taken' '1000' "${left}"
fi
rm -f -- "${run}"/*.winch.*
# the value of the shell changed after the start: the kept link is moved all the same,
# the value is not touched
winch_windows explicit-later
winch_run "new_host ${RL_NEW}" : "WINCH_EVAL=SSH_AUTH_SOCK=${tmp}/a2.sock" \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'explicit value after the start: moved' 'moved' "${results}"
check 'explicit value after the start is kept' "${tmp}/a2.sock" "${result}"
moved_to 'explicit value after the start' "${fresh}"
silent 'explicit value after the start'
# a second reload of the same window moves the same link to the next connection
second_reload() {
  # keeps where the link RL_OLD points in mid and replaces the extension host of window 1
  # once more
  readlink "${RL_OLD}" >"${tmp}/mid"
  rm -rf -- "${fake}/5000021"
  listen 9121 "${G1}"
  child 5000031 "${young}" extensionHost "${RL_NEW2}" 9121
}
winch_windows twice
winch_run "new_host ${RL_NEW}" 'after_done 1 second_reload' "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 WINCH_GO2=1
check 'twice: moved twice' 'moved moved' "${results}"
check 'twice: the first reload moves the link' "${fresh}" "$(cat "${tmp}/mid")"
moved_to 'twice' "${fresh2}"
silent 'twice'
# a second reload comes while the handler of the first one waits for the link of its
# extension host: the first handler follows the fresher host, the late link of the
# outdated one does not take the link RL_OLD back
overlap_steps() {
  # replaces the extension host of window 1 once more with the fresher one that has a
  # live link, lets the second signal come, then the link of the outdated host appears
  sleep 1
  rm -rf -- "${fake}/5000021"
  listen 9131 "${G1}"
  child 5000041 99950 extensionHost "${RL_OVER2}" 9131
  ln -sfn "${fresh2}" "${RL_OVER2}"
  : >"${tmp}/go1"
  after_done 1 "ln -sfn ${fresh} ${RL_OVER1}"
}
winch_windows overlap
rm -f -- "${RL_OVER1}"
winch_run "new_host ${RL_OVER1}" overlap_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 WINCH_GO2=1
# the order of the handlers depends on the speed of the machine: the second one moves
# first and the first one finds the link done, the first one moves first and the
# second one takes the fast path, or both test the link before either moves
ended=$(sorted "${results}")
case ${ended} in
'moved same' | 'fast moved' | 'moved moved') ended='moved, same or fast' ;;
esac
check 'overlap: both handlers end' 'moved, same or fast' "${ended}"
moved_to 'overlap' "${fresh2}"
silent 'overlap'
no_tmp_names 'overlap'
# a handler is delayed between the choice of the agent and the move: a fresher host of
# the window comes and the second handler moves the link to it first, the delayed one
# must not leave the link at the outdated agent; the first ln of the shell under test
# waits for the removal of the mark, the wrapper exists only during the scenario
delay_steps() {
  # waits for the first handler to stop in ln, replaces its host with the fresher one
  # that has a live link, lets the second signal come, after the line of the second
  # handler removes the mark
  wait_for -e "${tmp}/ln.1"
  rm -rf -- "${fake}/5000021"
  listen 9131 "${G1}"
  child 5000041 99950 extensionHost "${RL_DELAY2}" 9131
  ln -sfn "${fresh2}" "${RL_DELAY2}"
  : >"${tmp}/go1"
  wait_for -s "${tmp}/done"
  rm -f -- "${tmp}/hold.1"
}
real_ln=$(command -v ln)
# the first three calls of ln of the shell under test take the numbers 1 to 3 by the
# marks ln.<n>, made atomically, and each waits up to 10 seconds for the removal of its
# mark hold.<n>; the other calls and the calls without a mark hold.<n> are not delayed
cat >"${tmp}/bin/ln" <<EOF
#!/usr/bin/env bash
for n in 1 2 3; do
  if ( set -C; : >${tmp}/ln.\${n} ) 2>/dev/null; then
    for ((i = 0; i < 100; i++)); do
      [[ -e ${tmp}/hold.\${n} ]] || break
      sleep 0.1
    done
    break
  fi
done
exec ${real_ln} "\${@}"
EOF
chmod 755 "${tmp}/bin/ln"
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
winch_windows delay
rm -f -- "${RL_DELAY1}"
winch_run "new_host ${RL_DELAY1}; ln -sfn ${fresh} ${RL_DELAY1}; : >${tmp}/hold.1" \
  delay_steps "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 \
  WINCH_GO2=1
check 'delay: both handlers end' 'moved moved' "$(sorted "${results}")"
moved_to 'delay' "${fresh2}"
silent 'delay'
no_tmp_names 'delay'
# the first handler moves the link to the agent of four hosts one after another, each
# time a fresher host comes while it waits in ln, the second handler is quick: its move
# to the last host comes before the last move of the first one, which must check again
chain_step() {
  # $1: number of ln to wait for, $2: pid of the extension host to replace, $3: pid of the
  # next one, $4: its start time, $5: its link, $6: agent of the link, $7: socket inode
  wait_for -e "${tmp}/ln.${1}"
  rm -rf -- "${fake:?}/${2:?}"
  listen "${7}" "${G1}"
  child "${3}" "${4}" extensionHost "${5}" "${7}"
  ln -sfn "${6}" "${5}"
}
chain_steps() {
  chain_step 1 5000021 5000041 99920 "${RL_CHAIN2}" "${fresh2}" 9141
  rm -f -- "${tmp}/hold.1"
  chain_step 2 5000041 5000042 99940 "${RL_CHAIN3}" "${fresh}" 9142
  rm -f -- "${tmp}/hold.2"
  chain_step 3 5000042 5000043 99960 "${RL_CHAIN4}" "${fresh2}" 9143
  : >"${tmp}/go1"
  wait_for -s "${tmp}/done"
  rm -f -- "${tmp}/hold.3"
}
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
winch_windows chain
rm -f -- "${RL_CHAIN1}" "${RL_CHAIN2}" "${RL_CHAIN3}" "${RL_CHAIN4}"
winch_run "new_host ${RL_CHAIN1}; ln -sfn ${fresh} ${RL_CHAIN1}; : >${tmp}/hold.1; \
  : >${tmp}/hold.2; : >${tmp}/hold.3" chain_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 WINCH_GO2=1
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
check 'chain: both handlers end' 'fast moved' "$(sorted "${results}")"
moved_to 'chain' "${fresh2}"
silent 'chain'
no_tmp_names 'chain'
# the first handler is delayed in ln after it chose the agent of the host A; a fresher
# host B of the window comes without a link, host A stays alive; the handler follows
# host B and waits for its link
fresher_host() {
  # $1: link of the new host, none yet; waits for the first handler to stop in ln
  wait_for -e "${tmp}/ln.1"
  listen 9131 "${G1}"
  child 5000041 99950 extensionHost "${1}" 9131
}
# the second handler ends on the fast path, as the link already leads where the link of
# the live host A does, so nobody else moves the terminal to host B
fast_steps() {
  fresher_host "${RL_FAST2}"
  ln -sfn "${fresh}" "${RL_OLD}"
  : >"${tmp}/go1"
  wait_for -s "${tmp}/done"
  rm -f -- "${tmp}/hold.1"
  sleep 1
  ln -sfn "${fresh2}" "${RL_FAST2}"
}
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
winch_windows fastpath
rm -f -- "${RL_FAST1}" "${RL_FAST2}"
winch_run "new_host ${RL_FAST1}; ln -sfn ${fresh} ${RL_FAST1}; : >${tmp}/hold.1" \
  fast_steps "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 \
  WINCH_GO2=1
check 'fastpath: the second handler is quick, the first moves' 'fast moved' "${results}"
moved_to 'fastpath' "${fresh2}"
silent 'fastpath'
no_tmp_names 'fastpath'
# the link of host A comes after 7 seconds, the link of host B 5 seconds after it came:
# more than 10 seconds after the signal, less than 10 after host B
budget_steps() {
  sleep 7
  ln -sfn "${fresh}" "${RL_BUD1}"
  fresher_host "${RL_BUD2}"
  rm -f -- "${tmp}/hold.1"
  sleep 5
  ln -sfn "${fresh2}" "${RL_BUD2}"
}
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
winch_windows budget
rm -f -- "${RL_BUD1}" "${RL_BUD2}"
winch_run "new_host ${RL_BUD1}; : >${tmp}/hold.1" budget_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_WAIT=30000
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
check 'budget: moved' 'moved' "${results}"
moved_to 'budget' "${fresh2}"
silent 'budget'
no_tmp_names 'budget'
# a reconnection without a reload while the first handler is delayed in ln: the link of
# the same host leads to another agent now, the second handler moves the link there, the
# delayed one overwrites it and must move it again
same_host_steps() {
  # waits for the first handler to stop in ln, points the link of its host to the other
  # agent, lets the second signal come, after the line of the second handler removes
  # the mark
  wait_for -e "${tmp}/ln.1"
  ln -sfn "${fresh2}" "${RL_K13}"
  : >"${tmp}/go1"
  wait_for -s "${tmp}/done"
  rm -f -- "${tmp}/hold.1"
}
rm -f -- "${tmp}"/hold.* "${tmp}"/ln.*
winch_windows same-host
rm -f -- "${RL_K13}"
winch_run "new_host ${RL_K13}; ln -sfn ${fresh} ${RL_K13}; : >${tmp}/hold.1" \
  same_host_steps "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 \
  WINCH_GO2=1
rm -f -- "${tmp}/bin/ln" "${tmp}"/hold.* "${tmp}"/ln.*
check 'same host: moved twice' 'moved moved' "${results}"
moved_to 'same host' "${fresh2}"
silent 'same host'
no_tmp_names 'same host'
# every host is awaited for its own 10 seconds: host A without a link is awaited for 8
# seconds, a fresher host B without a link comes for a second, the link of A comes 14
# seconds after the first choice of A: it is too late, no rest of the time of B counts
return_steps() {
  sleep 8
  listen 9131 "${G1}"
  child 5000041 99950 extensionHost "${RL_K12B}" 9131
  sleep 1
  rm -rf -- "${fake}/5000041"
  sleep 5
  ln -sfn "${fresh2}" "${RL_K12A}"
}
winch_windows time-per-host
rm -f -- "${RL_K12A}" "${RL_K12B}"
winch_run "new_host ${RL_K12A}" return_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_WAIT=30000
check 'time per host: timeout' 'timeout' "${results}"
kept 'time per host'
check 'time per host: one message' '1' "${said}"
check 'time per host: no other output' '0' "${noise}"
check 'time per host: waits up to 10 seconds' 'yes' \
  "$(if ((done_ms >= 9000 && done_ms < 11500)); then echo yes; else echo no; fi)"
no_tmp_names 'time per host'
# the age of a host is taken once: the host is 14 seconds old at the signal, a second
# later the clock stands 2 seconds ahead and the host is 16 seconds old, its link comes
# a second after that: the waiting for a young host lasts up to 10 seconds even if it
# becomes old
age_steps() {
  sleep 1
  printf '1002.00 1.00\n' >"${fake}/uptime"
  sleep 1
  ln -sfn "${fresh2}" "${RL_AGE}"
}
winch_windows age
rm -f -- "${RL_AGE}"
winch_run "new_host ${RL_AGE} 98600" age_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'age: moved' 'moved' "${results}"
moved_to 'age' "${fresh2}"
silent 'age'
no_tmp_names 'age'
# the age of every host is kept: host A is 14 seconds old at the signal, a fresher host
# B comes and goes before its link appears, the clock stands 2 seconds ahead and the
# handler returns to host A, 16 seconds old by now, its link comes a second later
age_return_steps() {
  sleep 0.5
  listen 9131 "${G1}"
  child 5000041 99950 extensionHost "${RL_AGE3}" 9131
  sleep 1
  rm -rf -- "${fake}/5000041"
  printf '1002.00 1.00\n' >"${fake}/uptime"
  sleep 1
  ln -sfn "${fresh2}" "${RL_AGE2}"
}
winch_windows age-return
rm -f -- "${RL_AGE2}" "${RL_AGE3}"
winch_run "new_host ${RL_AGE2} 98600" age_return_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'age, return: moved' 'moved' "${results}"
moved_to 'age, return' "${fresh2}"
silent 'age, return'
no_tmp_names 'age, return'
# the link of the terminal is held by no live host at first; while the handler awaits
# the link of its host, a host of another window that holds it comes: the handler quits
# quietly, the own link that appears later does not move it
foreign_steps() {
  sleep 1
  child 5000051 130 extensionHost "${RL_OLD}"
  sleep 1
  ln -sfn "${fresh}" "${RL_K14}"
}
winch_windows foreign-later
rm -f -- "${RL_K14}"
winch_run "new_host ${RL_K14}" foreign_steps "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'link of another window while waiting: foreign' 'foreign' "${results}"
kept 'link of another window while waiting'
silent 'link of another window while waiting'
no_tmp_names 'link of another window while waiting'
# mv fails after ln has made the temporary name: the link is kept, the temporary name is
# removed, one message for a young host; the wrapper of mv exists only in the scenario
printf '#!/bin/sh\nexit 1\n' >"${tmp}/bin/mv"
chmod 755 "${tmp}/bin/mv"
winch_windows mv-fails
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${tmp}/bin/mv"
check 'failed mv: failed' 'failed' "${results}"
kept 'failed mv'
check 'failed mv: one message' '1' "${said}"
check 'failed mv: open a new terminal' 'yes' \
  "$(if [[ ${last} == *'open a new terminal' ]]; then echo yes; else echo no; fi)"
check 'failed mv: no other output' '0' "${noise}"
no_tmp_names 'failed mv'
# mv fails after the link of the terminal has been moved to the agent of its window by
# another handler: failed, no message
printf '#!/bin/sh\n%s -sfn %s %s\nexit 1\n' "${real_ln}" "${fresh}" "${RL_OLD}" \
  >"${tmp}/bin/mv"
chmod 755 "${tmp}/bin/mv"
winch_windows mv-fails-settled
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${tmp}/bin/mv"
check 'failed mv, link settled meanwhile: failed' 'failed' "${results}"
moved_to 'failed mv, link settled meanwhile' "${fresh}"
silent 'failed mv, link settled meanwhile'
no_tmp_names 'failed mv, link settled meanwhile'
# the clock is lost when the handler would start to wait for the link of its host, dead
# at first; by then the link of the host has come and another handler has moved the link
# of the terminal to it: timeout without waiting, no message. The wrapper of readlink
# acts once, after the first check of the link of the host, and exists only here
real_readlink=$(command -v readlink)
cat >"${tmp}/bin/readlink" <<EOF
#!/usr/bin/env bash
${real_readlink} "\${@}"
rc=\$?
if [[ " \${*} " == *" -e "* && " \${*} " == *" ${RL_TO} "* ]] &&
  ( set -C; : >${tmp}/readlink.mark ) 2>/dev/null; then
  ${real_ln} -sfn ${fresh} ${RL_TO}
  ${real_ln} -sfn ${fresh} ${RL_OLD}
  rm -f -- ${tmp}/proc-winch-timeout-settled/uptime
fi
exit \${rc}
EOF
chmod 755 "${tmp}/bin/readlink"
printf 'unset EPOCHREALTIME\n' >"${home}/.bashrc_local"
rm -f -- "${tmp}/readlink.mark"
winch_windows timeout-settled
ln -sfn "${tmp}/gone.sock" "${RL_TO}"
winch_run "new_host ${RL_TO}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${tmp}/bin/readlink" "${home}/.bashrc_local"
check 'timeout, link settled meanwhile: the wrapper acted' 'yes' \
  "$(if [[ -e ${tmp}/readlink.mark ]]; then echo yes; else echo no; fi)"
check 'timeout, link settled meanwhile: timeout' 'timeout' "${results}"
moved_to 'timeout, link settled meanwhile' "${fresh}"
silent 'timeout, link settled meanwhile'
no_tmp_names 'timeout, link settled meanwhile'
# functions of the user named like builtins and options set before the logic is
# sourced do not break the handler
printf '%s\n' "${user_env}" >"${home}/.bashrc_local"
winch_windows user-env
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${home}/.bashrc_local"
check 'functions and options of the user, reload: moved' 'moved' "${results}"
moved_to 'functions and options of the user, reload' "${fresh}"
silent 'functions and options of the user, reload'
# XDG_RUNTIME_DIR is a sticky directory of root, like /tmp without it: the trap is set
# and moves the link
sticky_link() {
  # $1: target; links it under a free name /tmp/vscode-ssh-auth-sock-<digits>, keeps
  # the name in sticky for the cleanup and in sticky_name
  local i name
  for ((i = 0; i < 100; i++)); do
    name=/tmp/vscode-ssh-auth-sock-$$${RANDOM}
    if ln -s "${1}" "${name}" 2>/dev/null; then
      sticky+=("${name}")
      sticky_name=${name}
      return 0
    fi
  done
  return 1
}
if [[ -k /tmp && ! -O /tmp && ! -L /tmp ]] && sticky_link "${tmp}/a1.sock"; then
  ST_OLD=${sticky_name}
  sticky_link "${fresh}"
  ST_NEW=${sticky_name}
  fake_winch sticky
  listen 9101 "${G1}"
  child 5000011 110 extensionHost "${ST_OLD}" 9101
  winch_run "new_host ${ST_NEW}" : "SSH_AUTH_SOCK=${ST_OLD}" \
    "VSCODE_GIT_IPC_HANDLE=${G1}" XDG_RUNTIME_DIR=/tmp
  check 'sticky directory: the trap is set' 'yes' \
    "$(if [[ ${traps} == *ssa_winch* ]]; then echo yes; else echo no; fi)"
  check 'sticky directory: moved' 'moved' "${results}"
  check 'sticky directory: the link is moved' "${fresh}" "$(readlink "${ST_OLD}")"
  silent 'sticky directory'
  check 'sticky directory: no temporary names' '0' \
    "$(compgen -G "${ST_OLD}.winch.*" | wc -l)"
else
  printf 'SKIP sticky directory: /tmp is not a sticky directory of another user\n'
fi
# no trap without the git socket of the window or with a value at the start that is not
# a link of Remote SSH
winch_windows no-git
winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" WINCH_WAIT=0
check 'no git socket: no trap' '' "${traps}"
printf 'export SSH_AUTH_SOCK=%s/a1.sock\n' "${tmp}" >"${home}/.bashrc_local"
winch_windows not-link
winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_WAIT=0
rm -f -- "${home}/.bashrc_local"
check 'explicit value at the start: no trap' '' "${traps}"
# SSH_AGENT_STABLE=off: no trap; set after the start: the handler does nothing
winch_windows off
winch_run "new_host ${RL_NEW}" : SSH_AGENT_STABLE=off "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_WAIT=0
check 'off: no trap' '' "${traps}"
check 'off: no handler' '' "${results}"
kept 'off'
winch_windows off-later
winch_run "new_host ${RL_NEW}" : 'WINCH_EVAL=SSH_AGENT_STABLE=off' \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'off after the start: off' 'off' "${results}"
kept 'off after the start'
silent 'off after the start'
# a trap of SIGWINCH from the profile is kept
printf "trap ':' WINCH\n" >"${home}/.bashrc_local"
winch_windows foreign-trap
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" \
  WINCH_WAIT=0
rm -f -- "${home}/.bashrc_local"
check 'foreign trap is kept' "trap -- ':' SIGWINCH" "${traps}"
check 'foreign trap: no handler' '' "${results}"
kept 'foreign trap'
# no clock: the age of the host is unknown and counts as old, one check without waiting
printf 'unset EPOCHREALTIME\n' >"${home}/.bashrc_local"
winch_windows no-clock
rm -f -- "${fake}/uptime" "${RL_LATE}"
winch_run "new_host ${RL_LATE}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'no clock, no agent: stale' 'stale' "${results}"
kept 'no clock, no agent'
silent 'no clock, no agent'
winch_windows no-clock-agent
rm -f -- "${fake}/uptime"
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${home}/.bashrc_local"
check 'no clock, live agent: moved' 'moved' "${results}"
moved_to 'no clock, live agent' "${fresh}"
silent 'no clock, live agent'
# tmx and scrrr from .bash_profile, scrrr from .bashrc
mux() {
  # $1: tmx or scrrr, the rest: extra environment; sets out and calls
  : >"${tmp}/mux.log"
  out=$("${base[@]}" "${login}" "${@:2}" \
    bash -l -i -c "PATH=\${SHIMS}:\${PATH}; ${1}; echo AFTER" </dev/null 2>/dev/null)
  calls=$(paste -s -d ' ' "${tmp}/mux.log")
}
started='-u new-session -AD -s tester-0'
mux tmx "SSH_AUTH_SOCK=${tmp}/a1.sock"
check 'tmx starts tmux with the link' "tmux|${link}|${started}" "${calls}"
check 'tmx exits the shell' '0' "$(grep -c AFTER <<<"${out}")"
check 'tmx links its own socket' "${a1}" "$(target)"
mux tmx "SSH_AUTH_SOCK=${tmp}/dead.sock"
check 'socket without listener is published' "tmux|${link}|${started}" "${calls}"
check 'link to a socket without listener' "${dead}" "$(target)"
mux scrrr "SSH_AUTH_SOCK=${tmp}/a2.sock"
check 'scrrr runs screen with the link' "screen|${link}|-wipe screen|${link}|-D -RR" \
  "${calls}"
check 'scrrr exits the shell' '0' "$(grep -c AFTER <<<"${out}")"
check 'scrrr links its own socket' "${a2}" "$(target)"
mux tmx "SSH_AUTH_SOCK=${link}"
check 'link is passed again' "tmux|${link}|${started}" "${calls}"
check 'link does not point to itself' "${a2}" "$(target)"
mux tmx
check 'empty value is passed as is' "tmux||${started}" "${calls}"
mux tmx "SSH_AUTH_SOCK=${tmp}/missing.sock"
check 'missing path is passed as is' "tmux|${tmp}/missing.sock|${started}" "${calls}"
: >"${tmp}/regular"
mux tmx "SSH_AUTH_SOCK=${tmp}/regular"
check 'regular file is passed as is' "tmux|${tmp}/regular|${started}" "${calls}"
check 'link is kept for values that are not sockets' "${a2}" "$(target)"
mv -f -- "${link}" "${tmp}/saved-link"
mkdir "${link}"
mux tmx "SSH_AUTH_SOCK=${tmp}/a1.sock"
check 'directory in place of the link: value is passed as is' \
  "tmux|${tmp}/a1.sock|${started}" "${calls}"
rmdir "${link}"
check 'no temporary names in ~/.ssh' '0' "$(leftovers)"
: >"${tmp}/mux.log"
out=$("${base[@]}" TERM_PROGRAM=vscode bash -i -c scrrr </dev/null 2>/dev/null)
check 'scrrr from .bashrc is kept' "you're already screened" \
  "$(grep -F "you're already screened" <<<"${out}")"
check 'scrrr from .bashrc does not run screen' '0' "$(wc -c <"${tmp}/mux.log")"
printf 'passed: %s, failed: %s\n' "${passed}" "${#failed[@]}"
if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'FAIL %s\n' "${failed[@]}"
  exit 1
fi
