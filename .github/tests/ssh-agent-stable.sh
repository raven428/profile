#!/usr/bin/env bash
# cspell:ignore authsock ssa xauth scrrr tmx keygen proto rcout pids setsockopt REUSEADDR
# cspell:ignore settimeout SHIMS SCREENDIR setsid SIGTTIN fakebin
# Scenarios for .ssh/rc and .config/bash/ssh-agent-stable.sh in an isolated HOME.
# shellcheck disable=SC2016
set -u
repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d -p /var/tmp ssh-agent-stable.XXXXXXXX)
home=${tmp}/home
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
  wait_for -S "${1}"
}
mkdir -p "${home}/.ssh" "${home}/.config/bash" "${tmp}/bin" "${tmp}/run" "${tmp}/screen"
chmod 700 "${home}/.ssh" "${tmp}/run" "${tmp}/screen"
cp "${repo}/.bashrc" "${repo}/.bash_profile" "${home}/"
cp "${repo}/.config/bash/ssh-agent-stable.sh" "${home}/.config/bash/"
cp "${repo}/.ssh/rc" "${home}/.ssh/rc"
cat >"${tmp}/bin/xauth" <<'EOF'
#!/bin/sh
cat >>"${XAUTH_LOG:?}"
EOF
cat >"${tmp}/bin/tmux" <<'EOF'
#!/bin/sh
printf 'tmux|%s|%s|%s\n' "${SSH_AUTH_SOCK-}" "${DISPLAY-}" "$*" >>"${MUX_LOG:?}"
EOF
cat >"${tmp}/bin/screen" <<'EOF'
#!/bin/sh
printf 'screen|%s|%s|%s\n' "${SSH_AUTH_SOCK-}" "${DISPLAY-}" "$*" >>"${MUX_LOG:?}"
EOF
cat >"${tmp}/bin/timeout" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${TIMEOUT_LOG:?}"
exec "${REAL_TIMEOUT:?}" "$@"
EOF
mkdir "${tmp}/fakebin"
printf '#!/bin/sh\nexit 0\n' >"${tmp}/fakebin/bash"
chmod 755 "${tmp}/bin/xauth" "${tmp}/bin/tmux" "${tmp}/bin/screen" "${tmp}/bin/timeout" \
  "${tmp}/fakebin/bash"
: >"${tmp}/timeout.log"
: >"${tmp}/mux.log"
: >"${tmp}/xauth.log"
: >"${tmp}/rc.out"
# login shells reset PATH in /etc/profile, so mux scenarios prepend SHIMS after it
# setsid drops the controlling terminal: interactive bash must not stop on SIGTTIN
base=(setsid -w env -i "HOME=${home}" "PATH=${tmp}/bin:${PATH}" "SHIMS=${tmp}/bin"
  "USER=tester" "TERM=dumb" "XDG_RUNTIME_DIR=${tmp}/run" "TMUX_TMPDIR=${tmp}/run"
  "SCREENDIR=${tmp}/screen" "MUX_LOG=${tmp}/mux.log" "XAUTH_LOG=${tmp}/xauth.log"
  "TIMEOUT_LOG=${tmp}/timeout.log" "REAL_TIMEOUT=$(command -v timeout)")
host=$(env -i bash -c 'printf "%s" "${HOSTNAME%%.*}"')
link=${home}/.ssh/authsock-${host}
display_file=${home}/.ssh/display-${host}
run_rc() {
  # emulates sshd: sh runs ~/.ssh/rc from HOME, stdin is passed through
  local conn='SSH_CONNECTION=127.0.0.1 1 127.0.0.1 22' # DevSkim: ignore DS162092
  (cd "${home}" && "${base[@]}" "${conn}" "$@" \
    sh .ssh/rc >>"${tmp}/rc.out" 2>>"${tmp}/stderr.log")
}
shell_vars() {
  # $1: login or plain, the rest: extra environment; prints SSH_AUTH_SOCK|DISPLAY
  local flags=(-i)
  if [[ ${1} == 'login' ]]; then
    flags=(-l -i)
  fi
  shift
  "${base[@]}" "$@" bash "${flags[@]}" \
    -c 'printf "RESULT:%s|%s\n" "${SSH_AUTH_SOCK-}" "${DISPLAY-}"' \
    </dev/null 2>>"${tmp}/stderr.log" | sed -n 's/^RESULT://p'
}
target() {
  readlink "${link}" 2>/dev/null || printf 'none'
}
leftovers() {
  compgen -G "${home}/.ssh/.authsock.*" | wc -l
}
# agents: with a key, empty, two more for races and a local agent default-like path
ssh-keygen -q -t ed25519 -N '' -C test -f "${tmp}/key"
start_agent "${tmp}/a1.sock"
start_agent "${tmp}/a2.sock"
start_agent "${tmp}/a3.sock"
mkdir -m 700 "${tmp}/ssh-a1b2c3d4e5f6"
start_agent "${tmp}/ssh-a1b2c3d4e5f6/agent.4242"
SSH_AUTH_SOCK=${tmp}/a1.sock ssh-add -q "${tmp}/key" 2>/dev/null
a1=$(readlink -e "${tmp}/a1.sock")
a2=$(readlink -e "${tmp}/a2.sock")
a3=$(readlink -e "${tmp}/a3.sock")
python3 -c 'import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.close()' "${tmp}/dead.sock"
# X11 stand-in: two listening displays and one free display number
python3 - "${tmp}/x11" <<'EOF' &
import os, socket, sys
live, numbers = [], []
for n in range(50, 2000):
    s = socket.socket()
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(('127.0.0.1', 6000 + n))  # DevSkim: ignore DS162092
    except OSError:
        s.close()
        continue
    numbers.append(str(n))
    if len(live) < 2:
        s.listen(16)
        live.append(s)
    else:
        s.close()
        break
with open(sys.argv[1] + '.tmp', 'w') as f:
    f.write(' '.join(numbers))
os.rename(sys.argv[1] + '.tmp', sys.argv[1])
while True:
    for s in live:
        s.settimeout(0.1)
        try:
            c, _ = s.accept()
            c.close()
        except OSError:
            pass
EOF
pids+=("$!")
wait_for -s "${tmp}/x11"
read -r x1 x2 x3 <"${tmp}/x11"
d1="localhost:${x1}.0" # DevSkim: ignore DS162092
d2="localhost:${x2}.0" # DevSkim: ignore DS162092
d3="localhost:${x3}.0" # DevSkim: ignore DS162092
old=${tmp}/run/vscode-ssh-auth-sock-1
pane='TMUX=/tmp/tmux-1/default,1,0'
login='SSH_CONNECTION=1 2 3 4'
# live target, repeated publication, empty agent
run_rc "SSH_AUTH_SOCK=${tmp}/a1.sock" </dev/null
check 'rc publishes an agent with keys' "${a1}" "$(target)"
run_rc "SSH_AUTH_SOCK=${tmp}/a2.sock" </dev/null
check 'rc publishes an empty agent' "${a2}" "$(target)"
run_rc "SSH_AUTH_SOCK=${tmp}/a2.sock" </dev/null
check 'repeated publication' "${a2}" "$(target)"
check 'no temporary files after publication' '0' "$(leftovers)"
# socket without listener and local agent are not published
run_rc "SSH_AUTH_SOCK=${tmp}/dead.sock" </dev/null
check 'socket without listener is not published' "${a2}" "$(target)"
run_rc "SSH_AUTH_SOCK=${tmp}/ssh-a1b2c3d4e5f6/agent.4242" </dev/null
check 'local ssh-agent is not published' "${a2}" "$(target)"
# dead target: the link points to a stopped agent
start_agent "${tmp}/a4.sock"
pid4=${pids[-1]}
a4=$(readlink -e "${tmp}/a4.sock")
run_rc "SSH_AUTH_SOCK=${tmp}/a4.sock" </dev/null
kill "${pid4}"
wait "${pid4}" 2>/dev/null
local_agent=${tmp}/ssh-a1b2c3d4e5f6/agent.4242
: >"${tmp}/mux.log"
"${base[@]}" "${login}" "SSH_AUTH_SOCK=${local_agent}" \
  bash -l -i -c 'PATH=${SHIMS}:${PATH}; tmx' </dev/null >/dev/null 2>>"${tmp}/stderr.log"
check 'tmx keeps a local agent while the link is dead' \
  "tmux|${local_agent}||-u new-session -AD -s tester-0" "$(cat "${tmp}/mux.log")"
check 'tmx does not publish a local agent' "${a4}" "$(target)"
: >"${tmp}/mux.log"
"${base[@]}" "${login}" bash -l -i -c 'PATH=${SHIMS}:${PATH}; tmx' \
  </dev/null >/dev/null 2>>"${tmp}/stderr.log"
check 'tmx without agent keeps it empty while the link is dead' \
  'tmux|||-u new-session -AD -s tester-0' "$(cat "${tmp}/mux.log")"
check 'vscode shell keeps OLD while the link is dead' "${old}|" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
run_rc "SSH_AUTH_SOCK=${tmp}/a1.sock" </dev/null
check 'link is alive again after the next connection' "${a1}" "$(target)"
# a link left by an older profile that points to a live local agent is not exported
local_agent=${tmp}/ssh-a1b2c3d4e5f6/agent.4242
ln -sfn "${local_agent}" "${link}"
check 'vscode shell keeps OLD when the link is a local agent' "${old}|" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
check 'tmux pane keeps its agent when the link is a local agent' "${tmp}/a2.sock|" \
  "$(shell_vars plain "${pane}" "SSH_AUTH_SOCK=${tmp}/a2.sock")"
: >"${tmp}/mux.log"
"${base[@]}" "${login}" "SSH_AUTH_SOCK=${local_agent}" \
  bash -l -i -c 'PATH=${SHIMS}:${PATH}; tmx' </dev/null >/dev/null 2>>"${tmp}/stderr.log"
check 'tmx does not export a link to a local agent' \
  "tmux|${local_agent}||-u new-session -AD -s tester-0" "$(cat "${tmp}/mux.log")"
check 'link to a local agent is left untouched' "${local_agent}" "$(target)"
ln -sfn "${a1}" "${link}"
# non-login and login shells
check 'non-login vscode shell switches to the link' "${link}|" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
check 'login vscode shell switches to the link' "${link}|" \
  "$(shell_vars login TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
check 'tmux pane switches to the link' "${link}|" \
  "$(shell_vars plain "${pane}" "SSH_AUTH_SOCK=${tmp}/a2.sock")"
check 'ssh login keeps its own agent' "${tmp}/a2.sock|" \
  "$(shell_vars login "${login}" "SSH_AUTH_SOCK=${tmp}/a2.sock")"
check 'ssh login without agent takes the link' "${link}|" \
  "$(shell_vars login "${login}")"
# two parallel publications
for i in 1 2 3 4 5; do
  run_rc "SSH_AUTH_SOCK=${tmp}/a2.sock" </dev/null &
  first=$!
  run_rc "SSH_AUTH_SOCK=${tmp}/a3.sock" </dev/null &
  wait "${first}" "$!"
  now=$(target)
  if [[ ${now} == "${a2}" || ${now} == "${a3}" ]]; then
    check "parallel publication ${i}" 'a2 or a3' 'a2 or a3'
  else
    check "parallel publication ${i}" 'a2 or a3' "${now}"
  fi
  check "parallel publication ${i} keeps a symlink" 'yes' \
    "$(if [[ -L ${link} ]]; then printf yes; else printf no; fi)"
done
check 'no temporary files after parallel publications' '0' "$(leftovers)"
# X11 block and DISPLAY file
run_rc "SSH_AUTH_SOCK=${tmp}/a1.sock" 'DISPLAY=remote:12.0' <<<'MIT-MAGIC-COOKIE-1 abcd'
check 'xauth gets DISPLAY with X11UseLocalhost=no' \
  'add remote:12.0 MIT-MAGIC-COOKIE-1 abcd' "$(tail -n 1 "${tmp}/xauth.log")"
check 'vscode shell ignores a dead display from the file' "${link}|" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
run_rc "SSH_AUTH_SOCK=${tmp}/a1.sock" "DISPLAY=${d1}" <<<'MIT-MAGIC-COOKIE-1 abcd'
check 'xauth gets unix display for loopback' "add unix:${x1}.0 MIT-MAGIC-COOKIE-1 abcd" \
  "$(tail -n 1 "${tmp}/xauth.log")"
check 'rc records DISPLAY' "${d1}" "$(cat "${display_file}" 2>/dev/null)"
check 'rc writes nothing to stdout' '0' "$(wc -c <"${tmp}/rc.out")"
check 'vscode shell takes the live display' "${link}|${d1}" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
check 'tmux pane replaces a live own display' "${link}|${d1}" \
  "$(shell_vars plain "${pane}" "SSH_AUTH_SOCK=${link}" "DISPLAY=${d2}")"
check 'ssh login keeps its own live display' "${tmp}/a2.sock|${d2}" \
  "$(shell_vars login "${login}" "SSH_AUTH_SOCK=${tmp}/a2.sock" "DISPLAY=${d2}")"
check 'ssh login replaces a dead own display' "${tmp}/a2.sock|${d1}" \
  "$(shell_vars login "${login}" "SSH_AUTH_SOCK=${tmp}/a2.sock" "DISPLAY=${d3}")"
# explicit values from the profile and from the command line
printf 'export SSH_AUTH_SOCK=%s/explicit.sock\nexport DISPLAY=explicit:7\n' "${tmp}" \
  >"${home}/.bashrc_local"
check 'profile values are kept' "${tmp}/explicit.sock|explicit:7" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
rm -f -- "${home}/.bashrc_local"
out=$("${base[@]}" "${login}" "SSH_AUTH_SOCK=${tmp}/a2.sock" "MANUAL=${tmp}/a3.sock" \
  bash -l -i -c 'export SSH_AUTH_SOCK=${MANUAL}; set_mux_env
    printf "RESULT:%s\n" "${SSH_AUTH_SOCK}"' \
  </dev/null 2>>"${tmp}/stderr.log" | sed -n 's/^RESULT://p')
check 'manual SSH_AUTH_SOCK is kept by set_mux_env' "${tmp}/a3.sock" "${out}"
check 'manual SSH_AUTH_SOCK is not published' "${a1}" "$(target)"
# SSH_AGENT_STABLE=off
run_rc SSH_AGENT_STABLE=off "SSH_AUTH_SOCK=${tmp}/a2.sock" </dev/null
check 'off disables publication' "${a1}" "$(target)"
check 'off disables export' "${old}|" \
  "$(shell_vars plain SSH_AGENT_STABLE=off TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
# tmx and scrrr from .bash_profile, scrrr from .bashrc
: >"${tmp}/mux.log"
out=$("${base[@]}" "${login}" "SSH_AUTH_SOCK=${tmp}/a3.sock" "DISPLAY=${d2}" \
  bash -l -i -c 'PATH=${SHIMS}:${PATH}; tmx; echo AFTER' \
  </dev/null 2>>"${tmp}/stderr.log")
check 'tmx exits the shell' '0' "$(grep -c AFTER <<<"${out}")"
check 'tmx starts tmux with stable values' \
  "tmux|${link}|${d2}|-u new-session -AD -s tester-0" "$(cat "${tmp}/mux.log")"
check 'tmx publishes its own agent' "${a3}" "$(target)"
check 'tmx records its own display' "${d2}" "$(cat "${display_file}" 2>/dev/null)"
: >"${tmp}/mux.log"
out=$("${base[@]}" "${login}" "SSH_AUTH_SOCK=${tmp}/a2.sock" \
  bash -l -i -c 'PATH=${SHIMS}:${PATH}; scrrr; echo AFTER' \
  </dev/null 2>>"${tmp}/stderr.log")
check 'scrrr exits the shell' '0' "$(grep -c AFTER <<<"${out}")"
mux=$(paste -s -d ' ' "${tmp}/mux.log")
check 'scrrr runs screen with stable values' \
  "screen|${link}|${d2}|-wipe screen|${link}|${d2}|-D -RR" "${mux}"
check 'scrrr publishes its own agent' "${a2}" "$(target)"
: >"${tmp}/mux.log"
out=$("${base[@]}" TERM_PROGRAM=vscode bash -i -c scrrr </dev/null 2>>"${tmp}/stderr.log")
check 'scrrr from .bashrc is kept' "you're already screened" \
  "$(grep -F "you're already screened" <<<"${out}")"
check 'scrrr from .bashrc does not run screen' '0' "$(wc -c <"${tmp}/mux.log")"
check 'rc never writes to stdout' '0' "$(wc -c <"${tmp}/rc.out")"
# rc runs the shared file by /bin/bash even if PATH starts with another bash
run_rc "SSH_AUTH_SOCK=${tmp}/a3.sock" "DISPLAY=${d1}" \
  "PATH=${tmp}/fakebin:${tmp}/bin:${PATH}" <<<'MIT-MAGIC-COOKIE-1 abcd'
check 'rc publishes the agent with another bash first in PATH' "${a3}" "$(target)"
check 'rc records DISPLAY with another bash first in PATH' "${d1}" \
  "$(cat "${display_file}" 2>/dev/null)"
# unix:N display is dead without network probes
printf 'unix:%s\n' "${x1}" >"${display_file}"
printf 'PATH=${SHIMS}:${PATH}\n' >"${home}/.bash_profile_local"
: >"${tmp}/timeout.log"
check 'vscode shell ignores a unix display from the file' "${link}|" \
  "$(shell_vars plain TERM_PROGRAM=vscode "SSH_AUTH_SOCK=${old}")"
check 'ssh login ignores a unix display from the file' "${link}|" \
  "$(shell_vars login "${login}")"
rm -f -- "${home}/.bash_profile_local"
check 'unix display is not probed' '0' "$(grep -c ' unix ' "${tmp}/timeout.log")"
printf 'passed: %s, failed: %s\n' "${passed}" "${#failed[@]}"
if [[ ${#failed[@]} -gt 0 ]]; then
  printf 'FAIL %s\n' "${failed[@]}"
  exit 1
fi
