#!/usr/bin/env bash
set -eo pipefail

# Base installation script: partitions should already be formatted and mounted at /mnt
# Usage: Run this on the host after partitioning:
#   sudo bash arch/tasks/base.sh
# Source logging utilities
    source "$REPO_DIR/lib/ui.sh"        # ui_menu, ui_yesno, ui_input …

# Step 1: Copy entire project into new system for post-install use
log_info "Copying project into new system at /mnt/root/installer"
mkdir -p /mnt/root
cp -r "$(dirname "$0")/../../" /mnt/root/installer

# Step 2: Optimize pacman parallel downloads
log_info "Optimizing pacman configuration"
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 15/' /etc/pacman.conf

# Step 3: Install core packages via pacstrap
log_info "Installing base system (pacstrap)"
pacstrap /mnt base base-devel iptables-nft linux linux-headers intel-ucode linux-firmware linux-firmware

# Step 4: Generate fstab
log_info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

# Step 5: Remove subvolid entries (if using Btrfs)
log_info "Cleaning subvolid entries from fstab"
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab

# Step 6: Chroot into the new system and perform post-base configuration
log_info "Entering chroot for post-base configuration"
arch-chroot /mnt bash << 'EOF'
# Set timezone and synchronize hardware clock
ln -sf /usr/share/zoneinfo/Canada/Eastern /etc/localtime
hwclock --systohc

# Generate locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf

echo "KEYMAP=us" > /etc/vconsole.conf

# Set hostname
read -p "Enter hostname: " HOSTNAME
echo "$HOSTNAME" > /etc/hostname

# Configure hosts file
echo "127.0.0.1   localhost" >> /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   $HOSTNAME" >> /etc/hosts

# Install additional packages and bootloader
pacman -Syu --noconfirm grub btrfs-progs efibootmgr networkmanager dosfstools mtools vim sudo

# Install GRUB for EFI
echo "Installing GRUB..."
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH

grub-mkconfig -o /boot/grub/grub.cfg

# Enable services
echo "Enabling NetworkManager..."
systemctl enable NetworkManager

# Create user and set passwords
read -p "Enter root password: " -s ROOTPW && echo -e "\n" && passwd root <<PW
$ROOTPW
$ROOTPW
PW

read -p "Enter a username to create: " USERNAME
useradd -m -G wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/$USERNAME
read -p "Enter password for $USERNAME: " -s USERPW && echo -e "\n" && passwd $USERNAME <<PW2
$USERPW
$USERPW
PW2

EOF

log_success "Base and post-base configuration complete. You may now reboot manually."
