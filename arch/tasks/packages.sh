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

    # User stuff
    USERNAME=$(whoami)
    HOME_DIR=$(eval echo "~$USERNAME")

    # packages
    if [ ! -d "$HOME_DIR/git/" ]; then
        mkdir -p "$HOME_DIR/git/"
    fi

    if [ ! -d "$HOME_DIR/git/paru" ]; then
        git clone https://aur.archlinux.org/paru-bin.git "$HOME_DIR/git/paru"
        (cd "$HOME_DIR/git/paru" && makepkg -si --noconfirm)
    fi
    
    sudo pacman -Syu --noconfirm --needed dialog xdg-user-dirs xdg-utils xdg-desktop-portal-gtk pipewire-pulse gvfs gvfs-smb nfs-utils inetutils dnsutils bluez bluez-utils cups alsa-utils pipewire pipewire-alsa pipewire-pulse bash-completion openssh rsync reflector acpi acpi_call tlp virt-manager qemu-desktop qemu edk2-ovmf bridge-utils dnsmasq vde2 iptables-nft ipset firewalld sof-firmware nss-mdns acpid os-prober ntfs-3g


    paru -Syu --noconfirm --needed alacritty btop code discord dunst emacs fish ttf-jetbrains-mono-nerd lf light mpv neofetch ookla-speedtest-bin qbittorrent spotify spicetify-cli thunar vlc python-pywal zathura zathura-pdf-mupdf zathura-djvu zathura-pywal-git

    ## skipping zathura-epub-mupdf rn cause the package
}
