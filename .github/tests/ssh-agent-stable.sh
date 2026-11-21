#!/usr/bin/env bash
# cspell:ignore authsock scrrr tmx keygen pids setsid SIGTTIN SHIMS SCREENDIR cmdline
# cspell:ignore epochrealtime inode inodes uptime sigwinch winch
# Scenarios for .config/bash/ssh-agent-stable.sh and set_mux_env in an isolated HOME,
# VS Code server processes are emulated by a fake /proc tree.
# shellcheck disable=SC2016
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d -p /var/tmp ssh-agent-stable.XXXXXXXX)
home=${tmp}/home
run=${tmp}/run
pids=()
failed=()
passed=0
fwd=''
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf -- "${tmp}"
  if [[ -n ${fwd-} ]]; then
    rm -rf -- "${fwd}"
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
result_cmd='printf "RESULT:%s\n" "${SSH_AUTH_SOCK-}"'
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
    grep -v -e '^RESULT:' -e '^TRAP:' -e '^TRAPS:' -e '^RC_AFTER:' -e '^REM_AFTER:' \
      -e '^IFS_AFTER:' "${tmp}/out"
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
# fallback: the git socket is held by a hanging extension host with a dead link
fake_new hanging
listen 9190 "${G1}"
child 5000090 90 extensionHost "${LD}" 9190
child 5000012 120 extensionHost "${L2}" 9102
child 5000013 130 extensionHost "${L3}"
vscode_shell "${fake}" plain ptyHost "SSH_AUTH_SOCK=${OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'hanging owner: the freshest candidate' "${L3}" "${result}"
quiet 'hanging owner'
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
# race: the extension host of the window appears about a second after the shell started
fake_new race
child 5000090 90 extensionHost "${LD}" 9190
rm -f -- "${tmp}/err"
(
  for ((i = 0; i < 50; i++)); do
    if grep -q ' ssh-agent-stable: ' "${tmp}/err" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  sleep 0.8
  listen 9191 "${G1}"
  child 5000091 300 extensionHost "${L1}" 9191
) &
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
# Reload Window: the trap of SIGWINCH moves the link of the old connection to the agent
# of the new one; a forwarded agent lives in /tmp/ssh-XXXXXXXXXX like the one of sshd
fwd=$(mktemp -d /tmp/ssh-XXXXXXXXXX)
start_agent "${fwd}/agent.1"
start_agent "${fwd}/agent.3"
fresh=$(readlink -e "${fwd}/agent.1")
fresh2=$(readlink -e "${fwd}/agent.3")
RL_OLD=${run}/vscode-ssh-auth-sock-300
RL_NEW=${run}/vscode-ssh-auth-sock-301
RL_LATE=${run}/vscode-ssh-auth-sock-302
RL_BAD=${run}/vscode-ssh-auth-sock-303
RL_NEW2=${run}/vscode-ssh-auth-sock-304
RL_FILE=${run}/vscode-ssh-auth-sock-305
: >"${fwd}/agent.2"
ln -s "${fresh}" "${RL_NEW}"
ln -s "${fresh2}" "${RL_NEW2}"
ln -s "${tmp}/a2.sock" "${RL_BAD}"
ln -s "${fwd}/agent.2" "${RL_FILE}"
# the shell under test marks that it is ready, waits for the go mark up to 5 seconds,
# runs WINCH_EVAL, sends SIGWINCH to itself WINCH_TIMES times and reports the time
# of the last trap in ms, the trap of SIGWINCH and SSH_AUTH_SOCK; WINCH_EVAL2 runs
# before the second and the next signals; with WINCH_IFS the signal comes from outside
# while a command of a function with that IFS runs, after a successful =~ and with
# the status 3, and the state of the interrupted code is reported after the trap
winch_cmd='sig_inside() {
  local IFS=${WINCH_IFS}
  [[ abc-123 =~ ^([a-z]+)-([0-9]+)$ ]]
  { (sleep 0.1; kill -WINCH "${1}") & } 2>/dev/null
  sh -c "sleep 0.3; exit 3"
  printf "RC_AFTER:%s\n" "$?"
  printf "REM_AFTER:%s|%s|%s\n" "${BASH_REMATCH[0]}" "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}"
  printf "IFS_AFTER:%q\n" "${IFS}"
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
    for ((m = 0; m < 100; m++)); do
      if [[ -e ${WINCH_DIR}/go2 ]]; then
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
  else
    kill -WINCH $$
  fi
  t1=${EPOCHREALTIME/[.,]/}
  : >"${WINCH_DIR}/winch-sig${n}"
done
printf "TRAP:%s\n" "$(((${t1:-0} - ${t0:-0}) / 1000))"
printf "TRAPS:%s\n" "$(trap -p WINCH)"
printf "RESULT:%s\n" "${SSH_AUTH_SOCK-}"'
winch_windows() {
  # $1: name; window 1 with the link RL_OLD of a live old connection, window 2
  fake_new "winch-${1}"
  listen 9101 "${G1}"
  child 5000011 110 extensionHost "${RL_OLD}" 9101
  listen 9102 "${G2}"
  child 5000012 120 extensionHost "${L2}" 9102
  ln -sfn "${tmp}/a1.sock" "${RL_OLD}"
}
new_host() {
  # $1: SSH_AUTH_SOCK of the new extension host of window 1, the old one is gone
  rm -rf -- "${fake}/5000011"
  listen 9111 "${G1}"
  child 5000021 300 extensionHost "${1}" 9111
}
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
winch_run() {
  # $1: command that changes the fake /proc before SIGWINCH, $2: command after the go
  # mark, the rest: extra environment; sets trap_ms (the last trap) and traps
  rm -f -- "${tmp}/ready" "${tmp}/go" "${tmp}/go2" "${tmp}/mid" \
    "${tmp}"/winch-sig*
  reload "${1}" "${2}" &
  racer=$!
  shell_cmd=${winch_cmd}
  vscode_shell "${fake}" plain ptyHost "WINCH_DIR=${tmp}" "${@:3}"
  shell_cmd=${result_cmd}
  wait "${racer}"
  trap_ms=$(sed -n 's/^TRAP://p' "${tmp}/out")
  traps=$(sed -n 's/^TRAPS://p' "${tmp}/out")
  check "${fake##*/}: the shell under test signals itself" 'yes' \
    "$(if [[ -n ${trap_ms} ]]; then echo yes; else echo no; fi)"
}
# a resize: the extension host of the window is alive, the trap returns at once
winch_windows resize
winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'resize: the trap is set' "trap -- 'ssa_winch' SIGWINCH" "${traps}"
check 'resize keeps the value' "${RL_OLD}" "${result}"
check 'resize keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
check 'resize: no messages' '0' "${said}"
check 'resize: no other output' '0' "${noise}"
check 'resize: the trap returns at once' 'yes' \
  "$(if ((trap_ms < 1000)); then echo yes; else echo no; fi)"
# reload: the old extension host is gone, the new one has the link of the new connection
winch_windows reload
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'reload keeps the value' "${RL_OLD}" "${result}"
check 'reload moves the old link to the new agent' "${fresh}" "$(readlink "${RL_OLD}")"
check 'reload keeps the new link' "${fresh}" "$(readlink "${RL_NEW}")"
check 'reload keeps the link of another window' "${tmp}/a2.sock" "$(readlink "${L2}")"
SSH_AUTH_SOCK=${RL_OLD} ssh-add -l >/dev/null 2>&1
check 'reload: the old link reaches the new agent' '1' "$?"
check 'reload: no messages' '0' "${said}"
check 'reload: no other output' '0' "${noise}"
check 'reload: no temporary names' '0' "$(compgen -G "${run}/*.winch.*" | wc -l)"
# the new link appears a second after the signal, as ln of Remote SSH does
winch_windows late
rm -f -- "${RL_LATE}"
winch_run "new_host ${RL_LATE}" "sleep 1; ln -s ${fresh} ${RL_LATE}" \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'late link: the old link is moved' "${fresh}" "$(readlink "${RL_OLD}")"
check 'late link: no messages' '0' "${said}"
check 'late link: waits for the link within 3 seconds' 'yes' \
  "$(if ((trap_ms >= 500 && trap_ms < 3000)); then echo yes; else echo no; fi)"
second_reload() {
  # waits up to 10 seconds until the trap of the first signal has returned, keeps
  # where the link RL_OLD points in mid and replaces the extension host of window 1
  # once more
  local i
  for ((i = 0; i < 100; i++)); do
    if [[ -e ${tmp}/winch-sig0 ]]; then
      break
    fi
    sleep 0.1
  done
  readlink "${RL_OLD}" >"${tmp}/mid"
  rm -rf -- "${fake}/5000021"
  listen 9121 "${G1}"
  child 5000031 400 extensionHost "${RL_NEW2}" 9121
  : >"${tmp}/go2"
}
# a second reload of the same window moves the same link to the next connection
winch_windows twice
winch_run "new_host ${RL_NEW}" second_reload "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 WINCH_GO2=1
check 'twice: the first reload moves the link' "${fresh}" "$(cat "${tmp}/mid")"
check 'twice: the second reload moves the link again' "${fresh2}" \
  "$(readlink "${RL_OLD}")"
check 'twice: no messages' '0' "${said}"
check 'twice: no other output' '0' "${noise}"
# a link of another window taken at the start is not moved, whether the extension
# host of this window is known at the start or appears later
winch_windows other-link
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'other window link: the value is kept' "${L2}" "${result}"
check 'other window link is not moved' "${tmp}/a2.sock" "$(readlink "${L2}")"
check 'other window link: no messages' '0' "${said}"
check 'other window link: no other output' '0' "${noise}"
fake_new other-link-late
listen 9102 "${G2}"
child 5000012 120 extensionHost "${L2}" 9102
winch_run 'listen 9111 "${G1}"; child 5000021 300 extensionHost "${RL_NEW}" 9111' : \
  "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'other window link, late host: the value is kept' "${L2}" "${result}"
check 'other window link, late host: not moved' "${tmp}/a2.sock" "$(readlink "${L2}")"
check 'other window link, late host: no messages' '0' "${said}"
# a link of another window to the same agent as the own link is not moved
winch_windows shared-agent
ln -sfn "${tmp}/a1.sock" "${L2}"
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'shared agent: the value is kept' "${L2}" "${result}"
check 'shared agent: the link is not moved' "${tmp}/a1.sock" "$(readlink "${L2}")"
check 'shared agent: no messages' '0' "${said}"
check 'shared agent: no other output' '0' "${noise}"
ln -sfn "${tmp}/a2.sock" "${L2}"
# the shell starts with the link of window 2 that leads to the agent of the host of
# window 1, which appears later: neither the first nor the second reload moves it
fake_new shared-agent-late
listen 9102 "${G2}"
child 5000012 120 extensionHost "${L2}" 9102
ln -sfn "${fresh}" "${L2}"
winch_run 'listen 9111 "${G1}"; child 5000021 300 extensionHost "${RL_NEW}" 9111' \
  second_reload "SSH_AUTH_SOCK=${L2}" "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2 \
  WINCH_GO2=1
check 'shared agent, late host: the value is kept' "${L2}" "${result}"
check 'shared agent, late host: the second reload keeps the link' "${fresh}" \
  "$(readlink "${L2}")"
check 'shared agent, late host: no messages' '0' "${said}"
ln -sfn "${tmp}/a2.sock" "${L2}"
blocking_host() {
  # adds an extension host whose cmdline is a FIFO: any search of the children of
  # server-main blocks on it until the writer opens it 2 seconds later or is cut by
  # timeout; the pid of the writer is kept in writer.pid
  child 5000022 310 extensionHost "${RL_NEW}" 9111
  rm -f -- "${fake}/5000022/cmdline"
  mkfifo "${fake}/5000022/cmdline"
  timeout 5 bash -c 'sleep 2; : >"${1}"' _ "${fake}/5000022/cmdline" &
  echo "$!" >"${tmp}/writer.pid"
}
bulky_sockets() {
  # appends many foreign sockets to /proc/net/unix: any search of the git socket owner
  # has to parse every line, one pass takes seconds
  yes '0000000000000000: 00000002 00000000 00010000 0001 01 9999 /run/other.sock' |
    head -n 200000 >>"${fake}/net/unix"
}
# a resize with a fresher extension host of the window that holds the git socket
# does not move the link: the remembered host still runs; any search of the owner
# besides the fast path would block on the FIFO and parse the bulky table of sockets
winch_windows resize-fresher
winch_run 'bulky_sockets; listen 9111 "${G1}";
  child 5000021 300 extensionHost "${RL_NEW}" 9111; blocking_host' : \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
kill "$(cat "${tmp}/writer.pid")" 2>/dev/null
rm -f -- "${tmp}/writer.pid" "${fake}/5000022/cmdline" "${fake}/net/unix"
check 'resize with a fresher host keeps the link' "${tmp}/a1.sock" \
  "$(readlink "${RL_OLD}")"
check 'resize with a fresher host: no messages' '0' "${said}"
check 'resize with a fresher host: no other output' '0' "${noise}"
check 'resize with a fresher host: the trap returns at once' 'yes' \
  "$(if ((trap_ms < 1000)); then echo yes; else echo no; fi)"
# Reload while SSH_AUTH_SOCK is switched to another agent: the link is not moved and
# the host is not remembered, the first signal after the switch back moves it
mid_go2() {
  local i
  for ((i = 0; i < 100; i++)); do
    if [[ -e ${tmp}/winch-sig0 ]]; then
      break
    fi
    sleep 0.1
  done
  readlink "${RL_OLD}" >"${tmp}/mid"
  : >"${tmp}/go2"
}
winch_windows switched
winch_run "new_host ${RL_NEW}" mid_go2 "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" "WINCH_EVAL=SSH_AUTH_SOCK=${tmp}/a2.sock" \
  "WINCH_EVAL2=SSH_AUTH_SOCK=${RL_OLD}" WINCH_TIMES=2 WINCH_GO2=1
check 'switched value: the first reload keeps the link' "${tmp}/a1.sock" \
  "$(cat "${tmp}/mid")"
check 'switched value: the value is back' "${RL_OLD}" "${result}"
check 'switched value: the next signal moves the link' "${fresh}" \
  "$(readlink "${RL_OLD}")"
check 'switched value: no messages' '0' "${said}"
check 'switched value: no other output' '0' "${noise}"
# the signal comes inside a function with another IFS after =~ and a failure: the
# resize is quick and quiet, the reload moves the link, BASH_REMATCH, IFS and $?
# of the interrupted code are the same
interrupted_state() {
  # $1: scenario name, $2: expected IFS as %q
  check "${1}: \$? is kept" '3' "$(sed -n 's/^RC_AFTER://p' "${tmp}/out")"
  check "${1}: BASH_REMATCH is kept" 'abc-123|abc|123' \
    "$(sed -n 's/^REM_AFTER://p' "${tmp}/out")"
  check "${1}: IFS is kept" "${2}" "$(sed -n 's/^IFS_AFTER://p' "${tmp}/out")"
}
nl=$'\n'
k=0
for ifs in ':' "${nl}"; do
  k=$((k + 1))
  name="IFS ${ifs/${nl}/newline}"
  winch_windows "ifs-resize-${#ifs}${k}"
  winch_run : : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}" \
    "WINCH_IFS=${ifs}"
  check "resize, ${name}: the link is kept" "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
  check "resize, ${name}: no messages" '0' "${said}"
  check "resize, ${name}: no other output" '0' "${noise}"
  check "resize, ${name}: the trap returns at once" 'yes' \
    "$(if ((trap_ms < 1000)); then echo yes; else echo no; fi)"
  interrupted_state "resize, ${name}" "$(printf '%q' "${ifs}")"
  winch_windows "ifs-reload-${#ifs}${k}"
  winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
    "VSCODE_GIT_IPC_HANDLE=${G1}" "WINCH_IFS=${ifs}"
  check "reload, ${name}: the link is moved" "${fresh}" "$(readlink "${RL_OLD}")"
  check "reload, ${name}: no messages" '0' "${said}"
  check "reload, ${name}: no other output" '0' "${noise}"
  interrupted_state "reload, ${name}" "$(printf '%q' "${ifs}")"
done
# a temporary name left by a killed shell with the same pid does not break the move
winch_windows leftover-name
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" \
  'WINCH_EVAL=ln -s /nonexistent "${SSH_AUTH_SOCK}.winch.$$"'
check 'leftover name: the link is moved' "${fresh}" "$(readlink "${RL_OLD}")"
check 'leftover name: no messages' '0' "${said}"
check 'leftover name: no other output' '0' "${noise}"
check 'leftover name: no temporary names' '0' \
  "$(compgen -G "${run}/*.winch.*" | wc -l)"
# a target of the right form that is not a socket is not accepted: one message
winch_windows regular-file
winch_run "new_host ${RL_FILE}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'regular file target keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
check 'regular file target: one message' '1' "${said}"
check 'regular file target: open a new terminal' 'yes' \
  "$(if [[ ${last} == *'open a new terminal' ]]; then echo yes; else echo no; fi)"
check 'regular file target: no other output' '0' "${noise}"
# no agent of the new connection: one message, the next signal searches silently
winch_windows fail
winch_run "new_host ${RL_BAD}" : "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}" WINCH_TIMES=2
check 'no fresh agent keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
check 'no fresh agent: one message' '1' "${said}"
check 'no fresh agent: open a new terminal' 'yes' \
  "$(if [[ ${last} == *'open a new terminal' ]]; then echo yes; else echo no; fi)"
check 'no fresh agent: no other output' '0' "${noise}"
check 'no fresh agent: the next signal waits up to 3 seconds' 'yes' \
  "$(if ((trap_ms >= 2000 && trap_ms < 3500)); then echo yes; else echo no; fi)"
# a window without a git socket: no extension host is known, signals search silently
winch_windows no-git
winch_run : : "SSH_AUTH_SOCK=${RL_OLD}"
check 'no git socket keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
check 'no git socket: no messages' '0' "${said}"
check 'no git socket: the search waits up to 3 seconds' 'yes' \
  "$(if ((trap_ms >= 2000 && trap_ms < 3500)); then echo yes; else echo no; fi)"
# SSH_AGENT_STABLE=off: no trap; set after the start: the trap does nothing
winch_windows off
winch_run "new_host ${RL_NEW}" : SSH_AGENT_STABLE=off "SSH_AUTH_SOCK=${RL_OLD}" \
  "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'off: no trap' '' "${traps}"
check 'off keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
winch_windows off-later
winch_run "new_host ${RL_NEW}" : 'WINCH_EVAL=SSH_AGENT_STABLE=off' \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'off after the start keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
check 'off after the start: no messages' '0' "${said}"
# a trap of SIGWINCH from the profile is kept
printf "trap ':' WINCH\n" >"${home}/.bashrc_local"
winch_windows foreign
winch_run "new_host ${RL_NEW}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${home}/.bashrc_local"
check 'foreign trap is kept' "trap -- ':' SIGWINCH" "${traps}"
check 'foreign trap keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
# an explicit value set after the start is not a link of Remote SSH: nothing is moved
winch_windows explicit-later
winch_run "new_host ${RL_NEW}" : "WINCH_EVAL=SSH_AUTH_SOCK=${tmp}/a2.sock" \
  "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
check 'explicit value after the start is kept' "${tmp}/a2.sock" "${result}"
check 'explicit value after the start keeps the link' "${tmp}/a1.sock" \
  "$(readlink "${RL_OLD}")"
check 'explicit value after the start: no messages' '0' "${said}"
# no clock: one search without waiting
printf 'unset EPOCHREALTIME\n' >"${home}/.bashrc_local"
winch_windows no-clock
rm -f -- "${fake}/uptime"
winch_run "new_host ${RL_BAD}" : "SSH_AUTH_SOCK=${RL_OLD}" "VSCODE_GIT_IPC_HANDLE=${G1}"
rm -f -- "${home}/.bashrc_local"
check 'no clock keeps the link' "${tmp}/a1.sock" "$(readlink "${RL_OLD}")"
check 'no clock: one message' '1' "${said}"
ready 'no clock: no waiting' 1500
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
