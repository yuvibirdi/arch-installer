#!/usr/bin/env bash
set -eo pipefail
run(){
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

    # Detect microcode package
    vendor=$(LC_ALL=C lscpu | awk -F: '/Vendor ID:/ {gsub(/^[ \t]+/, "", $2); print $2}')
    hypervisor=$(LC_ALL=C lscpu | awk -F: '/Hypervisor vendor:/ {gsub(/^[ \t]+/, "", $2); print $2}')

    if [[ -n "$hypervisor" ]]; then
        log_warn "Virtualized system detected under $hypervisor. Skipping microcode install."
        UCODE=""
    else
        case "$vendor" in
            GenuineIntel)  UCODE="intel-ucode" ;;
            AuthenticAMD)  UCODE="amd-ucode" ;;
            *) error "Unsupported or unknown CPU vendor: $vendor" ;;
        esac
        log_info "Detected CPU vendor: $vendor → using $UCODE"
    fi

    #FS_TYPE
    FS_TYPE=$(findmnt -n -o FSTYPE /mnt) || error "Could not detect root filesystem on /mnt"
    log_info "Detected root filesystem: $FS_TYPE"


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

    EXTRA_PKGS=()
    [[ "$FS_TYPE" == "btrfs" ]] && EXTRA_PKGS+=(grub-btrfs btrfs-progs)
    EXTRA_PKGS_STRING="${EXTRA_PKGS[*]}"

    arch-chroot /mnt bash -s <<EOF
set -eo pipefail
EXTRA_PKGS=($EXTRA_PKGS_STRING)

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

PKG_LIST=(grub efibootmgr networkmanager dosfstools mtools neovim sudo emacs git fish os-prober ntfs-3g "\${EXTRA_PKGS[@]}")

# Remove any empty strings (just in case)
FILTERED_PKGS=()
for pkg in "\${PKG_LIST[@]}"; do
  [[ -n "\$pkg" ]] && FILTERED_PKGS+=("\$pkg")
done

pacman -Syu --noconfirm --needed "\${FILTERED_PKGS[@]}"

# Enable os-prober for GRUB
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub || echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ARCH
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager

echo "$ROOTPW" | passwd --stdin root 2>/dev/null || echo -e "$ROOTPW\n$ROOTPW" | passwd root

useradd -m -G wheel,audio,video -s /bin/bash $USERNAME
echo "$USERNAME ALL=(ALL) ALL" > /etc/sudoers.d/$USERNAME
echo "$USERPW" | passwd --stdin $USERNAME 2>/dev/null || echo -e "$USERPW\n$USERPW" | passwd $USERNAME
chsh $USERNAME -s /bin/fish
EOF
    log_info "Copying project into new system at /mnt/home/$USERNAME/git/dev/"
    mkdir -p /mnt/home/$USERNAME/git/
    cp -r "$(dirname "$0")/../" /mnt/home/$USERNAME/git/dev/
    chown -R $USERNAME:$USERNAME /home/$USERNAME/git


    log_success "Base and post-base configuration complete. You may now reboot manually."
}
