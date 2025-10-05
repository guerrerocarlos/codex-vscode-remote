#!/usr/bin/env bash
set -euo pipefail

LOG_PREFIX="[codex-user]"
TARGET_USER="codex001"
SOURCE_USER=""
SUDOERS_FILE=""
GIT_NAME="Carlos Guerrero"
GIT_EMAIL="c@carlosguerrero.com"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_NAME=$(basename "$SCRIPT_DIR")
if command -v git >/dev/null 2>&1 && git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    REPO_REMOTE=$(git -C "$SCRIPT_DIR" config --get remote.origin.url || true)
else
    REPO_REMOTE=""
fi

usage() {
    cat <<'USAGE'
Usage: 001-create-user.sh [options]

Options:
  --user NAME          Username to create (default: codex001)
  --source-user NAME   Existing user to copy SSH credentials from
  --help               Show this help message and exit
USAGE
}

log() {
    printf '%s %s\n' "$LOG_PREFIX" "$*"
}

err() {
    printf '%s ERROR: %s\n' "$LOG_PREFIX" "$*" >&2
}

require_root() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        err "This script must be run as root (try: sudo $0 ...)"
        exit 1
    fi
}

determine_source_user() {
    if [ -n "$SOURCE_USER" ]; then
        return
    fi

    if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        SOURCE_USER="$SUDO_USER"
        return
    fi

    local logname_user
    logname_user=$(logname 2>/dev/null || true)
    if [ -n "$logname_user" ] && [ "$logname_user" != "root" ]; then
        SOURCE_USER="$logname_user"
        return
    fi

    if [ -n "${USER:-}" ] && [ "${USER}" != "root" ]; then
        SOURCE_USER="$USER"
    fi
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --user)
                shift || { err "--user requires a value"; exit 1; }
                TARGET_USER="$1"
                ;;
            --source-user)
                shift || { err "--source-user requires a value"; exit 1; }
                SOURCE_USER="$1"
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

sanitize_username() {
    local name=$1
    if ! printf '%s' "$name" | grep -Eq '^[a-z_][a-z0-9_-]*$'; then
        err "Invalid username: $name"
        exit 1
    fi
}

user_home() {
    local user=$1
    getent passwd "$user" | cut -d: -f6
}

copy_ssh_credentials() {
    local src_home=$1
    local dst_home=$2

    if [ ! -d "$src_home/.ssh" ]; then
        log "Source user has no ~/.ssh directory; skipping SSH credential copy"
        return
    fi

    log "Copying SSH credentials from $src_home/.ssh to $dst_home/.ssh"
    mkdir -p "$dst_home/.ssh"
    cp -a "$src_home/.ssh/." "$dst_home/.ssh/"
    chown -R "$TARGET_USER:$TARGET_USER" "$dst_home/.ssh"
    chmod 700 "$dst_home/.ssh"
    find "$dst_home/.ssh" -type d -exec chmod 700 {} +
    find "$dst_home/.ssh" -type f -exec chmod 600 {} +
}

copy_path_if_missing() {
    local src_home=$1
    local dst_home=$2
    local rel_path=$3

    local src="$src_home/$rel_path"
    local dst="$dst_home/$rel_path"

    if [ ! -e "$src" ]; then
        return
    fi

    if [ -e "$dst" ]; then
        log "Keeping existing $rel_path in $dst_home"
        return
    fi

    local parent
    parent=$(dirname "$dst")
    if [ ! -d "$parent" ]; then
        mkdir -p "$parent"
    fi

    log "Copying $rel_path from source user"
    cp -a "$src" "$dst"

    local top_component
    case "$rel_path" in
        */*)
            top_component=${rel_path%%/*}
            ;;
        *)
            top_component=$rel_path
            ;;
    esac

    if [ -n "$top_component" ] && [ -e "$dst_home/$top_component" ]; then
        chown -R "$TARGET_USER:$TARGET_USER" "$dst_home/$top_component"
    else
        chown -R "$TARGET_USER:$TARGET_USER" "$dst"
    fi
}

copy_dev_environment() {
    local src_home=$1
    local dst_home=$2

    local -a rel_paths=(
        ".nvm"
        ".local/share/nvm"
        ".config/nvm"
        ".npmrc"
        ".npm"
        ".config/npm"
        ".local/bin"
        ".local/share/fisher"
        ".config/fish/functions"
        ".config/fish/conf.d"
        ".config/fish/completions"
        ".config/fish/fish_plugins"
        ".config/codex"
    )

    local rel
    for rel in "${rel_paths[@]}"; do
        copy_path_if_missing "$src_home" "$dst_home" "$rel"
    done
}

run_as_target() {
    local cmd=$1
    if command -v runuser >/dev/null 2>&1; then
        runuser -l "$TARGET_USER" -c "$cmd"
    else
        su - "$TARGET_USER" -c "$cmd"
    fi
}

configure_git_identity() {
    local dst_home=$1
    local gitconfig="$dst_home/.gitconfig"

    if command -v git >/dev/null 2>&1; then
        local name_cmd email_cmd
        printf -v name_cmd 'git config --global user.name %q' "$GIT_NAME"
        printf -v email_cmd 'git config --global user.email %q' "$GIT_EMAIL"
        log "Setting git identity via git config"
        run_as_target "$name_cmd"
        run_as_target "$email_cmd"
    else
        log "git not found; writing $gitconfig manually"
        cat >"$gitconfig" <<'EOF_GIT'
[user]
    name = Carlos Guerrero's Agent
    email = agent@carlosguerrero.com
EOF_GIT
        chown "$TARGET_USER:$TARGET_USER" "$gitconfig"
        chmod 600 "$gitconfig"
    fi
}

bootstrap_target_user() {
    local target_home=$1
    local repo_dir="$target_home/$REPO_NAME"

    if [ -d "$repo_dir" ]; then
        log "Repository already present at $repo_dir"
        if command -v git >/dev/null 2>&1; then
            local pull_cmd
            printf -v pull_cmd 'cd %q && git pull --rebase --autostash >/dev/null 2>&1 || true' "$repo_dir"
            run_as_target "$pull_cmd"
        fi
    else
        if command -v git >/dev/null 2>&1 && [ -n "$REPO_REMOTE" ]; then
            local clone_cmd
            printf -v clone_cmd 'git clone %q %q' "$REPO_REMOTE" "$repo_dir"
            log "Cloning repository into $repo_dir"
            run_as_target "$clone_cmd"
        else
            log "Git remote unavailable; copying current directory into $repo_dir"
            mkdir -p "$repo_dir"
            cp -a "$SCRIPT_DIR/." "$repo_dir/"
            chown -R "$TARGET_USER:$TARGET_USER" "$repo_dir"
        fi
    fi

    local bootstrap_script="$repo_dir/002-setup-remote-vscode-codex.sh"
    if [ -f "$bootstrap_script" ]; then
        local run_cmd
        printf -v run_cmd 'cd %q && bash 002-setup-remote-vscode-codex.sh' "$repo_dir"
        log "Running bootstrap as $TARGET_USER"
        run_as_target "$run_cmd"
    else
        log "Bootstrap script not found at $bootstrap_script; skipping auto run"
    fi
}

configure_sudoers() {
    SUDOERS_FILE="/etc/sudoers.d/99-$TARGET_USER"
    log "Configuring passwordless sudo in $SUDOERS_FILE"
    printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$TARGET_USER" >"$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"
}

main() {
    parse_args "$@"
    require_root
    sanitize_username "$TARGET_USER"
    determine_source_user

    if [ -z "$SOURCE_USER" ] || [ "$SOURCE_USER" = "root" ]; then
        err "Could not determine a non-root source user. Use --source-user USER to specify one."
        exit 1
    fi

    if ! getent passwd "$SOURCE_USER" >/dev/null 2>&1; then
        err "Source user '$SOURCE_USER' does not exist"
        exit 1
    fi

    local source_home
    source_home=$(user_home "$SOURCE_USER")
    if [ -z "$source_home" ] || [ ! -d "$source_home" ]; then
        err "Unable to determine home directory for source user $SOURCE_USER"
        exit 1
    fi

    log "Creating or updating user: $TARGET_USER (source: $SOURCE_USER)"

    if id "$TARGET_USER" >/dev/null 2>&1; then
        log "User $TARGET_USER already exists; skipping creation"
    else
        useradd -m -s /bin/bash "$TARGET_USER"
        log "User $TARGET_USER created"
    fi

    passwd -d "$TARGET_USER" >/dev/null 2>&1 || true

    local target_home
    target_home=$(user_home "$TARGET_USER")
    if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
        err "Unable to determine home directory for target user $TARGET_USER"
        exit 1
    fi

    copy_ssh_credentials "$source_home" "$target_home"
    copy_dev_environment "$source_home" "$target_home"
    configure_git_identity "$target_home"
    configure_sudoers
    bootstrap_target_user "$target_home"

    log "Done. New user: $TARGET_USER"
    log "Home directory: $target_home"
    if [ -n "$SUDOERS_FILE" ]; then
        log "sudoers entry: $SUDOERS_FILE"
    fi
}

main "$@"
