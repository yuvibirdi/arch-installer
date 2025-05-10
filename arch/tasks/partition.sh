#!/usr/bin/env bash
# --------------------------------------------------------------------
# tasks/partition.sh  –  interactive disk / partition setup
# --------------------------------------------------------------------
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
  done < <(lsblk -dprno PATH,SIZE,MODEL)

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
  local parts
  parts=$(lsblk -n "$TARGET_PATH" | tail -n +2 || true)
  if [[ -n $parts ]]; then
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

create_in_gap() {
  # find largest free gap in MiB
  read -r start end < <(
    parted -sm "$TARGET_PATH" unit MiB print free | awk -F: '$1 ~ /^[0-9]+$/ {gsize=$3-$2; if (gsize>max){max=gsize; s=$2; e=$3}} END{print s,e}'
  )
  if [[ -z $start || -z $end ]]; then
    log_error "No suitable free space found"; exit 1
  fi
  local swap_start=$start
  local swap_end=$((swap_start+8192))   # 8 GiB
  local root_start=$swap_end
  local root_end=$end

  parted -s "$TARGET_PATH" mkpart primary linux-swap ${swap_start}MiB ${swap_end}MiB
  local pnum_swap; pnum_swap=$(lsblk -prno PARTNUM "${TARGET_PATH}$(lsblk -rpno NAME | grep -o '[0-9]*$' | sort -n | tail -1)") # last partnum
  mkswap "${TARGET_PATH}${pnum_swap}"

  parted -s "$TARGET_PATH" mkpart primary "$INSTALL_FS" ${root_start}MiB ${root_end}MiB
  local root_part="${TARGET_PATH}$(lsblk -rpno NAME | grep "^${TARGET_PATH}" | sort | tail -1 | grep -o '[0-9]*$')"
  format_partition "$root_part"
}
