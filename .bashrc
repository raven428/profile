#!/usr/bin/env bash
# cspell:ignore clicolor colorterm cvsroot fgrep gxfxcxdxbxegedabagacad ignoredups
# cspell:ignore ignorespace isilon kend khome lscolors onefs pbrewrc pebatr perlbrew
# cspell:ignore pfxgrep scrrr xisi xscreen
#shellcheck disable=1091
/usr/bin/env test -f /etc/bashrc && source /etc/bashrc

# fill PATH:
echo "$PATH" | /usr/bin/env fgrep ~/.local/bin >/dev/null || PATH=$PATH:~/.local/bin
echo "$PATH" | /usr/bin/env fgrep /sbin >/dev/null || PATH=$PATH:/sbin
echo "$PATH" | /usr/bin/env fgrep /usr/sbin >/dev/null || PATH=$PATH:/usr/sbin
echo "$PATH" | /usr/bin/env fgrep /usr/local/sbin >/dev/null || PATH=$PATH:/usr/local/sbin
echo "$PATH" | /usr/bin/env fgrep ~/.local/go/bin >/dev/null || PATH=$PATH:~/.local/go/bin

# isilon onefs detector:
/usr/bin/env uname | grep -F OneFS >/dev/null 2>&1 && unm=isi

# fill colors:
case $OSTYPE in
*bsd*)
  export LSCOLORS=gxfxcxdxbxegedabagacad
  export CLICOLOR_FORCE=1
  alias ls='/bin/ls -lG'
  bash_completion=/usr/local/share/bash-completion/bash_completion
  alias diff='diff -u'
  ;;
*linux* | *)
  # editorconfig-checker-disable
  export LS_COLORS='di=36:ln=35:so=32:pi=33:ex=31:bd=34;46:cd=34;43:su=0;41:sg=0;46:tw=0;42:ow=0;43:'
  # editorconfig-checker-enable
  alias ls='/bin/ls -l --color=always'
  bash_completion=/etc/bash_completion
  alias diff='diff -u --color=always'
  ;;
esac

# aliases:
alias jqc='jq -C '\''.'\'''
alias jqc1='jqc --indent 1'
alias jqc2='jqc --indent 2'
alias pv='pv -pebatr'
alias less='less -RIn'
alias vi='vim'
alias nft-full-list='sudo nft list ruleset | tr '\''\t'\'' '\'' '\'''
# editorconfig-checker-disable
alias nft-skip-sets='sudo nft list ruleset | sed '\''/elements = {/,/}/d'\'' | tr '\''\t'\'' '\'' '\'''
# editorconfig-checker-enable

# grep aliases:
pfxgrep() {
  pfx=$1
  shift
  if read -t 0; then
    # exclude line with "${pfx}grep" from grep output:
    /usr/bin/env fgrep -v "${pfx}grep" | "${pfx}grep" --color=always "$@"
  else
    # pass to regular grep if stdin is empty:
    /usr/bin/env "${pfx}grep" --color=always "$@"
  fi
}

# environment:
export COLORTERM=1
export EDITOR='vim'
export PAGER='less -RIn'
#shellcheck disable=2025
export PS1='\e[32m[\e[33m\w@\H/\t\e[32m]\e[0m\n\u\$ \[\033[2 q\]'
export CVS_RSH='ssh'
export CVSROOT='raven@hq:/usr/home/raven/cry/cvs'
export TIME_STYLE='long-iso'
if [[ "$unm" != "isi" ]]; then
  export LC_ALL='en_US.UTF-8'
  export LANG='en_US.UTF-8'
  export LANGUAGE='en_US.UTF-8'
  export LC_TIME='en_GB.UTF-8'
  unset LC_ALL
fi
scrrr() {
  echo "you're already screened"
}
#shellcheck disable=1090
/usr/bin/env test -f "$bash_completion" && source "$bash_completion"
export PERLBREW_ROOT='/usr/perl5/brew'
export PERLBREW_HOME='/usr/perl5/home'
pbrewrc="${PERLBREW_ROOT}/etc/bashrc"
#shellcheck disable=1090
test -f "$pbrewrc" && source "$pbrewrc"
umask 0022

# disable history purging:
export HISTSIZE=
export HISTFILESIZE=
export HISTTIMEFORMAT='[%F %T] '
export HISTCONTROL=ignoredups:ignorespace

if [[ -x $(which tic) ]]; then
  /usr/bin/env tic -x - <<EOF
xterm-256color|true color terminal,
  use=xterm-256color,
  kend=\E[4~,khome=\E[1~,
  RGB,
  Tc,
EOF
fi

# force set tmux terminal
if [[ -n "$TMUX" ]]; then
  export TERM='xterm-256color'
fi

# append to the history file, don't overwrite it:
shopt -s histappend

# check the window size after each command and, if necessary,
# update the values of LINES and COLUMNS:
shopt -s checkwinsize

# modifications of PROMPT_COMMAND:
PROMPT_COMMAND='/usr/bin/env true'

# write and read new history after each command:
PROMPT_COMMAND+='; history -a; history -n'

# actual xterm window title:
# editorconfig-checker-disable
PROMPT_COMMAND+='; /usr/bin/env printf "\033]0;[%s@%s:%s]\007" "${USER}" "${HOSTNAME%%.*}" "${PWD}"'
# editorconfig-checker-enable

# actual screen window title:
if [[ "${TERM}" = "screen" ]]; then
  PROMPT_COMMAND+='; /usr/bin/env printf "\033k%s@%s\033\\" "${USER}" "${PWD}"'
fi

# https://github.com/tmux/tmux/issues/2682 avoid blinking cursor in tmux with kitty:
#PROMPT_COMMAND+='; /usr/bin/env printf '\''\033[2 q'\'''
# (moved to PS1 above)

#shellcheck disable=1090
/usr/bin/env test -f ~/.bashrc_local && source ~/.bashrc_local

# SSH agent of the VS Code window, sourced last to keep values set above
#shellcheck disable=1090
if [[ -r ~/.config/bash/ssh-agent-stable.sh ]]; then
  source ~/.config/bash/ssh-agent-stable.sh
fi
