#
# $Id: .bashrc,v 1.49 2024/08/20 06:58:02 raven Exp $
#

# load defaults:
/usr/bin/env test -f /etc/bashrc && source /etc/bashrc

# fill PATH:
echo $PATH | /usr/bin/env fgrep ~/bin >/dev/null || PATH=$PATH:~/bin
echo $PATH | /usr/bin/env fgrep ~/go/bin >/dev/null || PATH=$PATH:~/go/bin
echo $PATH | /usr/bin/env fgrep /sbin >/dev/null || PATH=$PATH:/sbin
echo $PATH | /usr/bin/env fgrep /usr/sbin >/dev/null || PATH=$PATH:/usr/sbin
echo $PATH | /usr/bin/env fgrep /usr/local/sbin >/dev/null || PATH=$PATH:/usr/local/sbin
echo $PATH | /usr/bin/env fgrep /usr/local/go/bin >/dev/null || PATH=$PATH:/usr/local/go/bin

# isilon onefs detector:
/usr/bin/env uname | fgrep OneFS >/dev/null 2>&1 && unm=isi

# fill colors:
case $OSTYPE in
 *bsd*)
  export LSCOLORS=gxfxcxdxbxegedabagacad
  export CLICOLOR_FORCE=1
  alias ls='/bin/ls -lG'
  bash_completion=/usr/local/share/bash-completion/bash_completion
  alias diff='diff -u'
 ;;
 *linux*|*)
  export LS_COLORS='di=36:ln=35:so=32:pi=33:ex=31:bd=34;46:cd=34;43:su=0;41:sg=0;46:tw=0;42:ow=0;43:'
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
alias finch='export PAGER=$HOME/less-Ri && exec finch'
alias vi='vim'

# grep aliases:
pfxgrep() {
 pfx=$1
 shift
 if read -t 0; then
  # exclude line with "${pfx}grep" from grep output:
  /usr/bin/env fgrep -v ${pfx}grep | ${pfx}grep --color=always "$@"
 else
  # pass to regular grep if stdin is empty:
  /usr/bin/env ${pfx}grep --color=always "$@"
 fi
}
for g in '' z bz xz; do
 for r in '' e f; do
  alias ${g}${r}grep="pfxgrep \"${g}${r}\""
 done
done

# environment:
export COLORTERM=1
export EDITOR='vim'
export PAGER='less -RIn'
export PS1='\e[32m[\e[33m\w@\H/\t\e[32m]\e[0m\n\u\$ '
export CVS_RSH='ssh'
export CVSROOT='raven@hq:/usr/home/raven/cry/cvs'
if [[ "x$unm" != "xisi" ]]; then
 export LANG='en_US.UTF-8'
 export LANGUAGE='en_US.UTF-8'
 export LC_ALL='en_US.UTF-8'
 unset LC_ALL
fi
scrrr() {
 echo "you're already screened"
}
/usr/bin/env test -f "$bash_completion" && source "$bash_completion"
export PERLBREW_ROOT='/usr/perl5/brew'
export PERLBREW_HOME='/usr/perl5/home'
pbrewrc="${PERLBREW_ROOT}/etc/bashrc"
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
PROMPT_COMMAND+='; /usr/bin/env printf "\033]0;[%s@%s:%s]\007" "${USER}" "${HOSTNAME%%.*}" "${PWD}"'

# actual screen window title:
if [[ "x${TERM}" = "xscreen" ]]; then
 PROMPT_COMMAND+='; /usr/bin/env printf "\033k%s@%s\033\\" "${USER}" "${PWD}"'
fi

# https://github.com/tmux/tmux/issues/2682
# avoid blinking cursor in tmux with kitty:
PROMPT_COMMAND+='; /usr/bin/env printf '\''\033[2 q'\'''

# load local:
/usr/bin/env test -f ~/.bashrc_local && source ~/.bashrc_local
