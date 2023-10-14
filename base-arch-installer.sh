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
|               This is Yuvraj's Arch Linux Install Script that he got of the Internet to Modify          |
|---------------------------------------------------------------------------------------------------------|
|                               Base Installation Of Arch Linux Begins Now                                |
|_________________________________________________________________________________________________________|

"
# Function Definitions
drive_selection() {
    lsblk
    echo "Enter the drive or partition to install Arch Linux on it. (e.g., /dev/sda, /dev/sda1, /dev/nvme0n1, or something similar)"
    read -p "Drive/Partition: " DRIVE

    # Check if the DRIVE variable is empty
    if [ -z "$DRIVE" ]; then
        echo "ERROR: Drive/partition not selected. Please run the script again and select a drive/partition."
        exit 1
    fi

    # Check if the DRIVE variable points to a valid block device (drive or partition)
    if lsblk "$DRIVE" >/dev/null 2>&1; then
        if [ -b "$DRIVE" ]; then
            # It's a block device, so it's either a drive or a partition
            if [[ "$DRIVE" =~ [0-9]$ ]]; then
                IS_PARTITION=1
                echo "Selected partition: $DRIVE"
            else
                IS_PARTITION=0
                echo "Selected drive: $DRIVE"
            fi
        else
            echo "ERROR: The selected drive/partition '$DRIVE' is not a valid block device or does not exist."
            exit 1
        fi
    else
        echo "ERROR: The selected drive/partition '$DRIVE' is not a valid block device or does not exist."
        exit 1
    fi
    DRIVE=$(echo "$DRIVE" | sed 's/[^A-Za-z]*$//')
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
        echo "the boot partition will be 1G to support multiple kernels if needed"
        echo "the swap will be 8G "
        echo "Rest of the space will be allocated to the mainfs "

        if [ "$IS_PARTITION" -eq 1 ]; then
                echo "PARTITION DETECTED!"
                sleep 2s
                #CONSTANTS
                BOOT_SIZE_GB=1
                SWAP_SIZE_GB=8

                END_OF_LAST_PARTITION=$(sudo parted "$DRIVE" print | awk '/[[:digit:]]/' | tail -n 1 | awk '($1 ~ /^[0-9]+$/) {print $3}')
                LAST_PARTITION_NO=$(sudo parted "$DRIVE" print | awk '/[[:digit:]]/' | tail -n 1 | awk '($1 ~ /^[0-9]+$/) {print $1}')
                END_PART_UNIT=$(echo "$END_OF_LAST_PARTITION" | sed 's/[^A-Za-z]//g')
                END_PART_NUMERIC=$(echo "$END_OF_LAST_PARTITION" | sed 's/[^0-9.]//g')
                if [ "$END_PART_UNIT" == "GB" ]; then
                        END_PART_NUMERIC=$(echo "$END_PART_NUMERIC * 1074" | bc)
                        END_PART_UNIT="MB"
                fi
                BOOT_END=$(echo "$END_PART_NUMERIC + ($BOOT_SIZE_GB * 1074) + 1" | bc)
                SWAP_END=$(echo "$BOOT_END + ($SWAP_SIZE_GB * 1074) + 1" | bc)
                if [ "$FSYS" = "btrfs" ]; then
                        echo "Partitioning the Drive"
                        parted -s "$DRIVE" mkpart primary fat32 "$END_PART_NUMERIC" "$BOOT_END" name $((LAST_PARTITION_NO +1)) boot
                        parted -s "$DRIVE" mkpart primary linux-swap "$BOOT_END" "$SWAP_END" name $((LAST_PARTITION_NO +2)) swap
                        parted -s "$DRIVE" mkpart primary btrfs "$SWAP_END" 100% name $((LAST_PARTITION_NO +3)) rootfs
                fi
        else
                echo "COMPLETE DRIVE DETECTED!"
                sleep 2s
                if [ "$FSYS" = "btrfs" ]; then
                        echo "Partitioning the Drive"
                        parted -s "$DRIVE" mklabel gpt
                        parted -s "$DRIVE" mkpart primary fat32 1MiB 1GiB name 1 boot
                        parted -s "$DRIVE" mkpart primary linux-swap 1GiB 9GiB name 2 swap
                        parted -s "$DRIVE" mkpart primary btrfs 9GiB 100% name 3 rootfs
                fi

        fi
        # Continuting with the Formatting
        echo "Formatting the Drive"
        lsblk
        mkfs.fat -F32 /dev/disk/by-partlabel/boot
        mkswap /dev/disk/by-partlabel/swap
        mkfs.btrfs /dev/disk/by-partlabel/rootfs

        echo "Creating Btrfs Subvolumes"
        mount /dev/disk/by-partlabel/rootfs /mnt
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home
        btrfs subvolume create /mnt/@var
        btrfs subvolume create /mnt/@snapshots


        echo "Creating mount points and mounting subvolumes"
        umount /dev/disk/by-partlabel/rootfs /mnt
        mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@ /dev/disk/by-partlabel/rootfs /mnt
        mkdir -p /mnt/{boot/efi,home,var,.snapshots}
        mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@home /dev/disk/by-partlabel/rootfs /mnt/home
        mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@var /dev/disk/by-partlabel/rootfs /mnt/var
        mount -o noatime,compress=zstd,ssd,discard=async,space_cache=v2,subvol=@snapshots /dev/disk/by-partlabel/rootfs /mnt/.snapshots
        mount /dev/disk/by-partlabel/boot /mnt/boot/efi
        swapon /dev/disk/by-partlabel/swap

}

echo "Internet Connection is a must to begin."
echo "Updating Keyrings"
pacman -Sy --needed --noconfirm archlinux-keyring
echo "Ensuring if the system clock is accurate."
timedatectl set-ntp true
drive_selection
fs_selection
fs_confirm

sleep 10s
lsblk
#Replace kernel and kernel-header file and with your requirements (eg linux-zen linux-zen-headers or linux linux-headers)
#Include intel-ucode/amd-ucode if you use intel/amd processor.
echo "Installing The Base system!"
sleep 2s
pacstrap /mnt base base-devel iptables-nft linux linux-headers intel-ucode 
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 15/' /etc/pacman.conf
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
echo "generating locale"
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
sleep 2s
echo "setting LANG variable"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
sleep 2s
echo "setting console keyboard layout"
echo "KEYMAP=us" > /etc/vconsole.conf
sleep 2s
echo "Set up your hostname!"
echo "Enter your computer name: "
read -p "" HOSTNAME
echo $HOSTNAME > /etc/hostname
echo "Checking hostname (/etc/hostname)"
cat /etc/hostname
sleep 3s
echo "setting up hosts file"
echo "127.0.0.1       localhost" >> /etc/hosts
echo "::1             localhost" >> /etc/hosts
echo "127.0.1.1       $HOSTNAME" >> /etc/hosts
echo "checking /etc/hosts file"
cat /etc/hosts
sleep 3s
#if you are dualbooting, add os-prober with grub and efibootmgr
echo "Installing some needed packages"
sleep 2s
pacman -Syyu --noconfirm grub btrfs-progs grub-btrfs efibootmgr networkmanager dialog wpa_supplicant mtools dosfstools xdg-user-dirs xdg-utils xdg-desktop-portal-gtk pipewire-pulse  gvfs gvfs-smb nfs-utils inetutils dnsutils bluez bluez-utils cups hplip alsa-utils pipewire pipewire-alsa pipewire-pulse pipewire-jack bash-completion openssh rsync reflector acpi acpi_call tlp virt-manager qemu-desktop qemu edk2-ovmf bridge-utils dnsmasq vde2 iptables-nft ipset firewalld flatpak sof-firmware nss-mdns acpid os-prober ntfs-3g git
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

echo "Enabling NetworkManager"
systemctl enable NetworkManager
sleep 2s
echo "Enter password for root user:"
passwd
echo "Adding regular user!"
read -p "Enter username to add a regular user: " USERNAME
useradd -m -g users -G wheel,audio,video -s /bin/bash $USERNAME
echo "Enter password for $USERNAME:"
passwd $USERNAME
echo "NOTE: ALWAYS REMEMBER THIS USERNAME AND PASSWORD YOU PUT JUST NOW."

# Adding sudo privileges to the user you created
echo "Giving sudo access to $USERNAME!"
echo "$USERNAME ALL=(ALL) ALL" >> /etc/sudoers.d/$USERNAME

# Install aur helper (paru) as the newly created user
echo "Installing aur helper (paru) for $USERNAME"
sudo -u $USERNAME bash -c 'cd ~/ && mkdir -p ~/git && cd ~/git && git clone https://aur.archlinux.org/paru-bin.git && cd paru-bin && makepkg -si'

# Install other packages as the newly created 
paru -S --noconfirm alacritty btop brave code discord dunst emacs fish ttf-jetbrains-mono-nerd lf light mpv neofetch notion-app-enhanced  ookla-speedtest-bin qbittorrent ranger rofi spotify spicetify-cli thunar vlc python-pywal zathura arc-gtk-theme pairus-dark-icons lx-appearance
rm /post_base-install.sh
