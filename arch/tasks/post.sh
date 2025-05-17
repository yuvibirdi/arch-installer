#!/usr/bin/env bash
set -eo pipefail

run() {
    # Imports
    source "$REPO_DIR/lib/ui.sh"
    source "$REPO_DIR/lib/logging.sh"

    # Helper functions
    error() { log_error "$1"; exit 1; }
    info()  { log_warn "$1"; }
    log()   { log_info "$1"; }

    USERNAME=$(whoami)
    HOME_DIR="/home/$USERNAME"

    log "Ensuring ~/git exists"
    mkdir -p "$HOME_DIR/git"

    log "Cloning dotfiles repo"
    git clone --recursive https://github.com/yuvibirdi/dotfiles-backup.git "$HOME_DIR/git/dotfiles-backup" || error "Failed to clone dotfiles"

    log "Copying dotfiles to home"
    cp -rfT "$HOME_DIR/git/dotfiles-backup/arch/..files" "$HOME_DIR"
    cp -rfT "$HOME_DIR/git/dotfiles-backup/arch/.config" "$HOME_DIR/.config"

    log "Cloning and building DWM and dwmblocks from GitLab"
    git clone --depth=1 https://gitlab.com/yuvibirdi/dwm_config.git "$HOME_DIR/git/dwm_config" || error "Failed to clone dwm_config"

    log "Building dwm"
    sudo make -C "$HOME_DIR/git/dwm_config" || error "Failed to build dwm"
    sudo make -C "$HOME_DIR/git/dwm_config" install || error "Failed to install dwm"

    log "Building dwmblocks"
    sudo make -C "$HOME_DIR/git/dwm_config/dwmblocks" || error "Failed to build dwmblocks"
    sudo make -C "$HOME_DIR/git/dwm_config/dwmblocks" install || error "Failed to install dwmblocks"

    log "Installing SDDM and required packages"
    sudo pacman -S --noconfirm sddm xorg xorg-xinit libx11 libxft libxinerama make gcc git

    log "Installing sddm-chinese-painting-theme from AUR using paru"
    paru -S --noconfirm sddm-chinese-painting-theme || error "Failed to install SDDM theme"


    log "Setting SDDM theme to chinese-painting"
    sudo mkdir -p /etc/sddm.conf.d
    sudo tee /etc/sddm.conf.d/theme.conf > /dev/null <<EOF
[Theme]
Current=chinese-painting
EOF

    log "Creating dwm.desktop file for SDDM"
    sudo mkdir -p /usr/share/xsessions
    sudo tee /usr/share/xsessions/dwm.desktop > /dev/null <<EOF
[Desktop Entry]
Encoding=UTF-8
Name=dwm
Comment=Dynamic Window Manager
Exec=dwm
Icon=dwm
Type=XSession
EOF

    log "Enabling SDDM service"
    sudo systemctl enable sddm

    log_success "Post-installation complete: dotfiles, dwm, dwmblocks, SDDM, and theme configured."
}
