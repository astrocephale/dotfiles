###
### Settings
###

#colors enabling
autoload -U colors && colors
export CLICOLOR=1
export LS_COLORS=$LS_COLORS:'di=1;32:'

# zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# Set vi mode
set -o vi

# Keybindings
bindkey '^R' history-incremental-search-backward
bindkey '^H' vi-backward-kill-word

# Change prompt
if [ -z "$SSH_TTY" ]; then
  PS1='%1~ > '
else
  PS1="%{$(tput setaf 120)%}%m:%{$(tput sgr0)%} %1~ > "
fi

# Setup cross-session history
HISTSIZE=5000
HISTFILE=~/.local/share/zsh_history
SAVEHIST=$HISTSIZE
HISTDUP=erase
setopt appendhistory
setopt sharehistory
setopt hist_ignore_space
setopt hist_ignore_dups
setopt hist_ignore_all_dups
setopt hist_save_no_dups
setopt hist_find_no_dups

###
### Aliases
###

alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias .....='cd ../../../..'

alias pbcopy='wl-copy'
alias pbpaste='wl-paste'
alias open='xdg-open'
alias so="source ${XDG_CONFIG_HOME}/zsh/.zshrc"
alias weather='curl wttr.in'

alias dc='docker compose'
alias v='nvim'
alias e='nvim'
alias p='pnpm'
alias ports='sudo ss -tulnp'
alias s='kitten ssh'
alias mmv='nvim +Oil'
alias fdh='fd --hidden --exclude .git'

# systemd aliases
alias sss='sudo systemctl status'
alias ssr='sudo systemctl restart'
alias sst='sudo systemctl stop'
alias k='systemctl --user restart kanata.service'

alias install='sudo pacman -S'
alias update='sudo pacman -Syu'
alias remove='sudo pacman -Rns'

# git aliases
alias gcl='. gcl'
alias lg='lazygit'
alias gs='git status'
alias ga='git add'
alias gc='git commit'
alias gck='git checkout'
alias gb='git branch'
alias gp='git push'
alias gl='git pull'
alias glog='git log --oneline --decorate --graph'
alias gloga='git log --oneline --decorate --graph --all'
alias gr='git rebase'
alias gri='git rebase --interactive'
alias g-='git switch -'

# aliases depending on Rust tools
if command -v eza &> /dev/null; then
  alias ls='eza --icons=always -F auto'
  alias la='eza -lA --icons=always -F auto'
  alias l='eza -l --icons=always -F auto'
  alias ll='eza -l --icons=always -F auto'
  alias tree='eza -T --icons=always -F auto'
else
  alias ls='ls --color'
  alias la='ls -lAh'
  alias l='ls -lh'
  alias ll='ls -lh'
fi
if command -v bat &> /dev/null; then
  alias cat='bat'
fi

# Yt-dlp alias
alias zik-dl='yt-dlp -f bestaudio --extract-audio --audio-format opus --audio-quality 0 -o "%(uploader)s - %(title)s.%(ext)s" --embed-thumbnail --add-metadata'

# LazyDocker
alias lzd='docker run --rm -it -v /var/run/docker.sock:/var/run/docker.sock -v /yourpath/config:/.config/jesseduffield/lazydocker lazyteam/lazydocker'

###
### Custom utils
###

# quick folders
eval "alias $(grep -v "^#" "$HOME/.config/zsh/foldersrc" \
  | awk '{print $1 "=\"cd " $2 " && ls\" "}' \
  | tr "\"\n" "' ")"

# Load device-specific config
if ! [ -e "$XDG_CONFIG_HOME/zsh/device-specific.sh" ]; then
  touch "$XDG_CONFIG_HOME/zsh/device-specific.sh"
fi
source "$XDG_CONFIG_HOME/zsh/device-specific.sh"

# Extract utility (like unzip)
source "$XDG_CONFIG_HOME/zsh/archive.sh"

###
### Plugins
###

# Zinit bootstrapping
ZINIT_HOME="${XDG_DATA_HOME:-${HOME}/.local/share}/zinit/zinit.git"
if [[ ! -d "$ZINIT_HOME" ]]; then
  mkdir -p "$(dirname $ZINIT_HOME)"
  git clone https://github.com/zdharma-continuum/zinit.git "$ZINIT_HOME"
fi
source "${ZINIT_HOME}/zinit.zsh"

zinit ice wait lucid
zinit light zsh-users/zsh-syntax-highlighting

zinit ice wait lucid
zinit light zsh-users/zsh-completions

# Snippets
zinit snippet OMZP::sudo
# zinit snippet OMZP::ssh
zinit snippet OMZP::rust

# Instead of loading immediately
autoload -Uz compinit
# Load once per day
if [[ -n ${ZDOTDIR}/.zcompdump(#qNmh+24) ]]; then
  compinit
else
  compinit -C
fi

zinit cdreplay -q

###
### Tools integrations
###

# fzf
if command -v fzf &> /dev/null; then
  eval "$(fzf --zsh)"
else
  echo "fzf not found, skipping integration"
fi

# Cargo - lazy load
cargo() {
  unfunction cargo
  source "$HOME/.cargo/env"
  cargo "$@"
}

# pnpm
export PNPM_HOME="/home/astro/.local/share/pnpm"
case ":$PATH:" in
  *":$PNPM_HOME:"*) ;;
  *) export PATH="$PNPM_HOME:$PATH" ;;
esac
# pnpm end

# opencode
export PATH=/home/astro/.opencode/bin:$PATH
unalias ocl 2>/dev/null
ocl() {
  local list=$(opencode session list)
  local session=$(echo $list | fzf --header-lines=2 --height 40% --reverse)
  if [[ -n "$session" ]]; then
    local id=$(echo "$session" | awk '{print $1}')
    opencode --session "$id"
  fi
}

# vim: ts=2 sts=2 sw=2 et
