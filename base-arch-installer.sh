#!/bin/sh
echo -ne "
__________________________________________________________________________________________________________
|                                                                                                         |
| █████  ██████   ██████ ██   ██     ██ ███    ██ ███████ ████████  █████  ██      ██      ███████ ██████ |
|██   ██ ██   ██ ██      ██   ██     ██ ████   ██ ██         ██    ██   ██ ██      ██      ██      ██   ██|
|███████ ██████  ██      ███████     ██ ██ ██  ██ ███████    ██    ███████ ██      ██      █████   ██████ |
|██   ██ ██   ██ ██      ██   ██     ██ ██  ██ ██      ██    ██    ██   ██ ██      ██      ██      ██   ██|
|██   ██ ██   ██  ██████ ██   ██     ██ ██   ████ ███████    ██    ██   ██ ███████ ███████ ███████ ██   ██|
|                                                                                                         |
|---------------------------------------------------------------------------------------------------------|
|    		This is Yuvraj's Arch Linux Install Script that he got of the Internet to Modify          |
|---------------------------------------------------------------------------------------------------------|
|                               Base Installation Of Arch Linux Begins Now                                |
|_________________________________________________________________________________________________________|

"
# Function Definitions

drive_selection() {
	lsblk
	echo "Enter the drive to install Arch Linux on it. (/dev/...)"
	echo "Enter Drive (e.g., /dev/sda or /dev/vda or /dev/nvme0n1 or something similar)"
	read -p "Drive: " DRIVE

	# Check if the DRIVE variable is empty
	if [ -z "$DRIVE" ]; then
	echo "ERROR: Drive not selected. Please run the script again and select a drive."
	exit 1
	fi

	# Check if the DRIVE variable points to a valid block device
	if ! lsblk "$DRIVE" >/dev/null 2>&1; then
	echo "ERROR: The selected drive '$DRIVE' is not a valid block device or does not exist."
	exit 1
	fi

	# If both checks pass, the DRIVE variable is valid
	echo "Selected drive: $DRIVE"
}

fs_selection () {
	echo "choose your linux file system type for formatting drives"
	echo " 1. ext4"
	echo " 2. btrfs"
	echo " 3. xfs"
	read -p "Enter the filesystem: " FSYS  # Updated prompt

	LOOP_STATUS=1

	while [ $LOOP_STATUS -eq 1 ]
	do
	    case "$FSYS" in
		1 | ext4 | Ext4 | EXT4)
		    FSYS="ext4"
		    LOOP_STATUS=0
		    ;;
		2 | btrfs | Btrfs | BTRFS)
		    FSYS="btrfs"
		    LOOP_STATUS=0
		    ;;
		3 | xfs | Xfs | XFS)
		    FSYS="xfs"
		    LOOP_STATUS=0
		    ;;
		*)
		    echo "Unknown or unsupported filesystem. Please enter a valid option!"
		    echo ""
		    echo "choose your linux file system type for formatting drives"
		    echo " 1. ext4"
		    echo " 2. btrfs"
		    echo " 3. xfs"
		    read -p "Enter the filesystem: " FSYS  # Updated prompt
		    ;;
	    esac
	done

}
fs_confirm () {
	echo "Selected filesystem: $FSYS"
	# Get storage size in GB using lsblk and filter with sed
	STORAGE_SIZE_BYTES=$(lsblk -b -d -o SIZE "$DRIVE" | sed -n '2p')
	STORAGE_SIZE_GB=$((STORAGE_SIZE_BYTES / (1024 * 1024 * 1024)))

	echo "Storage Size of $DRIVE: $STORAGE_SIZE_GB GB"
	echo "Selected filesystem: $FSYS"
	read -p "confirm filesystem (Y/N): " CONFIRM
	LOOP_STATUS=1
	while [ $LOOP_STATUS -eq 1 ]
	do
		case $CONFIRM in
			 yes | YES | y | Y )
				echo "Partitioning Drives Now! "
				fs_setup 
				sleep 4s
				echo "Done!"
				LOOP_STATUS=0
				;;
			 no | NO | n | N )
				echo "What do you want to do ?"
				echo "1... Selected the File System Again! "
				echo "2... Exit this Installer! " 
				read -p "\n" CONFIRM_NO
				case $CONFIRM_NO in
					[1])
						fs_selection 
						;;
					[2])
						exit 1
						;;
				esac
				;;
			*)
				echo "Unknown Option Selected! "
				echo "confirm filesystem (Y/N) "
				read -p "\n" CONFIRM
				;;
		esac
	done
			
}

fs_setup () {
	echo " the boot partition will be 1G to support multiple kernels if needed"
	echo " the swap will be 8G " 
	echo "Rest of the space will be allocated to the mainfs " 

	if [ "$FSYS" = "btrfs" ]; then 
		echo "Partitioning the Drive"
		parted -s "$DRIVE" mklabel gpt
		parted -s "$DRIVE" mkpart primary fat32 1MiB 1GiB name 1 boot
		parted -s "$DRIVE" mkpart primary linux-swap 1GiB 9GiB name 2 swap
		parted -s "$DRIVE" mkpart primary btrfs 9GiB 100% name 3 rootfs

		echo "Formatting the Drive"
		lsblk
		mkfs.vfat -F32 -n BOOT /dev/disk/by-partlabel/boot
		mkswap -L SWAP /dev/disk/by-partlabel/swap
		mkfs.btrfs -L ROOT /dev/disk/by-partlabel/rootfs

		echo "Creating Btrfs Subvolumes"
		mount /dev/disk/by-partlabel/rootfs /mnt
		btrfs subvolume create /mnt/@
		btrfs subvolume create /mnt/@home
		btrfs subvolume create /mnt/@var
		btrfs subvolume create /mnt/@snapshots

		echo "Creating mount points and mounting subvolumes"
		umount /mnt
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@ /dev/disk/by-partlabel/rootfs /mnt
		mkdir -p /mnt/{boot/efi,home,var,.snapshots}
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@home /dev/disk/by-partlabel/rootfs /mnt/home
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@var /dev/disk/by-partlabel/rootfs /mnt/var
		mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@snapshots /dev/disk/by-partlabel/rootfs /mnt/.snapshots
		mount /dev/disk/by-partlabel/boot /mnt/boot/efi
		swapon /dev/disk/by-partlabel/swap
	fi
	clear
}
echo "Internet Connection is a must to begin."
echo "Updating Keyrings"
pacman -Sy --needed --noconfirm archlinux-keyring
echo "Ensuring if the system clock is accurate."
timedatectl set-ntp true
clear

drive_selection
fs_selection 
fs_confirm

sleep 2s
clear
lsblk
#Replace kernel and kernel-header file and with your requirements (eg linux-zen linux-zen-headers or linux linux-headers)
#Include intel-ucode/amd-ucode if you use intel/amd processor.
echo "Installing The Base system!"
sleep 2s
pacstrap /mnt base base-devel linux linux-headers intel-ucode
clear
echo -e "Generating fstab ..."
genfstab -U /mnt >> /mnt/etc/fstab
sleep 1s
echo "Removing subvolid entry in fstab ..."
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
sed '1,/^#part2$/d' /root/base-arch-installer.sh > /mnt/post_base-install.sh
sleep 2s
chmod +x /mnt/post_base-install.sh
echo "proceeding to post base install"
arch-chroot /mnt ./post_base-install.sh
sleep 1s
echo "done with base install"
echo "unmounting all the drives"
umount -R /mnt
sleep 2s
clear
echo -ne "
__________________________________________________________________________________________________________
|                                            THANKS FOR USING                                             |
|---------------------------------------------------------------------------------------------------------|
| █████  ██████   ██████ ██   ██     ██ ███    ██ ███████ ████████  █████  ██      ██      ███████ ██████ |
|██   ██ ██   ██ ██      ██   ██     ██ ████   ██ ██         ██    ██   ██ ██      ██      ██      ██   ██|
|███████ ██████  ██      ███████     ██ ██ ██  ██ ███████    ██    ███████ ██      ██      █████   ██████ |
|██   ██ ██   ██ ██      ██   ██     ██ ██  ██ ██      ██    ██    ██   ██ ██      ██      ██      ██   ██|
|██   ██ ██   ██  ██████ ██   ██     ██ ██   ████ ███████    ██    ██   ██ ███████ ███████ ███████ ██   ██|
|                                                                                                         |
|---------------------------------------------------------------------------------------------------------|
|                               Base Installation Of Arch Linux Is Complete                               |
|---------------------------------------------------------------------------------------------------------|
"
echo "Base Installation Finished. REBOOTING IN 10 SECONDS!!!"
exit 0
#reboot

#part2
echo "Working inside new root system!!!"
echo "setting timezone"
ln -sf /usr/share/zoneinfo/Canada/Eastern /etc/localtime
hwclock --systohc
sleep 2s
clear
echo "generating locale"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
sleep 2s
clear
echo "setting LANG variable"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
sleep 2s
clear
echo "setting console keyboard layout"
echo "KEYMAP=us" > /etc/vconsole.conf
sleep 2s
clear
echo "Set up your hostname!"
echo "Enter your computer name: "
read -p "" HOSTNAME
echo $HOSTNAME > /etc/hostname
echo "Checking hostname (/etc/hostname)"
cat /etc/hostname
sleep 3s
clear
echo "setting up hosts file"
echo "127.0.0.1       localhost" >> /etc/hosts
echo "::1             localhost" >> /etc/hosts
echo "127.0.1.1       $HOSTNAME" >> /etc/hosts
clear
echo "checking /etc/hosts file"
cat /etc/hosts
sleep 3s
clear
#if you are dualbooting, add os-prober with grub and efibootmgr
echo "Installing some needed packages"
sleep 2s
pacman -Syyu --noconfirm grub btrfs-progs grub-btrfs efibootmgr networkmanager dialog wpa_supplicant mtools dosfstools xdg-user-dirs xdg-utils xdg-desktop-portal-gtk pipewire-pulse  gvfs gvfs-smb nfs-utils inetutils dnsutils bluez bluez-utils cups hplip alsa-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack bash-completion openssh rsync reflector acpi acpi_call tlp virt-manager qemu-desktop qemu edk2-ovmf bridge-utils dnsmasq vde2 openbsd-netcat iptables-nft ipset firewalld flatpak sof-firmware nss-mdns acpid os-prober ntfs-3g git 
lsblk
sleep 2s
echo "Installing grub bootloader in /boot/efi parttiton"
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=arch --modules="tpm" --disable-shim-lock

grub-mkconfig -o /boot/grub/grub.cfg
sleep 2s

echo "Secure boot WIP not implemented yet"
#pacman -S --noconfirm sbctl
#sbctl status
#sudo sbctl create-keys
#sudo sbctl enroll-keys -m
#chattr -i /sys/firmware/efi/efivars/{PK,KEK,db}*
#sudo sbctl verify
#sudo sbctl sign -s /efi/EFI/GRUB/grubx64.efi 

clear
echo "Enabling NetworkManager"
systemctl enable NetworkManager
sleep 2s
clear
echo "Enter password for root user:"
passwd
clear
echo "Adding regular user!"
read -p "Enter username to add a regular user: " USERNAME
useradd -m -g users -G wheel,audio,video -s /bin/bash $USERNAME
echo "Enter password for $USERNAME:"
passwd $USERNAME
clear
echo "NOTE: ALWAYS REMEMBER THIS USERNAME AND PASSWORD YOU PUT JUST NOW."

# Adding sudo privileges to the user you created
echo "Giving sudo access to $USERNAME!"
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers.d/$USERNAME
clear

# Install aur helper (paru) as the newly created user
echo "Installing aur helper (paru) for $USERNAME"
sudo -u $USERNAME bash -c 'cd ~/ && mkdir -p ~/git && cd ~/git && git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -si'

# Install other packages as the newly created user
sudo -u $USERNAME paru -S --noconfirm alacritty btop brave code discord dunst emacs fish ttf-jetbrains-mono-nerd lf light mpv neofetch notion-app-enhanced  ookla-speedtest-bin qbittorrent ranger rofi spotify spicetify-cli thunar vlc python-pywal zathura arc-gtk-theme pairus-dark-icons lx-appearance
clear
rm /post_base-install.sh
