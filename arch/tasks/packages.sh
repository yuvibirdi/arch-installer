#!/usr/bin/env bash
set -eo pipefail
run(){
# Imports
source "$REPO_DIR/lib/ui.sh"       
source "$REPO_DIR/lib/logging.sh"  

# Helper functions
error() {
	log_error "$1"
	exit 1
}
info()  { log_warn "$1"; }
log()   { log_info "$1"; }
#

pacman -Syyu --noconfirm --needed dialog xdg-user-dirs xdg-utils xdg-desktop-portal-gtk pipewire-pulse gvfs gvfs-smb nfs-utils inetutils dnsutils bluez bluez-utils cups alsa-utils pipewire pipewire-alsa pipewire-pulse bash-completion openssh rsync reflector acpi acpi_call tlp virt-manager qemu-desktop qemu edk2-ovmf bridge-utils dnsmasq vde2 iptables-nft ipset firewalld sof-firmware nss-mdns acpid os-prober ntfs-3gogit


paru -Syyu --noconfirm --needed alacritty btop brave code discord dunst emacs fish ttf-jetbrains-mono-nerd lf light mpv neofetch notion-app-enhanced ookla-speedtest-bin qbittorrent ranger rofi spotify spicetify-cli thunar vlc python-pywal zathura 
}
