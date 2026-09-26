#!/bin/sh
# tui-linkify installer — wires the PTY linkifier in front of pi / opencode for
# every launch path we know about.
#
#   install.sh                 dry run (prints what would change)
#   install.sh --apply         write the WSL-side shims
#   install.sh --apply --windows  also emit Windows .cmd shims (no PATH edit)
#   install.sh --apply --win-dir 'C:\Users\dance\.local\bin'
#
# Touches only:
#   $HOME/.local/bin/tui-linkify
#   $HOME/.local/share/tui-linkify/bin/{pi,opencode}  (dedicated dir, no other names)
#   (and, with --windows, nothing but printed .cmd templates)
# Existing files are overwritten only when their content differs; every other
# file is left alone. Nothing is deleted.

set -eu

SKILL_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENTRY="$SKILL_DIR/tui-linkify.ts"
SHIM_DIR="${TUI_LINKIFY_SHIM_DIR:-$HOME/.local/share/tui-linkify/bin}"
APPLY=0
WINDOWS=0
WIN_DIR=''
DISTRO="${WSL_DISTRO_NAME:-Ubuntu-24.04}"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --windows) WINDOWS=1 ;;
    --win-dir) WIN_DIR=$2; shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
act() { say "  $1"; }

# write_if_changed TARGET MODE <<EOF ... EOF
write_if_changed() {
  target=$1; mode=$2; tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$target" ] && cmp -s "$tmp" "$target"; then
    say "unchanged: $target"; rm -f "$tmp"; return 0
  fi
  if [ "$APPLY" -eq 0 ]; then
    say "would write: $target"
    sed 's/^/    | /' "$tmp"
    rm -f "$tmp"; return 0
  fi
  mkdir -p "$(dirname -- "$target")"
  cp "$tmp" "$target"; chmod "$mode" "$target"; rm -f "$tmp"
  say "wrote: $target"
}

command -v bun >/dev/null 2>&1 || { echo "bun not found in PATH" >&2; exit 1; }
BUN_BIN=$(command -v bun)
[ -f "$ENTRY" ] || { echo "missing $ENTRY" >&2; exit 1; }
say "repo dir  : $SKILL_DIR"
say "bun       : $BUN_BIN"
say "mode      : $([ "$APPLY" -eq 1 ] && echo apply || echo 'dry run')"
say "shim dir  : $SHIM_DIR  (only pi/opencode live here, so PATH order stays safe)"

say ""
say "[1] launcher command"
write_if_changed "$HOME/.local/bin/tui-linkify" 755 <<EOF
#!/bin/sh
# managed by tui-linkify — do not edit
exec bun "$ENTRY" "\$@"
EOF

# [2] pi / opencode shims. They live in a dedicated dir so prepending it to PATH
#     shadows nothing else (node/npm/deno/uv in ~/.local/bin stay reachable).
for name in pi opencode; do
  say ""
  say "[2] $name shim"
  existing="$HOME/.local/bin/$name"
  if [ -f "$existing" ] && ! grep -q 'managed by tui-linkify' "$existing"; then
    say "  note: $existing already exists (not managed by this skill) — not touching it"
    say "        the shim below wraps whatever PATH resolves after $SHIM_DIR"
  fi
  real=$(PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx "$SHIM_DIR" | paste -sd: -) command -v "$name" || true)
  if [ -z "$real" ]; then say "  (skipped: $name not found outside $SHIM_DIR)"; continue; fi
  act "real $name: $real"
  pin=''
  if [ -x "$HOME/.local/bin/$name" ] && ! grep -q 'managed by tui-linkify' "$HOME/.local/bin/$name"; then
    pin="$HOME/.local/bin/$name"
    say "  pinning an existing wrapper first: $pin"
  fi
  write_if_changed "$SHIM_DIR/$name" 755 <<EOF
#!/bin/sh
# managed by tui-linkify — do not edit
# wraps $real in a PTY proxy so full paths become clickable file:// links
# bun is absolute: non-interactive shells never read ~/.bashrc.d (so ~/.bun/bin is absent)
self_dir=\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)
pin='$pin'
if [ -n "\$pin" ] && [ -x "\$pin" ]; then
  real=\$pin
else
  clean=\$(printf '%s' "\$PATH" | tr ':' '\n' | grep -vx "\$self_dir" | paste -sd: -)
  real=\$(PATH="\$clean" command -v $name) || { echo "$name: not found" >&2; exit 127; }
fi
BUN='$BUN_BIN'
[ -x "\$BUN" ] || BUN=\$(command -v bun) || { echo "tui-linkify: bun not found" >&2; exit 127; }
exec "\$BUN" "$ENTRY" -- "\$real" "\$@"
EOF
done

# [3] PATH order: the shim dir must come first; ~/.local/bin does not need to move
say ""
say "[3] PATH order"
case ":$PATH:" in
  "$SHIM_DIR:"*) act "ok: $SHIM_DIR is first in PATH" ;;
  *)
    act "add this to ~/.profile AFTER the nvm/pnpm lines (append at the end):"
    act "  export PATH=\"$SHIM_DIR:\$PATH\""
    ;;
esac

# [4] callers that bypass PATH (bash -c, PowerShell launcher)
say ""
say "[4] launch paths that bypass PATH"
say "  - ~/.agents/skills/opencode-launcher-win/opencode-launcher.ps1"
say "      replace 'opencode' with the absolute shim to cover 'wsl -e bash -c':"
say "      \$HOME/.local/bin/opencode  (i.e. /home/$USER/.local/bin/opencode)"
say "  - herdr / tmux panes: nothing to do (each pane runs the shim)"

if [ "$WINDOWS" -eq 1 ]; then
  say ""
  say "[5] Windows shims"
  [ -n "$WIN_DIR" ] || { echo "--win-dir is required with --windows" >&2; exit 2; }
  win_entry="\\\\wsl.localhost\\$DISTRO$(printf '%s' "$ENTRY" | sed 's|/|\\|g')"
  for pair in "opencode:C:\\Users\\dance\\.bun\\bin\\opencode.cmd"; do
    name=${pair%%:*}; real=${pair#*:}
    say "  $name -> $real"
    say "  emit into $WIN_DIR\\$name.cmd:"
    say "    @echo off"
    say "    bun \"$win_entry\" -- \"$real\" %*"
  done
  say "  (Windows PATH is not modified — put $WIN_DIR on PATH yourself)"
fi
