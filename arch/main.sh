#!/usr/bin/env bash
# ---------------------------------------------------------------------
#  main.sh  –  single entry-point for Yuvraj's Arch-Installer
#
#  Usage examples:
#      ./main.sh --task partition
#      ./main.sh --task partition,arch
#      ./main.sh --task all -y            # non-interactive for non-partition tasks
# ---------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$REPO_DIR/lib/logging.sh"

# ---- command-line parsing ------------------------------------------
usage() {
    cat << EOF
Usage: $0 --task <tag>[,<tag>…] [options]

Tags:
  partition      interactive disk/partition setup
  base           base Arch installation
  dev            developer tooling
  all            partition + arch + dev
  arch           shortcut for partition + base + packages + post

Options:
  -t|--task <...>          required; comma-separated list or 'all'
  -y|--yes                 non-interactive for *non-partition* tasks
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

# ---- expand meta-tags -----------------------------------------
EXPANDED_TASKS=()
for task in "${TASKS[@]}"; do
    case "$task" in
        # this wont work becuase this the packages and post dev working with inside the filesystem whereas partition and base work from the archiso 
        # all) 
        #   EXPANDED_TASKS+=(partition base packages post dev)
        #   ;;
        arch-install)
            EXPANDED_TASKS+=(partition base)
            ;;
        *)
            EXPANDED_TASKS+=("$task")
            ;;
    esac
done
TASKS=("${EXPANDED_TASKS[@]}")

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
