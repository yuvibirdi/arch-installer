#!/usr/bin/env bash
set -eo pipefail

#!/usr/bin/env bash
# tasks/partition.sh  –  your original script, fitted to the task framework
# ---------------------------------------------------------------------
run() {
    source "$REPO_DIR/lib/ui.sh"        # ui_menu, ui_yesno, ui_input …
    source "$REPO_DIR/lib/logging.sh"   # log_info, log_error, log_success …

    # ------------------------------------------------------------------
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

    # Function to partition only free space
    partition_free_space() {
	local disk=$1
	# Get free space boundaries in MiB
	free_space_info=$(parted -s "$disk" unit MiB print free | grep "Free Space" | tail -1)
	start=$(echo "$free_space_info" | awk '{print $1}' | sed 's/MiB//')
	end=$(echo "$free_space_info" | awk '{print $2}' | sed 's/MiB//')

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

    # Main script logic
    main() {
	local target
	target=$(select_target) || error "Selection cancelled"

	# Remove quotes from whiptail output
	target=${target//\"/}
	log "Selected target: $target"

	# Check if target is a disk or partition
	if [[ $target =~ [0-9]$ ]]; then
	    # Partition selected
	    log "Partition selected: $target"
	    if lsblk -fn "$target" | grep -q 'ext4\|xfs\|btrfs'; then
		log "Existing filesystem found on $target"
		whiptail --yesno "WARNING: Existing filesystem found on $target! Wipe it?" 10 60 || error "Cancelled"
		wipe_fs "$target"
	    fi
	    # Repartition parent disk
	    parent_disk=$(lsblk -no PKNAME "$target")
	    if [[ -z $parent_disk ]]; then
		error "Cannot determine parent disk of $target"
	    fi
	    parent_disk="/dev/$parent_disk"
	    log "Parent disk: $parent_disk"

	    if whiptail --yesno "WARNING: This will delete ALL existing partitions on $parent_disk. Continue?" 10 60; then
		create_gpt_layout "$parent_disk"
	    else
		error "Operation cancelled"
	    fi
	else
	    # Disk selected
	    log "Disk selected: $target"
	    parted_output=$(parted -s "$target" print 2>/dev/null || echo "No partition table")
	    if echo "$parted_output" | grep -q 'Partition Table'; then
		# Check for free space
		free_space=$(parted -s "$target" unit MiB print free | grep 'Free Space' | tail -1)
		if [[ -n "$free_space" ]]; then
		    free_size=$(echo "$free_space" | awk '{print $3}' | sed 's/MiB//')
		    log "Found ${free_size}MiB free space on $target"
		    if whiptail --yesno "Found ${free_size}MiB free space on $target. Use this free space instead of repartitioning the entire disk?" 10 70; then
			partition_free_space "$target"
		    else
			if whiptail --yesno "WARNING: This will delete ALL existing partitions on $target. Continue?" 10 60; then
			    create_gpt_layout "$target"
			else
			    error "Operation cancelled"
			fi
		    fi
		else
		    # No free space, treat as partition selection
		    log "No free space found on $target"
		    partitions=$(lsblk -lnpo NAME,SIZE,TYPE "$target" | grep part)
		    if [[ -z "$partitions" ]]; then
			error "No partitions found on $target and no free space available"
		    fi

		    if whiptail --yesno "No free space found on $target. Do you want to select an existing partition?" 10 60; then
			local part_options=()
			while IFS= read -r line; do
			    name=$(echo "$line" | awk '{print $1}')
			    size=$(echo "$line" | awk '{print $2}')
			    part_options+=("$name" "$size" off)
			done <<< "$partitions"
			selected_part=$(whiptail --title "Select Partition" --radiolist "Select a partition to use:" 20 70 15 "${part_options[@]}" 3>&1 1>&2 2>&3) || error "Partition selection cancelled"
			selected_part=${selected_part//\"/}
			log "Selected partition: $selected_part"

			if lsblk -fn "$selected_part" | grep -q 'ext4\|xfs\|btrfs'; then
			    whiptail --yesno "WARNING: Existing filesystem found on $selected_part! Wipe it?" 10 60 || error "Cancelled"
			    wipe_fs "$selected_part"
			fi
			mkfs.ext4 -F "$selected_part"
			info "Partition $selected_part formatted with ext4 filesystem"
		    else
			if whiptail --yesno "WARNING: This will delete ALL existing partitions on $target. Continue?" 10 60; then
			    create_gpt_layout "$target"
			else
			    error "Operation cancelled"
			fi
		    fi
		fi
	    else
		# No partition table, create new
		log "No partition table found on $target"
		create_gpt_layout "$target"
	    fi
	fi
	info "Partitioning completed successfully!"
    }
    # Start script execution
    main
}
