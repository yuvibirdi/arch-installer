#!/usr/bin/env bash
# lib/ui.sh  —  minimal yet extensible helper for interactive shells
set -euo pipefail

# If the caller exports NON_INTERACTIVE=true we bypass all prompts
shopt -s expand_aliases
[[ ${NON_INTERACTIVE:-false} == true ]] && alias _skip='true' || alias _skip='false'

ui_menu() {            # ui_menu <title> <prompt> <array items...>
  _skip && { echo "${3-}"; return 0; }
  local title=$1 text=$2; shift 2
  local choice
  choice=$(whiptail --title "$title" --menu "$text" 20 78 10 "$@" 3>&1 1>&2 2>&3) || return 1
  echo "$choice"
}

ui_yesno() {           # ui_yesno <text>
  _skip && return 0
  whiptail --yesno "$1" 10 60
}

ui_input() {           # ui_input <prompt> [default]
  _skip && { echo "${2-}"; return 0; }
  local out
  out=$(whiptail --inputbox "$1" 10 60 "${2-}" 3>&1 1>&2 2>&3) || return 1
  echo "$out"
}
