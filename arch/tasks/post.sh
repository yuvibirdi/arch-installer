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

    log "Installing SDDM display manager and dependencies"
    sudo pacman -S --noconfirm sddm xorg xorg-xinit libx11 libxft libxinerama make gcc git

    log "Cloning and building DWM and dwmblocks from GitLab"
    git clone --depth=1 https://gitlab.com/yuvibirdi/dwm_config.git /yb/git/dwm_config || error "Failed to clone dwm_config"

    log "Building dwm"
    sudo make -C /yb/git/dwm_config || error "Failed to build dwm"
    sudo make -C /yb/git/dwm_config install || error "Failed to install dwm"

    log "Building dwmblocks"
    sudo make -C /yb/git/dwm_config/dwmblocks/ || error "Failed to build dwmblocks"
    sudo make -C /yb/git/dwm_config/dwmblocks/ install || error "Failed to install dwmblocks"

    log "Installing sddm-chinese-painting-theme from AUR using paru"
    paru -S --noconfirm sddm-chinese-painting-theme || error "Failed to install SDDM theme"

    log "Enabling SDDM service"
    sudo systemctl enable sddm

    log "Setting Chinese painting theme for SDDM"
    sudo mkdir -p /etc/sddm.conf.d
    sudo cat <<EOF > /etc/sddm.conf.d/theme.conf
[Theme]
Current=chinese-painting
EOF

    log "Creating dwm.desktop file for SDDM"
    sudo mkdir -p /usr/share/xsessions
    sudo cat <<EOF > /usr/share/xsessions/dwm.desktop
[Desktop Entry]
Encoding=UTF-8
Name=dwm
Comment=Dynamic Window Manager
Exec=dwm
Icon=dwm
Type=XSession
EOF

    log_success "Post-installation complete: dwm, dwmblocks, SDDM, and theme configured."
}
