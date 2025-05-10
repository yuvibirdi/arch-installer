#!/usr/bin/env bash
# --------------------------------------------------------------------
# Automatic 3‑slice partitioner:
#   • Whole‑disk  → wipe + 3 fresh slices
#   • Single part → replace that slice with 3 fresh slices
# --------------------------------------------------------------------
run() {
  source "$REPO_DIR/lib/ui.sh"   # whiptail helpers

  pick_target               # TARGET  TARGET_TYPE=D|P
  choose_fs                 # ROOT_FS
  confirm_plan
  [[ $TARGET_TYPE == "D" ]] && full_disk_layout || slice_layout
  log_success "Partitioning complete ✔"
}

# ---------- pick disk or partition ----------------------------------
pick_target() {
  local menu=()
  while read -r path size model; do
    menu+=("$path" "$(printf 'DISK  %-8s %s' "$size" "$model")")
  done < <(lsblk -dprno PATH,SIZE,MODEL,TYPE | awk '$4=="disk"')

  while read -r path size fstype; do
    menu+=("$path" "$(printf 'PART  %-8s %s' "$size" "${fstype:-EMPTY}")")
  done < <(lsblk -prno PATH,SIZE,FSTYPE,TYPE | awk '$4=="part"')

  TARGET=$(ui_menu "Select Install Target" \
           "Pick a whole disk OR an existing partition slice" \
           "${menu[@]}") || exit 1

  [[ $(lsblk -no TYPE "$TARGET") == "disk" ]] && TARGET_TYPE=D || TARGET_TYPE=P
}

choose_fs() {
  ROOT_FS=$(ui_menu "Root Filesystem" "Choose a filesystem" \
             "ext4" "" "btrfs" "" "xfs" "") || exit 1
}

confirm_plan() {
  echo
  echo "Plan:"
  if [[ $TARGET_TYPE == "D" ]]; then
    echo "• Wipe $TARGET and create:"
  else
    echo "• Replace $TARGET with:"
  fi
  echo "    1 GiB  FAT32  /boot"
  echo "    8 GiB  swap"
  echo "    rest   $ROOT_FS  /"
  ui_yesno "Proceed?" || exit 1
}

# ---------- layout for whole disk -----------------------------------
full_disk_layout() {
  log_warn "WIPING entire disk $TARGET"
  wipefs -af "$TARGET"
  sgdisk --zap-all "$TARGET"

  log_info "Writing GPT"
  sgdisk -n 1::+1GiB   -t 1:EF00 -c 1:"boot" "$TARGET"
  sgdisk -n 2::+8GiB   -t 2:8200 -c 2:"swap" "$TARGET"
  sgdisk -n 3::-0      -t 3:8300 -c 3:"root" "$TARGET"

  partprobe "$TARGET"
  post_format "${TARGET}1" "${TARGET}2" "${TARGET}3"
}

# ---------- layout inside existing slice ----------------------------
slice_layout() {
  local parent disk partnum start end
  disk=$(lsblk -no PKNAME "$TARGET")
  parent="/dev/$disk"
  partnum=$(lsblk -no PARTNUM "$TARGET")
  read -r start end < <(sgdisk -i "$partnum" "$parent" | awk '/first sector/ {s=$4} /last sector/ {e=$4} END{print s,e}')

  log_warn "Re‑using slice $TARGET (sectors $start‑$end) on $parent"
  sgdisk --delete="$partnum" "$parent"

  local sz_boot=$(( 1 * 1024 * 1024 * 1024 / 512 ))   # sectors
  local sz_swap=$(( 8 * 1024 * 1024 * 1024 / 512 ))
  local s_boot=$start
  local e_boot=$(( s_boot + sz_boot - 1 ))
  local s_swap=$(( e_boot + 1 ))
  local e_swap=$(( s_swap + sz_swap - 1 ))
  local s_root=$(( e_swap + 1 ))
  local e_root=$end

  sgdisk -n $partnum:$s_boot:$e_boot   -t $partnum:EF00 -c $partnum:"boot" "$parent"
  sgdisk -n $((partnum+1)):$s_swap:$e_swap -t $((partnum+1)):8200 -c $((partnum+1)):"swap" "$parent"
  sgdisk -n $((partnum+2)):$s_root:$e_root -t $((partnum+2)):8300 -c $((partnum+2)):"root" "$parent"

  partprobe "$parent"
  local boot="${parent}$partnum"
  local swap="${parent}$((partnum+1))"
  local root="${parent}$((partnum+2))"
  post_format "$boot" "$swap" "$root"
}

# ---------- common formatting logic ---------------------------------
post_format() {
  local boot=$1 swap=$2 root=$3
  log_info "mkfs.vfat  $boot"
  mkfs.vfat -F32 "$boot"

  log_info "mkswap     $swap"
  mkswap "$swap"

  log_info "mkfs.$ROOT_FS $root"
  case "$ROOT_FS" in
    ext4)  mkfs.ext4  -F "$root" ;;
    btrfs) mkfs.btrfs -f "$root" ;;
    xfs)   mkfs.xfs   -f "$root" ;;
  esac
}
