#!/usr/bin/env bash
# --------------------------------------------------------------------
# tasks/partition.sh  –  interactive disk / partition setup
#   • always interactive (ignores $NON_INTERACTIVE)
#   • lists disks and *all* partitions with current FS status
#   • no duplicate /dev paths
# --------------------------------------------------------------------
run() {
  source "$REPO_DIR/lib/ui.sh"     # whiptail helpers

  show_layout
  pick_target            # sets TARGET_PATH + TARGET_TYPE (D=whole disk, P=part)
  choose_fs              # sets INSTALL_FS
  confirm_layout         # final “are you sure?”
  do_partitioning
  log_success "Partitioning complete"
}

# ----- 1. show current layout in a scrollable textbox ----------------
show_layout() {
  local tmp
  tmp="$(mktemp)"
  lsblk -f > "$tmp"
  whiptail --title "Current Disk Layout (lsblk -f)" \
           --textbox "$tmp" 25 80
  rm -f "$tmp"
}

# ----- 2. let user select disk OR partition --------------------------
pick_target() {
  local menu=()

  # Whole disks first
  while read -r path size model; do
    menu+=("$path" "$(printf '%-4s %-8s %s' 'DISK' "$size" "$model")")
  done < <(lsblk -dprno PATH,SIZE,MODEL)

  # Then every partition (empty or not)
  while read -r path size fstype _; do
    local status=${fstype:-EMPTY}
    menu+=("$path" "$(printf '%-4s %-8s %s' 'PART' "$size" "$status")")
  done < <(lsblk -prno PATH,SIZE,FSTYPE,TYPE | awk '$4=="part"')

  TARGET_PATH=$(ui_menu "Select Install Target" \
                "Pick a whole disk OR an existing partition" \
                "${menu[@]}") || exit 1

  if [[ $(lsblk -no TYPE "$TARGET_PATH") == "disk" ]]; then
    TARGET_TYPE="D"
  else
    TARGET_TYPE="P"
  fi
}

# ----- 3. choose root filesystem ------------------------------------
choose_fs() {
  INSTALL_FS=$(ui_menu "Filesystem" "Choose a filesystem for root" \
               "btrfs" "B‑tree FS (snapshots/compression)" \
               "ext4"  "Classic ext4" \
               "xfs"   "Scalable XFS") || exit 1
}

# ----- 4. show exactly what will change, ask for confirmation --------
confirm_layout() {
  echo
  echo "Planned changes:"
  if [[ $TARGET_TYPE == "D" ]]; then
    echo "• Re‑partition $TARGET_PATH completely:"
    echo "    • EFI     1 GiB  (FAT32)"
    echo "    • swap    8 GiB"
    echo "    • root    ${INSTALL_FS}  (rest)"
  else
    local fstype mount
    read -r _ _ fstype mount < <(lsblk -prno PATH,FSTYPE,MOUNTPOINT <<< "$TARGET_PATH")
    echo "• Format partition $TARGET_PATH as ${INSTALL_FS}"
    [[ -n $fstype ]] && echo "  (current FS: $fstype ${mount:+mounted on $mount})"
    echo "  NOTE: no other partitions will be touched."
  fi

  ui_yesno "Proceed?" || exit 1
}

# ----- 5. do the work ------------------------------------------------
do_partitioning() {
  if [[ $TARGET_TYPE == "D" ]]; then
    wipefs -af "$TARGET_PATH"
    sgdisk --zap-all "$TARGET_PATH"

    log_info "Creating GPT on $TARGET_PATH"
    parted -s "$TARGET_PATH" mklabel gpt
    parted -s "$TARGET_PATH" mkpart primary fat32 1MiB 1GiB
    parted -s "$TARGET_PATH" set 1 esp on
    parted -s "$TARGET_PATH" mkpart primary linux-swap 1GiB 9GiB
    parted -s "$TARGET_PATH" mkpart primary "$INSTALL_FS" 9GiB 100%

    local boot="${TARGET_PATH}1" swap="${TARGET_PATH}2" root="${TARGET_PATH}3"
    mkfs.vfat -F32 "$boot"
    mkswap          "$swap"

    case "$INSTALL_FS" in
      btrfs) mkfs.btrfs -f "$root" ;;
      ext4)  mkfs.ext4  -F "$root" ;;
      xfs)   mkfs.xfs   -f "$root" ;;
    esac
  else
    log_warn "Formatting single partition $TARGET_PATH → ${INSTALL_FS}"
    wipefs -af "$TARGET_PATH"
    case "$INSTALL_FS" in
      btrfs) mkfs.btrfs -f "$TARGET_PATH" ;;
      ext4)  mkfs.ext4  -F "$TARGET_PATH" ;;
      xfs)   mkfs.xfs   -f "$TARGET_PATH" ;;
    esac
  fi
}
