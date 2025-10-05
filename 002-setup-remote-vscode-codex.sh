#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[codex-setup]"
SESSION_NAME="vscode"
SKIP_PACKAGES=0

usage() {
    cat <<'EOF'
Usage: setup.sh [options]

Options:
  --session-name NAME  Base tmux session name to use (default: vscode)
  --skip-packages      Skip installing packages and only apply dotfile tweaks
  -h, --help           Show this help message and exit
EOF
}

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

err() {
    printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "Missing required command: $1"
        exit 1
    fi
}

detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v pacman >/dev/null 2>&1; then
        echo "pacman"
    else
        echo "unknown"
    fi
}

install_packages() {
    local manager=$1
    shift || true
    local packages=("$@")
    [ ${#packages[@]} -gt 0 ] || return 0

    local sudo_cmd=""
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        if command -v sudo >/dev/null 2>&1; then
            sudo_cmd="sudo"
        else
            err "Need root privileges to install packages. Install sudo or run this script as root."
            exit 1
        fi
    fi

    case "$manager" in
        apt)
            log "Installing packages via apt: ${packages[*]}"
            $sudo_cmd apt-get update -y
            $sudo_cmd apt-get install -y "${packages[@]}"
            ;;
        dnf)
            log "Installing packages via dnf: ${packages[*]}"
            $sudo_cmd dnf install -y "${packages[@]}"
            ;;
        yum)
            log "Installing packages via yum: ${packages[*]}"
            $sudo_cmd yum install -y "${packages[@]}"
            ;;
        pacman)
            log "Installing packages via pacman: ${packages[*]}"
            $sudo_cmd pacman -Sy --noconfirm "${packages[@]}"
            ;;
        *)
            err "Unsupported package manager. Install the following packages manually: ${packages[*]}"
            return 1
            ;;
    esac
}
sanitize_name() {
    local name=$1
    name=${name// /_}
    name=$(printf '%s' "$name" | tr -cs '[:alnum:]._-' '_')
    [ -n "$name" ] || name="vscode"
    printf '%s' "$name"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --session-name)
                shift || { err "--session-name requires a value"; exit 1; }
                SESSION_NAME=$(sanitize_name "$1")
                ;;
            --skip-packages|--no-packages)
                SKIP_PACKAGES=1
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                err "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
        shift || break
    done
}

main() {
    parse_args "$@"
    require_command printf

    local pkg_manager
    pkg_manager=$(detect_pkg_manager)
    if [ "$SKIP_PACKAGES" -eq 1 ]; then
        log "Skipping package installation per user request"
    elif [ "$pkg_manager" = "unknown" ]; then
        log "Could not detect package manager; skipping package installs. Ensure tmux, fish, curl, and git exist."
    else
        install_packages "$pkg_manager" tmux fish curl git
    fi

    log "Using tmux base session name: $SESSION_NAME"

    local bashrc="$HOME/.bashrc"
    if [ ! -f "$bashrc" ]; then
        log "Creating $bashrc"
        touch "$bashrc"
    fi

    local auto_block_marker_start="# >>> codex vscode tmux auto-attach >>>"
    local auto_block_marker_end="# <<< codex vscode tmux auto-attach <<<"
    local auto_block
    read -r -d '' auto_block <<'EOF'
# >>> codex vscode tmux auto-attach >>>
if [ -z "$TMUX" ] && [ -t 1 ] && [ "${TERM_PROGRAM:-}" = "vscode" ]; then
    if command -v tmux >/dev/null 2>&1; then
        session="__SESSION_NAME__"
        workspace="${VSCODE_CWD:-$PWD}"

        # Build a readable window slug from the workspace path.
        window_slug="${workspace##*/}"
        [ -n "$window_slug" ] || window_slug="vscode"
        window_slug=$(printf '%s' "$window_slug" | tr -cs '[:alnum:]._-' '_')

        target_window=""
        need_cd=""
        if ! tmux has-session -t "$session" 2>/dev/null; then
            tmux new-session -d -s "$session" -c "$workspace" -n "$window_slug"
            tmux set-option -w -t "$session:$window_slug" @vscode_root "$workspace" >/dev/null
            target_window="$window_slug"
            need_cd=1
        else
            existing_window=$(tmux list-windows -t "$session" -F '#{window_name}' 2>/dev/null | while IFS= read -r name; do
                path=$(tmux show-option -w -v -t "$session:$name" @vscode_root 2>/dev/null || true)
                if [ "${path:-}" = "$workspace" ]; then
                    printf '%s' "$name"
                    break
                fi
            done)

            if [ -n "$existing_window" ]; then
                target_window="$existing_window"
            else
                candidate="$window_slug"
                if tmux list-windows -t "$session" -F '#{window_name}' | grep -Fxq "$candidate"; then
                    idx=2
                    while tmux list-windows -t "$session" -F '#{window_name}' | grep -Fxq "${window_slug}-${idx}"; do
                        idx=$((idx + 1))
                    done
                    candidate="${window_slug}-${idx}"
                fi
                tmux new-window -t "$session" -n "$candidate" -c "$workspace"
                tmux set-option -w -t "$session:$candidate" @vscode_root "$workspace" >/dev/null
                target_window="$candidate"
                need_cd=1
            fi
        fi

        if [ -n "$need_cd" ] && [ -n "$target_window" ]; then
            tmux send-keys -t "$session:$target_window" "cd" Space "--" Space
            tmux send-keys -t "$session:$target_window" -l "$workspace"
            tmux send-keys -t "$session:$target_window" C-m
        fi

        client_session="${session}-client-$$"
        if ! tmux has-session -t "$client_session" 2>/dev/null; then
            tmux new-session -d -s "$client_session" -t "$session"
        fi

        tmux select-window -t "$client_session:$target_window" 2>/dev/null
        exec tmux attach-session -t "$client_session"
    fi
fi
EOF

    auto_block=${auto_block//__SESSION_NAME__/$SESSION_NAME}

    if grep -q "$auto_block_marker_start" "$bashrc" 2>/dev/null; then
        log "Refreshing existing VS Code auto-attach block in $bashrc"
        sed -i "/$auto_block_marker_start/,/$auto_block_marker_end/d" "$bashrc"
    else
        log "Adding VS Code auto-attach block to $bashrc"
    fi
    printf '\n%s\n%s\n' "$auto_block" "$auto_block_marker_end" >>"$bashrc"

    local tmux_conf="$HOME/.tmux.conf"
    local fish_path
    fish_path=$(command -v fish || true)
    if [ -n "$fish_path" ]; then
        if [ ! -f "$tmux_conf" ]; then
            log "Creating $tmux_conf"
            touch "$tmux_conf"
        fi
        local tmux_marker_start="# >>> codex vscode tmux defaults >>>"
        local tmux_marker_end="# <<< codex vscode tmux defaults <<<"
        if grep -q "$tmux_marker_start" "$tmux_conf" 2>/dev/null; then
            log "Refreshing tmux defaults block in $tmux_conf"
            sed -i "/$tmux_marker_start/,/$tmux_marker_end/d" "$tmux_conf"
        else
            log "Adding tmux defaults block to $tmux_conf"
        fi
        {
            printf '\n%s\n' "$tmux_marker_start"
            printf 'set -g default-shell %s\n' "$fish_path"
            printf 'set -g default-command "%s -l"\n' "$fish_path"
            printf '%s\n' "$tmux_marker_end"
        } >>"$tmux_conf"
    fi

    local fish_config_dir="$HOME/.config/fish"
    if [ ! -d "$fish_config_dir" ]; then
        log "Creating $fish_config_dir"
        mkdir -p "$fish_config_dir"
    fi

    local fish_config="$fish_config_dir/config.fish"
    if [ ! -f "$fish_config" ]; then
        log "Creating default $fish_config"
        cat <<'EOF' >"$fish_config"
if status is-interactive
    # Place interactive fish configuration here.
end
EOF
    fi

    # Install Fisher (Fish plugin manager) if missing.
    if ! fish -lc 'functions -q fisher' >/dev/null 2>&1; then
        log "Installing Fisher"
        fish -lc 'curl -fsSL https://git.io/fisher | source; and fisher install jorgebucaran/fisher'
    fi

    # Ensure nvm.fish plugin is installed for Fish shells.
    log "Ensuring jorgebucaran/nvm.fish plugin is installed"
    if ! fish -lc 'fisher list | string match -q "jorgebucaran/nvm.fish"' >/dev/null 2>&1; then
        fish -lc 'fisher install jorgebucaran/nvm.fish'
    else
        fish -lc 'fisher update jorgebucaran/nvm.fish'
    fi

    log "Setup complete. Reload your shell or open a new VS Code terminal to use the configuration."
}

main "$@"
