#!/usr/bin/env bash
# --------------------------------------------------------------------
# tasks/partition.sh  –  interactive disk / partition setup
# --------------------------------------------------------------------
set -o errexit -o nounset -o pipefail
set -x
run() {
    source "$REPO_DIR/lib/ui.sh"     # whiptail helpers

    show_layout
    pick_target           # sets TARGET_PATH + TARGET_TYPE (D=whole disk, P=part)
    if [[ $TARGET_TYPE == "D" ]]; then
	decide_disk_mode  # sets DISK_MODE = wipe | gap
    fi
    choose_fs             # sets INSTALL_FS
    confirm_plan
    do_partitioning
    log_success "Partitioning complete"
}

# ----- 1. show current layout prettier -------------------------------
show_layout() {
    local tmp; tmp=$(mktemp)
    lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS,TYPE | column -t > "$tmp"
    whiptail --title "Current Disk Layout" --textbox "$tmp" 25 90
    rm -f "$tmp"
}

# ----- 2. pick disk or partition -------------------------------------
pick_target() {
    local menu=()
    while read -r path size model; do
	menu+=("$path" "$(printf 'DISK  %-8s %s' "$size" "$model")")
    done < <(lsblk -dprno PATH,SIZE,MODEL,TYPE | awk '$4=="disk" {print $1,$2,$3}')

    while read -r path size fstype _; do
	menu+=("$path" "$(printf 'PART  %-8s %s' "$size" "${fstype:-EMPTY}")")
    done < <(lsblk -prno PATH,SIZE,FSTYPE,TYPE | awk '$4=="part"')

    TARGET_PATH=$(ui_menu "Select Install Target" \
			  "Choose a whole disk OR an existing partition" \
			  "${menu[@]}") || exit 1

    [[ $(lsblk -no TYPE "$TARGET_PATH") == "disk" ]] && TARGET_TYPE="D" || TARGET_TYPE="P"
}

# ----- 2b. if disk already has partitions ask wipe vs gap ------------
decide_disk_mode() {
    if lsblk -prno TYPE "$TARGET_PATH" | grep -q '^part$'; then
	local choice
	choice=$(ui_menu "Existing Partitions Detected" \
			 "What should we do with $TARGET_PATH ?" \
			 "wipe" "❌  Wipe entire disk (DESTROYS EVERYTHING)" \
			 "gap"  "➕  Use the largest free space only") || exit 1
	DISK_MODE=$choice
    else
	DISK_MODE=wipe
    fi
}

# ----- 3. choose filesystem ------------------------------------------
choose_fs() {
    INSTALL_FS=$(ui_menu "Filesystem" "Choose a filesystem for root" \
			 "btrfs" "B‑tree FS (snapshots/compression)" \
			 "ext4"  "Classic ext4" \
			 "xfs"   "Scalable XFS") || exit 1
}

# ----- 4. final confirmation -----------------------------------------
confirm_plan() {
    echo
    echo "Planned changes:"
    if [[ $TARGET_TYPE == "D" ]]; then
	if [[ $DISK_MODE == "wipe" ]]; then
	    echo "• Wipe and re‑partition $TARGET_PATH:"
	    echo "    EFI 1 GiB, swap 8 GiB, root (${INSTALL_FS}) rest"
	else
	    echo "• Create new partitions in the largest free space on $TARGET_PATH:"
	    echo "    swap 8 GiB  +  root (${INSTALL_FS})  (rest of gap)"
	fi
    else
	local fstype mount
	read -r _ _ fstype mount < <(lsblk -prno PATH,FSTYPE,MOUNTPOINT <<< "$TARGET_PATH")
	echo "• Format $TARGET_PATH as ${INSTALL_FS}"
	[[ -n $fstype ]] && echo "  (currently $fstype ${mount:+mounted on $mount})"
    fi
    ui_yesno "Proceed?" || exit 1
}

# ----- 5. do the work ------------------------------------------------
do_partitioning() {
    if [[ $TARGET_TYPE == "P" ]]; then
	format_partition "$TARGET_PATH"
	return
    fi

    if [[ $DISK_MODE == "wipe" ]]; then
	wipefs -af "$TARGET_PATH"
	sgdisk --zap-all "$TARGET_PATH"
	create_gpt_full
    else
	create_in_gap
    fi
}

# --- helpers ---------------------------------------------------------
format_partition() {
    local p=$1
    log_warn "Formatting $p → $INSTALL_FS"
    wipefs -af "$p"
    case "$INSTALL_FS" in
	btrfs) mkfs.btrfs -f "$p" ;;
	ext4)  mkfs.ext4  -F "$p" ;;
	xfs)   mkfs.xfs   -f "$p" ;;
    esac
}

create_gpt_full() {
    parted -s "$TARGET_PATH" mklabel gpt
    parted -s "$TARGET_PATH" mkpart primary fat32 1MiB 1GiB
    parted -s "$TARGET_PATH" set 1 esp on
    parted -s "$TARGET_PATH" mkpart primary linux-swap 1GiB 9GiB
    parted -s "$TARGET_PATH" mkpart primary "$INSTALL_FS" 9GiB 100%

    mkfs.vfat -F32 "${TARGET_PATH}1"
    mkswap         "${TARGET_PATH}2"
    format_partition "${TARGET_PATH}3"
}

# --------------------------------------------------------------------
# Replace the old create_in_gap() in tasks/partition.sh with THIS:
# --------------------------------------------------------------------
create_in_gap() {
    # ----- gather disk + partition geometry in MiB --------------------
    local disk_bytes disk_mib
    disk_bytes=$(lsblk -brno SIZE "$TARGET_PATH")
    disk_mib=$(( disk_bytes / 1024 / 1024 ))

    # Build an ordered list of [start_mib end_mib] for existing parts
    local parts=()
    while read -r start size; do
	start=$(( start / 1024 / 1024 ))
	size=$(( size  / 1024 / 1024 ))
	parts+=( "$start" "$((start+size))" )
    done < <(lsblk -brno START,SIZE "$TARGET_PATH")

    # ----- scan for the largest free gap ------------------------------
    local prev_end=1        # keep first MiB free for GPT/MBR
    local best_gap=0 gap_s=0 gap_e=0

    for ((i=0; i<${#parts[@]}; i+=2)); do
	local s=${parts[i]} e=${parts[i+1]}
	if (( s - prev_end > best_gap )); then
	    best_gap=$(( s - prev_end ))
	    gap_s=$prev_end
	    gap_e=$s
	fi
	prev_end=$e
    done
    # tail gap
    if (( disk_mib - prev_end > best_gap )); then
	best_gap=$(( disk_mib - prev_end ))
	gap_s=$prev_end
	gap_e=$disk_mib
    fi

    if (( best_gap < 9000 )); then
	log_error "Largest free gap (${best_gap} MiB) is too small for swap+root"
	exit 1
    fi

    # ----- carve swap + root in that gap ------------------------------
    local swap_s=$gap_s
    local swap_e=$(( swap_s + 8192 ))          # 8 GiB swap
    local root_s=$swap_e
    local root_e=$gap_e

    log_info "Creating 8 GiB swap at ${swap_s}-${swap_e} MiB"
    log_info "Creating ${INSTALL_FS} root at ${root_s}-${root_e} MiB"

    parted -s "$TARGET_PATH" mkpart primary linux-swap  ${swap_s}MiB ${swap_e}MiB
    local swap_part
    swap_part=$(lsblk -prno NAME "$TARGET_PATH" | tail -1)
    mkswap "$swap_part"

    parted -s "$TARGET_PATH" mkpart primary "$INSTALL_FS" ${root_s}MiB ${root_e}MiB
    local root_part
    root_part=$(lsblk -prno NAME "$TARGET_PATH" | tail -1)
    format_partition "$root_part"
}
