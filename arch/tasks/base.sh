#!/usr/bin/env bash
set -eo pipefail

    source "$REPO_DIR/lib/ui.sh"        # ui_menu, ui_yesno, ui_input …
    source "$REPO_DIR/lib/logging.sh"   # log_info, log_error, log_success …

# Prompt user for config details
HOSTNAME=$(ui_input "Enter hostname") || error "Hostname prompt cancelled"
USERNAME=$(ui_input "Enter username for new user") || error "Username prompt cancelled"
ROOTPW=$(ui_input "Enter root password") || error "Root password prompt cancelled"
USERPW=$(ui_input "Enter password for $USERNAME") || error "User password prompt cancelled"

log_info "Copying project into new system at /mnt/root/installer"
mkdir -p /mnt/root
cp -r "$(dirname "$0")/../../" /mnt/root/installer

log_info "Optimizing pacman configuration"
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 15/' /etc/pacman.conf

log_info "Installing base system (pacstrap)"
pacstrap /mnt base base-devel iptables-nft linux linux-headers intel-ucode linux-firmware

log_info "Generating fstab"
genfstab -U /mnt >> /mnt/etc/fstab

log_info "Cleaning subvolid entries from fstab"
sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab

log_success "Entering arch-chroot to run post-base configuration"
arch-chroot /mnt bash -s <<EOF
set -eo pipefail

ln -sf /usr/share/zoneinfo/Canada/Eastern /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen

echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
echo "127.0.0.1   localhost" >> /etc/hosts
echo "::1         localhost" >> /etc/hosts
echo "127.0.1.1   $HOSTNAME.localdomain $HOSTNAME" >> /etc/hosts

pacman -Syu --noconfirm grub btrfs-progs efibootmgr networkmanager dosfstools mtools vim sudo

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager

echo -e "$ROOTPW\n$ROOTPW" | passwd root

useradd -m -G wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/$USERNAME
echo -e "$USERPW\n$USERPW" | passwd $USERNAME
EOF

log_success "Base and post-base configuration complete. You may now reboot manually."
