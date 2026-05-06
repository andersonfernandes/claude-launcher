#!/bin/zsh

# Claude Launcher - profile-based claude config selector
# Usage: cld [-w|--worktree] [-t|--tmux] [profile] [claude-args...]

SCRIPT_DIR="${0:A:h}"

# Paths — override via environment variables if needed
CONFIG_FILE="${CLD_CONFIG_FILE:-$SCRIPT_DIR/profiles.json}"

_require() {
  local var="$1" bin="$2" hint="$3"
  local val="${(P)var}"
  if [[ -n "$val" ]]; then
    [[ -x "$val" ]] || { echo "Error: $var='$val' is not executable." >&2; exit 1; }
    printf '%s' "$val"
    return 0
  fi
  command -v "$bin" &>/dev/null && { printf '%s' "$(command -v "$bin")"; return 0; }
  echo "Error: '$bin' not found in PATH. $hint" >&2
  exit 1
}

FZF_BIN=$(_require CLD_FZF_BIN    fzf    "Install: brew install fzf  /  apt install fzf")
JQ_BIN=$(_require  CLD_JQ_BIN     jq     "Install: brew install jq   /  apt install jq")
CLAUDE_BIN=$(_require CLD_CLAUDE_BIN claude "Install Claude Code: https://claude.ai/code")

FZF_THEME_OPTS=(
  --border=rounded
  --color='bg:#1a1b26,bg+:#2d3f76,fg:#9aa5ce,fg+:#c0caf5,gutter:#1a1b26,hl:#e0af68,hl+:#e0af68,border:#545c7e,label:#7aa2f7:bold,prompt:#7aa2f7,pointer:#bb9af7,info:#545c7e,separator:#545c7e,scrollbar:#545c7e,query:#c0caf5,preview-bg:#16161e,preview-border:#545c7e,preview-label:#7aa2f7'
)

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# ── Profile helpers ──────────────────────────────────────────────────────────

get_allowed_profiles() {
  $JQ_BIN -r --arg pwd "$PWD" --arg home "$HOME" '
    .profiles | to_entries[] |
    select(
      .value.directories | any(
        gsub("^~"; $home) as $dir |
        ($pwd == $dir) or ($pwd | startswith($dir + "/"))
      )
    ) | .key
  ' "$CONFIG_FILE"
}

get_description() {
  $JQ_BIN -r --arg name "$1" '.profiles[$name].description // ""' "$CONFIG_FILE"
}

profile_exists() {
  $JQ_BIN -e --arg name "$1" '.profiles[$name]' "$CONFIG_FILE" >/dev/null 2>&1
}

# ── Git / worktree helpers ───────────────────────────────────────────────────

is_git_repo() {
  git rev-parse --is-inside-work-tree &>/dev/null
}

git_root() {
  git rev-parse --show-toplevel 2>/dev/null
}

git_main_worktree() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10); exit}'
}

branch_to_slug() {
  printf '%s' "$1" | sed 's|/|-|g; s|[^a-zA-Z0-9._-]|-|g'
}

# Emit tab-delimited PATH\tDISPLAY lines for the worktree fzf picker
get_worktrees() {
  local cur_root
  cur_root=$(git_root) || return 1

  printf '__here__\t[ ↩  Stay in current dir ]\n'

  local wt_path="" wt_branch="" is_bare=0 wt_count=0

  _flush_wt() {
    [[ "$wt_path" != /* ]] && return   # skip prunable/stale entries with invalid paths
    [[ $is_bare -eq 1 ]] && return
    local _m _s
    [[ "$wt_path" == "$cur_root" ]] && _m="●" || _m=" "
    [[ -z "$wt_branch" ]] && wt_branch="(detached)"
    _s="${wt_path/#$HOME/~}"
    printf '%s\t%s %-24s  %s\n' "$wt_path" "$_m" "$wt_branch" "$_s"
    (( wt_count++ ))
  }

  while IFS= read -r line; do
    case "$line" in
      worktree\ *)
        [[ -n "$wt_path" ]] && _flush_wt
        wt_path="${line#worktree }"
        wt_branch="" is_bare=0
        ;;
      branch\ *)
        wt_branch="${line#branch refs/heads/}"
        ;;
      bare)
        is_bare=1
        ;;
    esac
  done < <(git worktree list --porcelain 2>/dev/null)

  [[ -n "$wt_path" ]] && _flush_wt

  printf '__new__\t[ + New worktree ]\n'
  (( wt_count >= 2 )) && printf '__remove__\t[ - Remove worktree... ]\n'
}

# ── Preview commands (exported so fzf subprocesses can access them) ───────────

# Store $PWD and key paths at launch time so preview subprocesses see the right values
export JQ_BIN CONFIG_FILE
export _CLD_PWD="$PWD"

# Profile preview: fzf passes the selected line as $1 ("profile - description")
# sh -c "$_CLD_PROFILE_PREV" -- {} runs this with $1 = selected line
export _CLD_PROFILE_PREV='
p="${1%% - *}"
desc=$("$JQ_BIN" -r --arg n "$p" '"'"'.profiles[$n].description // "(no description)"'"'"' "$CONFIG_FILE" 2>/dev/null)
printf "  \033[1m%s\033[0m\n  \033[2m%s\033[0m\n\n" "$p" "$desc"
history="$HOME/.config/claude-code/$p/history.jsonl"
[ -f "$history" ] || exit 0
ts=$(grep -F "\"project\":\"$_CLD_PWD\"" "$history" 2>/dev/null | tail -1 | "$JQ_BIN" -r .timestamp 2>/dev/null)
[ -z "$ts" ] || [ "$ts" = null ] && { printf "  \033[2mno recent session here\033[0m\n"; exit 0; }
now=$(date +%s); diff_s=$(( now - ts / 1000 ))
if   [ "$diff_s" -lt 60 ];    then ago="just now"
elif [ "$diff_s" -lt 3600 ];  then ago="$(( diff_s / 60 ))m ago"
elif [ "$diff_s" -lt 86400 ]; then ago="$(( diff_s / 3600 ))h ago"
else                               ago="$(( diff_s / 86400 ))d ago"
fi
printf "  \033[2mlast session\033[0m %s\n" "$ago"
'

# Worktree preview: fzf passes field 1 (path or sentinel) as $1
# sh -c "$_CLD_WORKTREE_PREV" -- {1} runs this with $1 = worktree path
# CLAUDE_CONFIG_DIR is inherited from the environment (exported before pick_worktree)
export _CLD_WORKTREE_PREV='
wt="$1"
case "$wt" in
  __here__)   printf "  \033[2mLaunch Claude in current directory\033[0m\n"; exit 0 ;;
  __new__)    printf "  \033[2mPick or type a branch name to create a new worktree\033[0m\n"; exit 0 ;;
  __remove__) printf "  \033[2mRemove a linked worktree\033[0m\n"; exit 0 ;;
esac
BLU="\033[38;2;122;162;247m"
CYN="\033[38;2;125;207;255m"
GRN="\033[38;2;158;206;106m"
YLW="\033[38;2;224;175;104m"
RED="\033[38;2;247;118;142m"
PRP="\033[38;2;187;154;247m"
DIM="\033[2m"; BLD="\033[1m"; RST="\033[0m"
branch=$(git -C "$wt" branch --show-current 2>/dev/null)
[ -z "$branch" ] && branch="(detached)"
dir=$(printf "%s" "$wt" | sed "s|^$HOME|~|")
printf "  ${BLD}${BLU}%s${RST}  ${DIM}%s${RST}\n\n" "$branch" "$dir"
tracking=$(git -C "$wt" rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null)
if [ -n "$tracking" ]; then
  counts=$(git -C "$wt" rev-list --left-right --count "HEAD...$tracking" 2>/dev/null)
  ahead=$(printf "%s" "$counts" | cut -f1)
  behind=$(printf "%s" "$counts" | cut -f2)
  [ "$ahead" -gt 0 ] 2>/dev/null && printf "  ${GRN}↑ %s ahead${RST}\n" "$ahead"
  [ "$behind" -gt 0 ] 2>/dev/null && printf "  ${RED}↓ %s behind${RST}\n" "$behind"
  printf "\n"
fi
status=$(git -C "$wt" status --short 2>/dev/null)
if [ -n "$status" ]; then
  printf "  ${DIM}changes${RST}\n"
  printf "%s\n" "$status" | head -12 | while IFS= read -r line; do
    xy=$(printf "%s" "$line" | cut -c1-2)
    rest=$(printf "%s" "$line" | cut -c4-)
    case "$xy" in
      "M "|" M"|"MM") printf "  ${YLW}%s${RST}  %s\n" "$xy" "$rest" ;;
      "A "|" A")      printf "  ${GRN}%s${RST}  %s\n" "$xy" "$rest" ;;
      "D "|" D")      printf "  ${RED}%s${RST}  %s\n" "$xy" "$rest" ;;
      "??")           printf "  ${DIM}%s${RST}  %s\n" "$xy" "$rest" ;;
      *)              printf "  %s  %s\n" "$xy" "$rest" ;;
    esac
  done
  printf "\n"
else
  printf "  ${DIM}working tree clean${RST}\n\n"
fi
printf "  ${DIM}commits${RST}\n"
git -C "$wt" log -5 --format="%h %s" 2>/dev/null | while IFS= read -r line; do
  hash=$(printf "%s" "$line" | cut -d" " -f1)
  msg=$(printf "%s" "$line" | cut -d" " -f2-)
  printf "  ${CYN}%s${RST}  %s\n" "$hash" "$msg"
done
'

# ── Splash ───────────────────────────────────────────────────────────────────

show_splash() {
  local B="\033[1m"
  local DIM="\033[2m"
  local R="\033[0m"
  local dir="${PWD/#$HOME/~}"
  local branch_part=""
  [[ -n "$2" ]] && branch_part=" ${DIM}·${R} ${DIM}${2}${R}"
  echo -e "${B}✳ Claude Code${R} ${DIM}·${R} ${B}${1}${R}${branch_part} ${DIM}·${R} ${DIM}${dir}${R}"

  local history="$CLAUDE_CONFIG_DIR/history.jsonl"
  if [[ -f "$history" ]]; then
    local ts
    ts=$(grep -F "\"project\":\"$PWD\"" "$history" | tail -1 | $JQ_BIN -r '.timestamp' 2>/dev/null)
    if [[ -n "$ts" && "$ts" != "null" ]]; then
      local now=$(($(date +%s) * 1000))
      local diff_s=$(( (now - ts) / 1000 ))
      local ago
      if (( diff_s < 60 )); then
        ago="just now"
      elif (( diff_s < 3600 )); then
        ago="$(( diff_s / 60 ))m ago"
      elif (( diff_s < 86400 )); then
        ago="$(( diff_s / 3600 ))h ago"
      else
        ago="$(( diff_s / 86400 ))d ago"
      fi
      echo -e "  ${DIM}last session ${ago}${R}"
    fi
  fi
}

# ── Worktree flows ───────────────────────────────────────────────────────────

_create_worktree() {
  local git_rt="$1"
  local branch slug base_name new_path

  local branch_list
  branch_list=$(git -C "$git_rt" branch --all --format='%(refname:short)' 2>/dev/null \
    | sed 's|^origin/||' | sort -u)

  local raw_output fzf_exit
  raw_output=$(
    printf '%s\n' "$branch_list" | $FZF_BIN \
      "${FZF_THEME_OPTS[@]}" \
      --prompt=" Branch › " \
      --border-label=" ✳ New Worktree " \
      --header=$'  \e[2mpick existing → checkout   type new name → create from HEAD\e[0m' \
      --height=~20 \
      --layout=reverse \
      --print-query
  )
  fzf_exit=$?
  (( fzf_exit == 130 )) && exit 130
  [[ -z "$raw_output" ]] && return 1

  # Prefer selected item (line 2) over typed query (line 1) when both are present
  branch=$(printf '%s\n' "$raw_output" | grep -v '^$' | tail -1)
  [[ -z "$branch" ]] && return 1

  slug=$(branch_to_slug "$branch")
  base_name=$(basename "$git_rt")
  new_path="$(dirname "$git_rt")/${base_name}-${slug}"

  echo "Creating worktree: $new_path  (branch: $branch)" >&2

  if git -C "$git_rt" show-ref --verify --quiet "refs/heads/$branch" ||
     git -C "$git_rt" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    # Branch exists locally or on remote — check it out (git DWIM creates tracking branch)
    git -C "$git_rt" worktree add "$new_path" "$branch" >&2
  else
    # Truly new name typed by user — create branch from current HEAD
    git -C "$git_rt" worktree add -b "$branch" "$new_path" >&2
  fi

  if [[ $? -eq 0 ]]; then
    WORKTREE_PATH="$new_path"
    return 0
  else
    echo "Error: failed to create worktree" >&2
    return 1
  fi
}

_remove_worktree() {
  local git_rt="$1"
  local main_wt
  main_wt=$(git_main_worktree)

  local -a removable
  local _wt_path _display
  while IFS=$'\t' read -r _wt_path _display; do
    [[ "$_wt_path" == __* ]] && continue
    [[ "$_wt_path" == "$main_wt" ]] && continue
    removable+=("${_wt_path}"$'\t'"${_display}")
  done < <(get_worktrees)

  if (( ${#removable} == 0 )); then
    echo "No linked worktrees to remove." >&2
    return 0
  fi

  local raw to_remove fzf_exit
  raw=$(
    printf '%s\n' "${removable[@]}" | $FZF_BIN \
      "${FZF_THEME_OPTS[@]}" \
      --prompt=" Remove › " \
      --border-label=" ✳ Remove Worktree " \
      --height=~12 \
      --layout=reverse \
      --delimiter=$'\t' \
      --with-nth=2
  )
  fzf_exit=$?
  (( fzf_exit == 130 )) && exit 130
  [[ -z "$raw" ]] && return 0
  to_remove=$(printf '%s' "$raw" | cut -d$'\t' -f1)

  echo "Removing worktree: $to_remove" >&2
  git worktree remove "$to_remove" >&2
  git worktree prune >&2
}

launch_in_tmux() {
  command -v tmux &>/dev/null || { echo "Error: tmux not found in PATH." >&2; exit 1; }

  local label="$profile"
  [[ -n "$WORKTREE_BRANCH" ]] && label="${profile}-$(branch_to_slug "$WORKTREE_BRANCH")"

  local tmpf
  tmpf=$(mktemp)
  show_splash "$profile" "$WORKTREE_BRANCH" >"$tmpf"

  local _cmd="cat ${(q+)tmpf}; rm -f ${(q+)tmpf}; CLAUDE_CONFIG_DIR=${(q+)CLAUDE_CONFIG_DIR} ${(q+)CLAUDE_BIN}${@:+ ${(q+j: :)@}}"

  if [[ -n "$TMUX" ]]; then
    tmux new-window -n "$label" -c "$PWD" "$_cmd"
  else
    exec tmux new-session -A -s "$label" -c "$PWD" "$_cmd"
  fi
}

pick_worktree() {
  local git_rt
  git_rt=$(git_root) || return 0

  local raw selected
  local -a wt_lines

  while true; do
    wt_lines=()
    local _raw_line
    while IFS= read -r _raw_line; do
      local _f1="${_raw_line%%$'\t'*}"
      case "$_f1" in
        __here__|__new__|__remove__|/*) wt_lines+=("$_raw_line") ;;
      esac
    done < <(get_worktrees)

    local fzf_exit
    raw=$(
      printf '%s\n' "${wt_lines[@]}" | $FZF_BIN \
        "${FZF_THEME_OPTS[@]}" \
        --prompt=" Worktree › " \
        --border-label=" ✳ Git Worktrees " \
        --height=60% \
        --min-height=24 \
        --layout=reverse \
        --delimiter=$'\t' \
        --with-nth=2 \
        --preview='sh -c "$_CLD_WORKTREE_PREV" -- {1}' \
        --preview-window='right:45%:border-rounded:noinfo' \
        --preview-label=" worktree info "
    )
    fzf_exit=$?
    (( fzf_exit == 130 )) && exit 130

    if [[ -z "$raw" ]]; then
      WORKTREE_PATH=""
      return 0
    fi

    selected=$(printf '%s' "$raw" | cut -d$'\t' -f1)

    case "$selected" in
      __here__)
        WORKTREE_PATH=""
        return 0
        ;;
      __new__)
        _create_worktree "$git_rt" && return 0
        ;;
      __remove__)
        _remove_worktree "$git_rt"
        ;;
      *)
        WORKTREE_PATH="$selected"
        return 0
        ;;
    esac
  done
}

# ── Pre-process: strip -w/--worktree from args ───────────────────────────────

force_wt=0
use_tmux=0
new_args=()
for _a in "$@"; do
  if [[ "$_a" == "-wt" ]]; then
    force_wt=1
    use_tmux=1
  elif [[ "$_a" == "-w" || "$_a" == "--worktree" ]]; then
    force_wt=1
  elif [[ "$_a" == "-t" || "$_a" == "--tmux" ]]; then
    use_tmux=1
  else
    new_args+=("$_a")
  fi
done
set -- "${new_args[@]}"

# ── Profile selection ────────────────────────────────────────────────────────

allowed=(${(f)"$(get_allowed_profiles)"})

if [[ -n "$1" ]] && ! [[ "$1" == -* ]]; then
  profile="$1"
  shift

  if ! profile_exists "$profile"; then
    echo "Error: Unknown profile '$profile'" >&2
    echo "Available profiles: $($JQ_BIN -r '.profiles | keys | join(", ")' "$CONFIG_FILE")" >&2
    exit 1
  fi

  if ! (( ${allowed[(Ie)$profile]} )); then
    echo "Error: Profile '$profile' is not allowed for directory: $PWD" >&2
    if (( ${#allowed} > 0 )); then
      echo "Allowed profiles here: ${(j:, :)allowed}" >&2
    else
      echo "No profiles are configured for this directory." >&2
    fi
    exit 1
  fi
elif (( ${#allowed} == 0 )); then
  echo "Error: No profiles are configured for directory: $PWD" >&2
  echo "Configure directories in: $CONFIG_FILE" >&2
  exit 1
elif (( ${#allowed} == 1 )); then
  profile="${allowed[1]}"
else
  fzf_input=""
  for p in "${allowed[@]}"; do
    desc="$(get_description "$p")"
    fzf_input+="$p - $desc"$'\n'
  done

  selected=$(
    print -r -- "$fzf_input" | $FZF_BIN \
      "${FZF_THEME_OPTS[@]}" \
      --prompt=" Profile › " \
      --border-label=" ✳ Claude Code " \
      --height=~15 \
      --layout=reverse \
      --preview='sh -c "$_CLD_PROFILE_PREV" -- {}' \
      --preview-window='right:40%:border-rounded:noinfo' \
      --preview-label=" profile info "
  )
  fzf_exit=$?
  (( fzf_exit == 130 )) && exit 130
  if [[ -z "$selected" ]]; then
    echo "No profile selected." >&2
    exit 1
  fi
  profile="${selected%% - *}"
fi

# ── Worktree selection ───────────────────────────────────────────────────────

export CLAUDE_CONFIG_DIR="$HOME/.config/claude-code/$profile"

WORKTREE_PATH="" WORKTREE_BRANCH=""
if is_git_repo; then
  _wt_count=$(git worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
  if (( _wt_count >= 2 || force_wt )); then
    pick_worktree
  fi
fi

if [[ -n "$WORKTREE_PATH" ]]; then
  WORKTREE_BRANCH=$(git -C "$WORKTREE_PATH" branch --show-current 2>/dev/null)
  cd "$WORKTREE_PATH" || { echo "Error: cannot cd to $WORKTREE_PATH" >&2; exit 1 }
fi

if (( use_tmux )); then
  launch_in_tmux "$@"
else
  show_splash "$profile" "$WORKTREE_BRANCH"
  exec "$CLAUDE_BIN" "$@"
fi
