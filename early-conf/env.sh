export EDITOR=nvim
export VISUAL="$EDITOR"
export PAGER=less
export LESS='-Fr --mouse'

case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) [ -d "$HOME/.local/bin" ] && PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH
