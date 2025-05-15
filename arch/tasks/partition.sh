#!/usr/bin/env bash
set -eo pipefail

#!/usr/bin/env bash
# tasks/partition.sh  –  your original script, fitted to the task framework
# ---------------------------------------------------------------------
run() {
    source "$REPO_DIR/lib/ui.sh"        # ui_menu, ui_yesno, ui_input …
    source "$REPO_DIR/lib/logging.sh"   # log_info, log_error, log_success …

    # ------------------------------------------------------------------
    BOOT_MB=1024
    SWAP_MB=8192
    # Helper functions
    error() { log_error "$1"; }
    info()  { log_warn "$1"; }
    log()   { log_info "$1"; }          

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

	mkfs.fat -F32 "${disk}1"
	mkswap "${disk}2"
	mkfs.ext4 -F "${disk}3"
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

        log "Formatting $boot_p → FAT32"
        mkfs.fat -F32 "$boot_p"
        log "mkswap $swap_p"
        mkswap "$swap_p"
        log "Formatting $root_p → ext4"
        mkfs.ext4 -F "$root_p"

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

	# Format the new partitions
	log "Formatting $boot_part as FAT32 (boot)"
	mkfs.fat -F32 "$boot_part"

	log "Setting up $swap_part as swap"
	mkswap "$swap_part"

	log "Formatting $root_part as ext4 (root)"
	mkfs.ext4 -F "$root_part"

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

        # ========  PARTITION CHOSEN  =================================
        if [[ $target =~ [0-9]$ ]]; then
            log "Partition selected: $target"
            if lsblk -fn "$target" | grep -qE 'ext4|xfs|btrfs'; then
                ui_yesno "WARNING: Existing filesystem on $target!  Wipe it and carves slices?" || error "Cancelled"
                wipe_fs "$target"
	    else 
                ui_yesno "This will carve new slices into $target and erase all contents. Proceed?" || error "Cancelled"
            fi
            replace_partition_with_slices "$target"
            info "Partitioning completed successfully!"
            return
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
        if [[ -z $part_list ]]; then
            error "Disk has no partitions and no free space?"
        fi

        if ui_yesno "Disk is full.  Pick an existing partition to reuse?"; then
            local part_options=()
            while IFS= read -r line; do
                name=$(awk '{print $1}' <<< "$line")
                size=$(awk '{print $2}' <<< "$line")
                part_options+=("$name" "$size")
            done <<< "$part_list"

            picked=$(ui_menu "Select Partition" "Choose a partition to replace:" "${part_options[@]}") || error "Cancelled"
            if lsblk -fn "$picked" | grep -qE 'ext4|xfs|btrfs'; then
                ui_yesno "WARNING: Existing filesystem on $picked!  Delete it?" || error "Cancelled"
            fi
            replace_partition_with_slices "$picked"
        else
            # ----- user prefers whole‑disk wipe ----------------------
            ui_yesno "WARNING: This will DELETE **ALL** partitions on $target.\nContinue?" || error "Cancelled"
            create_gpt_layout "$target"
        fi

        info "Partitioning completed successfully!"
    }

    # -----------------------------------------------------------------
    main
}
