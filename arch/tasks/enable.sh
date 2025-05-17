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



    # enable stuff with systemctl and other configs that need to be made
    # sudo systemctl enable 
}
