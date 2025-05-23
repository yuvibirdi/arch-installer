#!/usr/bin/env bash
set -eo pipefail

run() {
    source "$REPO_DIR/lib/ui.sh"        # ui_menu, ui_yesno, ui_input …
    source "$REPO_DIR/lib/logging.sh"   # log_info, log_error, log_success …

    # ------------------------------------------------------------------
    BOOT_MB=1024
    SWAP_MB=8192
    # Helper functions
    error() {
	log_error "$1"
	# echo -e "\e[90m[DEBUG]\e[0m Exiting from ${FUNCNAME[1]} at line ${BASH_LINENO[0]}" >&2
	exit 1
    }
    info()  { log_warn "$1"; }
    log()   { log_info "$1"; }          
    # Prompt user to choose root filesystem type
    select_root_fs() {
	local fs
	fs=$(ui_menu "Select Filesystem" \
		     "Choose the filesystem to use for the root partition:" \
		     "ext4" "Default, general-purpose Linux FS" \
		     "btrfs" "Advanced FS with snapshotting" \
		     "xfs" "High-performance FS, no shrink support") || return 1 
	echo "$fs"
    }
    mount_and_format_partitions() {
	local boot_p=$1
	local swap_p=$2
	local root_p=$3

	case "$FS_TYPE" in
            ext4)
		mkfs.fat -F32 "$boot_p"
		mkswap "$swap_p"
		mkfs.ext4 -F "$root_p"

		mount "$root_p" /mnt
		mkdir -p /mnt/boot/efi
		mount "$boot_p" /mnt/boot/efi
		swapon "$swap_p"
		;;
            btrfs)
		mkfs.fat -F32 "$boot_p"
		mkswap "$swap_p"
		mkfs.btrfs -f "$root_p"

		mount "$root_p" /mnt
		btrfs subvolume create /mnt/@
		btrfs subvolume create /mnt/@home
		btrfs subvolume create /mnt/@var
		btrfs subvolume create /mnt/@snapshots
		umount /mnt

		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@ "$root_p" /mnt
		mkdir -p /mnt/{boot/efi,home,var,.snapshots}
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@home "$root_p" /mnt/home
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@var "$root_p" /mnt/var
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@snapshots "$root_p" /mnt/.snapshots

		mount "$boot_p" /mnt/boot/efi
		swapon "$swap_p"
		;;
            *)
		error "Unsupported FS type for mounting: $FS_TYPE"
		;;
	esac
    }

    # Function to list disks and partitions for selection
    select_target() {
	local menu=()
	while IFS= read -r line; do
            name=$(echo "$line" | awk '{print $1}')
            size=$(echo "$line" | awk '{print $2}')
            type=$(echo "$line" | awk '{print $3}')
            label="$name ($type, $size)"
            menu+=("$name" "$label")
	done < <(lsblk -dnpo NAME,SIZE,TYPE)

	ui_menu "Select Disk or Partition" \
		"Select one disk or partition to use:" \
		"${menu[@]}"
    }
    # Function to create a full disk partition layout
    create_gpt_layout() {
	local disk=$1
	log "Creating full disk partition layout on $disk"
	info "Creating full disk partition layout on $disk"
	# Use consistent MiB units for exact sizes
	parted --script --align optimal "$disk" \
	       mklabel gpt \
	       mkpart primary fat32 1MiB 1025MiB \
	       set 1 boot on \
	       mkpart primary linux-swap 1025MiB 9217MiB \
	       mkpart primary ext4 9217MiB 100%

	# Ensure kernel recognizes the new partitions
	partprobe "$disk"
	udevadm settle
	sleep 2

	mapfile -t parts < <(lsblk -prno NAME "$disk" | tail -3)
	boot_part=${parts[0]} ; swap_part=${parts[1]} ; root_part=${parts[2]}

	mount_and_format_partitions "$boot_part" "$swap_part" "$root_part"
    }
    # Function to carve 3 slices inside one existing partition
    replace_partition_with_slices() {
        local part=$1                     # e.g. /dev/sda3
        local disk partnum start end
        disk="/dev/$(lsblk -no PKNAME "$part")"
	partnum=$(basename "$part" | sed -E 's/.*[^0-9]([0-9]+)$/\1/') || error "Cannot extract partition number from $part"
        read -r start end < <(
            parted -sm "$disk" unit MiB print |
		awk -v p="$partnum" -F: '$1==p {gsub(/MiB/,"",$2); gsub(/MiB/,"",$3); print $2,$3}')
        [[ -z $start || -z $end ]] && error "Could not locate slice range (MiB)"

        ui_yesno "Delete $part and create boot+swap+root inside?\n\nRange: ${start}-${end} MiB" ||
            error "Cancelled"
	# ---- backup table (for rollback) --------------------------
        sfdisk -d "$disk" > /tmp/part_backup.txt

        log "Deleting partition $partnum on $disk"
        parted -s "$disk" rm "$partnum" || {
            sfdisk "$disk" < /tmp/part_backup.txt
            error "Failed to delete slice – table restored"
        }
	
        local boot_s=$start
        local boot_e=$(( boot_s + BOOT_MB ))
        local swap_s=$boot_e
        local swap_e=$(( swap_s + SWAP_MB ))
        (( swap_e >= end )) && error "Slice too small"

        log "Creating boot ${boot_s}-${boot_e} MiB"
        parted -s "$disk" -- mkpart primary fat32  ${boot_s}MiB ${boot_e}MiB || {
            sfdisk "$disk" < /tmp/part_backup.txt
            error "Failed creating boot slice – table restored"
        }
        boot_idx=$(parted -sm "$disk" print | tail -1 | cut -d: -f1)
        parted -s "$disk" set "$boot_idx" boot on

        log "Creating swap ${swap_s}-${swap_e} MiB"
        parted -s "$disk" -- mkpart primary linux-swap ${swap_s}MiB ${swap_e}MiB || {
            sfdisk "$disk" < /tmp/part_backup.txt
            error "Failed creating swap slice – table restored"
        }

        log "Creating root ${swap_e}-${end} MiB"
        parted -s "$disk" -- mkpart primary ext4 ${swap_e}MiB ${end}MiB || {
            sfdisk "$disk" < /tmp/part_backup.txt
            error "Failed creating root slice – table restored"
        }

        partprobe "$disk"; udevadm settle

        # Identify the three brand‑new slices (last three on the disk)
        mapfile -t new_parts < <(lsblk -prno NAME "$disk" | tail -3)
        boot_p=${new_parts[0]} ; swap_p=${new_parts[1]} ; root_p=${new_parts[2]}

	mount_and_format_partitions "$boot_p" "$swap_p" "$root_p"

        info "Replaced $part with:\n  $boot_p (boot)\n  $swap_p (swap)\n  $root_p (root)"
    }

    # Function to partition only free space
    partition_free_space() {
	local disk=$1
	# Pick the largest free gap on the disk
	read -r start end gap <<< $(
            parted -sm "$disk" unit MiB print free |
		awk -F: '
          $1  {
            gsub(/MiB/,"",$2); gsub(/MiB/,"",$3);
            g=$3-$2;
            if (g>max){max=g;s=$2;e=$3}
          }
          END{if(max>0) printf "%d %d %d",s,e,max}'
	     )
	[ -z "$gap" ] && error "No free gap found"
	# claming start
	start=$(( start < 1 ? 1 : start ))
	# Calculate sizes for partitions within free space
	total_space=$(echo "$end - $start" | bc)
	boot_size=1024  # 1GiB in MiB
	swap_size=8192  # 8GiB in MiB

	# Calculate exact positions
	boot_end=$(echo "$start + $boot_size" | bc)
	swap_end=$(echo "$boot_end + $swap_size" | bc)

	# Validate - make sure our calculations don't exceed the device
	if (( $(echo "$swap_end + 1024 >= $end" | bc -l) ));
	then
	    error "Not enough free space for requested partition sizes (need at least $((boot_size + swap_size))MiB, but only ${total_space}MiB available)"
	fi

	log "Creating partitions in free space from ${start}MiB to ${end}MiB"
	info "Creating partitions in free space from ${start}MiB to ${end}MiB"

	# Backup the current partition table
	log "Creating backup of partition table"
	sfdisk -d "$disk" > /tmp/part_backup.txt

	# Get partition count BEFORE creating new partitions
	local current_partitions=($(ls ${disk}[0-9]* 2>/dev/null || echo ""))
	log "Current partitions: ${current_partitions[*]}"

	# Create all partitions in one atomic operation - if this fails, no partitions will be created
	if ! parted -s --align optimal "$disk" -- \
	     mkpart primary fat32 ${start}MiB ${boot_end}MiB \
	     mkpart primary linux-swap ${boot_end}MiB ${swap_end}MiB \
	     mkpart primary ext4 ${swap_end}MiB 100%
	then

	    log "Error creating partitions - restoring backup"
	    sfdisk "$disk" < /tmp/part_backup.txt
	    partprobe "$disk"
	    error "Failed to create partitions. Original partition table restored."
	fi
	sleep 3

	# Get NEW partition list after creation
	local new_partitions=($(ls ${disk}[0-9]* 2>/dev/null))
	log "New partitions: ${new_partitions[*]}"

	# Find the new partitions (those not in current_partitions)
	local boot_part=""
	local swap_part=""
	local root_part=""

	# Find the newly created partitions
	for part in "${new_partitions[@]}"; do
	    if ! [[ " ${current_partitions[*]} " =~ " ${part} " ]]; then
		if [[ -z "$boot_part" ]]; then
		    boot_part="$part"
		elif [[ -z "$swap_part" ]]; then
		    swap_part="$part"
		elif [[ -z "$root_part" ]]; then
		    root_part="$part"
		fi
	    fi
	done

	log "Identified new partitions - Boot: $boot_part, Swap: $swap_part, Root: $root_part"

	# Verify partitions exist before formatting
	if [[ ! -b "$boot_part" ]]; then
	    error "Boot partition $boot_part not found. Partitioning may have failed."
	fi

	if [[ ! -b "$swap_part" ]]; then
	    error "Swap partition $swap_part not found. Partitioning may have failed."
	fi

	if [[ ! -b "$root_part" ]]; then
	    error "Root partition $root_part not found. Partitioning may have failed."
	fi

	mount_and_format_partitions "$boot_part" "$swap_part" "$root_part"

	info "Created and formatted new partitions:\n$boot_part (boot)\n$swap_part (swap)\n$root_part (root)"
    }

    # Function to wipe filesystem on a partition
    wipe_fs() {
	local target=$1
	log "Wiping filesystem on $target"
	if wipefs -a "$target"; then
	    info "Filesystem wiped on $target"
	else
	    error "Failed to wipe $target"
	fi
    }

    # ---------------- Main script logic ------------------------------
    main() {
        local target
        target=$(select_target) || error "Selection cancelled"
        target=${target//\"/}
	log "Selected target: $target"
	FS_TYPE=$(select_root_fs) || error "Filesystem selection cancelled"
	log "Selected root filesystem: $FS_TYPE"
        # ========  PARTITION CHOSEN  =================================
        if [[ $target =~ [0-9]$ ]]; then
	    log "Partition selected: $target"
	    if [[ -n $(lsblk -no FSTYPE "$target") ]]; then
		if ui_yesno "WARNING: Existing filesystem on $target! Wipe it and carve slices?"; then
		    wipe_fs "$target"
		    replace_partition_with_slices "$target"
		else
		    error "Cancelled"
		fi
	    else
		if ui_yesno "This will carve new slices into $target and erase all contents. Proceed?"; then
		    replace_partition_with_slices "$target"
		else
		    error "Cancelled"
		fi
	    fi
	fi
        # ========  DISK CHOSEN  ======================================
        log "Disk selected: $target"

        if ! parted -s "$target" print >/dev/null 2>&1; then
            log "No partition table on $target"
            create_gpt_layout "$target"
            info "Partitioning completed successfully!"
            return
        fi

        # ----- disk has a table; check for usable free space ----------
	read -r free_start free_end free_size <<< $(
	    parted -sm "$target" unit MiB print free |
		awk -F: '
	  /free/ {
	    gsub(/MiB/,"",$2); gsub(/MiB/,"",$3);
	    gap = $3 - $2;
	    if (gap > max) { max = gap; s = $2; e = $3 }
	  }
	  END { if (max > 0) printf "%d %d %d", s, e, max }'
	     )
        free_size=${free_size:-0}
        if (( free_size > BOOT_MB + SWAP_MB + 2 )); then
            log "Found ${free_size}MiB free space"
            if ui_yesno "Found ${free_size}MiB free space on $target.\nUse this gap instead of repartitioning the disk?"; then
                partition_free_space "$target"
                info "Partitioning completed successfully!"
                return
            fi
	fi

	# ----- no useful gap – offer existing partition path ----------
	log "No sizeable free space on $target"

	part_list=$(lsblk -lnpo NAME,SIZE,TYPE "$target" | grep part)
	[[ -z $part_list ]] && error "Disk has no partitions and no free space?"

	if ui_yesno "Disk is full. Pick an existing partition to reuse?"; then
	    local part_options=()
	    while IFS= read -r line; do
		name=$(awk '{print $1}' <<< "$line")
		size=$(awk '{print $2}' <<< "$line")
		part_options+=("$name" "$size")
	    done <<< "$part_list"

	    picked=$(ui_menu "Select Partition" "Choose a partition to replace:" "${part_options[@]}") || error "Cancelled"

	    #check FSTYPE of picked partition, not target disk
	    if [[ -n $(lsblk -no FSTYPE "$picked") ]]; then
		ui_yesno "WARNING: Existing filesystem on $picked! Delete it?" || error "Cancelled"
	    fi

	    replace_partition_with_slices "$picked"
	else
	    ui_yesno "WARNING: This will DELETE **ALL** partitions on $target.\nContinue?" || error "Cancelled"
	    create_gpt_layout "$target"
	fi

	info "Partitioning completed successfully!"
    }

    # -----------------------------------------------------------------
    main
}
