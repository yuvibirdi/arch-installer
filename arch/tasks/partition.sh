#!/usr/bin/env bash
run() {
  source "$REPO_DIR/lib/ui.sh"

  pick_target           # sets TARGET_TYPE=D|P and TARGET_PATH
  confirm_layout        # shows exactly what will change
  do_partitioning       # executes partitioning
}

pick_target() {
  local menu_items=()
  # Build menu: disks first
  while read -r name size model; do
    menu_items+=("/dev/$name" "DISK  $size  $model")
  done < <(lsblk -dno NAME,SIZE,MODEL)

  # …then every partition that is *unformatted* (no FS or swap)
  while read -r name size; do
    menu_items+=("/dev/$name" "PART  $size  **unused**")
  done < <(lsblk -prno NAME,SIZE,FSTYPE | awk '$3==""{print $1,$2}')

  TARGET_PATH=$(ui_menu "Select Install Target" \
                "Pick a whole disk OR an empty partition" \
                "${menu_items[@]}") || exit 1

  if [[ $(lsblk -no TYPE "$TARGET_PATH") == "disk" ]]; then
    TARGET_TYPE="D"
  else
    TARGET_TYPE="P"
  fi
}

confirm_layout() {
  echo -e "\nPlanned changes:"
  if [[ $TARGET_TYPE == "D" ]]; then
    echo "• Completely repartition $TARGET_PATH:"
    echo "  EFI 1 GiB, swap 8 GiB, root (${INSTALL_FS}) rest"
  else
    echo "• Format single partition $TARGET_PATH as ${INSTALL_FS}"
    echo "  (you must have an EFI partition already)."
  fi

  ui_yesno "Is that OK?" || exit 1
}

do_partitioning() {
  if [[ $TARGET_TYPE == "D" ]]; then
    wipefs -af "$TARGET_PATH"
    sgdisk --zap-all "$TARGET_PATH"
    # … same as before creating three partitions …
  else
    wipefs -af "$TARGET_PATH"
    case "$INSTALL_FS" in
      ext4)  mkfs.ext4 -F "$TARGET_PATH" ;;
      btrfs) mkfs.btrfs -f "$TARGET_PATH" ;;
      xfs)   mkfs.xfs  -f "$TARGET_PATH" ;;
    esac
  fi
}
