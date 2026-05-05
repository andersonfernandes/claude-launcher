#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${ZDOTDIR:-$HOME}/.zshrc"

# ── Colors ───────────────────────────────────────────────────────────────────
OK="\033[32m✔\033[0m"
ERR="\033[31m✘\033[0m"
INFO="\033[34m·\033[0m"

ok()   { printf "  $OK  %s\n" "$1"; }
err()  { printf "  $ERR  %s\n" "$1" >&2; }
info() { printf "  $INFO  %s\n" "$1"; }

# ── Dependency check ─────────────────────────────────────────────────────────
check_dep() {
  local bin="$1" hint="$2"
  if command -v "$bin" &>/dev/null; then
    ok "$bin  $(command -v "$bin")"
  else
    err "$bin not found — $hint"
    MISSING=1
  fi
}

echo
echo "  Claude Launcher — install"
echo "  ─────────────────────────"
echo

MISSING=0
info "Checking dependencies..."
check_dep fzf    "brew install fzf  /  apt install fzf"
check_dep jq     "brew install jq   /  apt install jq"
check_dep claude "https://claude.ai/code"
echo

if [[ "$MISSING" -eq 1 ]]; then
  err "Fix missing dependencies then re-run install.sh"
  exit 1
fi

# ── profiles.json ────────────────────────────────────────────────────────────
if [[ ! -f "$SCRIPT_DIR/profiles.json" ]]; then
  cp "$SCRIPT_DIR/profiles.example.json" "$SCRIPT_DIR/profiles.json"
  ok "Created profiles.json from example — edit it to add your directories"
else
  ok "profiles.json already exists"
fi
echo

# ── ~/.zshrc patches ─────────────────────────────────────────────────────────
info "Patching $ZSHRC..."

FPATH_LINE="fpath=(\"$SCRIPT_DIR\" \$fpath)"
CLD_FUNC=$(cat <<'FUNC'
cld() { ~/.scripts/claude-launcher/cld.sh "$@"; }
FUNC
)
# Replace the hardcoded path in the function with the actual script dir
CLD_FUNC="cld() { \"$SCRIPT_DIR/cld.sh\" \"\$@\"; }"

patch_zshrc() {
  local marker="$1" line="$2"
  if grep -qF "$marker" "$ZSHRC" 2>/dev/null; then
    ok "Already in $ZSHRC: $marker"
  else
    printf '\n# claude-launcher\n%s\n' "$line" >> "$ZSHRC"
    ok "Added to $ZSHRC: $line"
  fi
}

# fpath must come before compinit — warn if compinit appears before our marker
patch_zshrc "$SCRIPT_DIR" "$FPATH_LINE"
patch_zshrc "claude-launcher/cld.sh" "$CLD_FUNC"

# Warn if fpath line landed after compinit
if grep -n "compinit" "$ZSHRC" 2>/dev/null | head -1 | grep -q .; then
  compinit_line=$(grep -n "compinit" "$ZSHRC" | head -1 | cut -d: -f1)
  fpath_line=$(grep -n "$SCRIPT_DIR" "$ZSHRC" | head -1 | cut -d: -f1)
  if [[ "$fpath_line" -gt "$compinit_line" ]]; then
    printf "\n  \033[33m⚠\033[0m  fpath line is after compinit in $ZSHRC\n"
    printf "     Move it above the compinit / oh-my-zsh source line for completions to work.\n"
  fi
fi

echo
echo "  Done. Reload your shell:  exec zsh"
echo
