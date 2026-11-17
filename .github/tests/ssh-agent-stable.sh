#!/usr/bin/env bash
# cspell:ignore authsock scrrr tmx keygen pids setsid SIGTTIN SHIMS SCREENDIR cmdline
# cspell:ignore epochrealtime inode inodes uptime
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
cleanup() {
  local pid
  for pid in "${pids[@]}"; do
    kill "${pid}" 2>/dev/null
  done
  wait 2>/dev/null
  rm -rf -- "${tmp}"
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
    -c 'printf "RESULT:%s\n" "${SSH_AUTH_SOCK-}"' </dev/null 2>&1 >"${tmp}/out" |
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
    grep -v '^RESULT:' "${tmp}/out"
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
