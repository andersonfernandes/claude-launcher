#!/bin/zsh

# Claude Launcher - profile-based claude config selector
# Usage: cld [profile] [claude-args...]

SCRIPT_DIR="${0:A:h}"
CONFIG_FILE="$SCRIPT_DIR/profiles.json"
FZF_BIN="$HOME/.local/share/nvim/site/pack/packer/start/fzf/bin/fzf"
JQ_BIN="/usr/bin/jq"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Error: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

# Get profiles whose directories are a prefix match for $PWD
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

# Get description for a profile
get_description() {
  $JQ_BIN -r --arg name "$1" '.profiles[$name].description // ""' "$CONFIG_FILE"
}

# Validate that a profile exists in the config
profile_exists() {
  $JQ_BIN -e --arg name "$1" '.profiles[$name]' "$CONFIG_FILE" >/dev/null 2>&1
}

# Splash line
show_splash() {
  local CO="\033[1;38;2;245;158;11m"
  local DIM="\033[2m"
  local R="\033[0m"
  local dir="${PWD/#$HOME/~}"
  echo -e "${CO}✦ Claude Code${R} ${DIM}·${R} ${CO}${1}${R} ${DIM}·${R} ${DIM}${dir}${R}"
}

# Collect allowed profiles
allowed=(${(f)"$(get_allowed_profiles)"})

# Determine which profile to use
if [[ -n "$1" ]] && ! [[ "$1" == -* ]]; then
  # Profile name given as argument
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
  echo "Auto-selected profile: $profile"
else
  # Multiple matches - use fzf
  fzf_input=""
  for p in "${allowed[@]}"; do
    desc="$(get_description "$p")"
    fzf_input+="$p - $desc"$'\n'
  done

  selected=$( echo "$fzf_input" | $FZF_BIN --prompt="Select profile> " --height=~10 --reverse )
  if [[ -z "$selected" ]]; then
    echo "No profile selected." >&2
    exit 1
  fi
  profile="${selected%% -*}"
fi

export CLAUDE_CONFIG_DIR="$HOME/.config/claude-code/$profile"
show_splash "$profile"
exec /home/anderson/.local/bin/claude "$@"
