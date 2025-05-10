#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  main.sh  –  single entry‑point for Yuvraj's Arch‑Installer
#
#  Usage examples:
#     sudo ./main.sh --task partition
#     sudo ./main.sh --task partition,arch
#     sudo ./main.sh --task all -y            # non‑interactive for non‑partition tasks
# ---------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source $"REPO_DIR/lib/logging.sh"


# ---- command‑line parsing ------------------------------------------
usage() {
  cat << EOF
Usage: $0 --task <tag>[,<tag>…] [options]

Tags:
  partition      interactive disk/partition setup
  arch           base Arch installation
  dev            developer tooling
  all            partition + arch + dev

Options:
  -t|--task <...>          required; comma‑separated list or 'all'
  -y|--yes                 non‑interactive for *non‑partition* tasks
  -h|--help                show this help and exit
EOF
}

TASKS=()
NON_INTERACTIVE=false

LONGOPTS=task:,yes,help
OPTS=$(getopt -o t:yh --long "$LONGOPTS" -- "$@") || { usage; exit 1; }
eval set -- "$OPTS"

while true; do
  case "$1" in
    -t|--task) IFS=',' read -ra TASKS <<< "$2"; shift 2 ;;
    -y|--yes)  NON_INTERACTIVE=true;                shift ;;
    -h|--help) usage;                               exit 0 ;;
    --) shift; break ;;
    *) usage; exit 1 ;;
  esac
done

[[ ${#TASKS[@]} -eq 0 ]] && { log_error "No --task supplied"; usage; exit 1; }

# ---- expand meta‑tag 'all' -----------------------------------------
for i in "${!TASKS[@]}"; do
  [[ ${TASKS[i]} == "all" ]] && { TASKS=(partition arch dev); break; }
done

# ---- export context for downstream tasks ---------------------------
export REPO_DIR
export NON_INTERACTIVE             # partition task ignores this

# ---- run tasks in sequence -----------------------------------------
for TASK in "${TASKS[@]}"; do
  TASK_FILE="$REPO_DIR/tasks/${TASK}.sh"
  if [[ ! -f $TASK_FILE ]]; then
    log_error "Unknown task: $TASK"
    exit 1
  fi

  log_info "Running task: $TASK"
  source "$TASK_FILE"
  run                         # each task defines its own run() function
done

log_success "All specified tasks completed ✔"
