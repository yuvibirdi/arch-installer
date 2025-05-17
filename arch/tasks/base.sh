#!/usr/bin/env bash
set -eo pipefail

source "$REPO_DIR/lib/ui.sh"        # ui_menu, ui_yesno, ui_input …
source "$REPO_DIR/lib/logging.sh"   # log_info, log_error, log_success …

# Helper functions
error() {
	log_error "$1"
	exit 1
}
info()  { log_warn "$1"; }
log()   { log_info "$1"; }          

# Prompt user for config details
HOSTNAME=$(ui_input "Enter hostname") || error "Hostname prompt cancelled"
USERNAME=$(ui_input "Enter username for new user") || error "Username prompt cancelled"

# Determine CPU microcode package
device_vendor=$(lscpu | grep -i vendor | awk '{print $3}')
if [[ "$device_vendor" == "GenuineIntel" ]]; then
    UCODE="intel-ucode"
elif [[ "$device_vendor" == "AuthenticAMD" ]]; then
    UCODE="amd-ucode"
else
    error "Unsupported CPU vendor: $device_vendor"
fi
log_info "Detected CPU vendor: $device_vendor, using microcode: $UCODE"

# Secure password prompt with confirmation
echo "Enter root password:" >&2
while true; do
    ROOTPW=$(whiptail --passwordbox "Enter root password" 10 60 3>&1 1>&2 2>&3) || error "Root password cancelled"
    ROOTPW2=$(whiptail --passwordbox "Confirm root password" 10 60 3>&1 1>&2 2>&3) || error "Root password confirmation cancelled"
    [[ "$ROOTPW" == "$ROOTPW2" ]] && break || whiptail --msgbox "Passwords do not match. Try again." 8 40
done

echo "Enter password for $USERNAME:" >&2
while true; do
    USERPW=$(whiptail --passwordbox "Enter password for $USERNAME" 10 60 3>&1 1>&2 2>&3) || error "User password cancelled"
    USERPW2=$(whiptail --passwordbox "Confirm password for $USERNAME" 10 60 3>&1 1>&2 2>&3) || error "User password confirmation cancelled"
    [[ "$USERPW" == "$USERPW2" ]] && break || whiptail --msgbox "Passwords do not match. Try again." 8 40
done

log_info "Copying project into new system at /mnt/root/installer"
mkdir -p /mnt/root
cp -r "$(dirname "$0")/../../" /mnt/root/installer

log_info "Optimizing pacman configuration"
sed -i 's/^#ParallelDownloads = 5$/ParallelDownloads = 15/' /etc/pacman.conf

log_info "Installing base system (pacstrap)"
pacstrap /mnt base base-devel iptables-nft linux linux-headers $UCODE linux-firmware

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

pacman -Syu --noconfirm grub grub-btrfs btrfs-progs efibootmgr networkmanager dosfstools mtools neovim sudo emacs os-prober ntfs-3g

# Enable os-prober for GRUB
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager

echo "$ROOTPW" | passwd --stdin root 2>/dev/null || echo -e "$ROOTPW\n$ROOTPW" | passwd root

useradd -m -G wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/$USERNAME
echo "$USERPW" | passwd --stdin $USERNAME 2>/dev/null || echo -e "$USERPW\n$USERPW" | passwd $USERNAME
EOF

log_success "Base and post-base configuration complete. You may now reboot manually."
