# Codex VS Code Remote Bootstrap

This folder contains a one-shot script that reproduces the VS Code Remote + tmux + Fish workflow used on the current machine.

## What it does

`001-create-user.sh` provisions a new Linux account (default `codex001`), mirrors the invoking user's SSH configuration, grants passwordless sudo, and seeds a git identity for the agent. `002-setup-remote-vscode-codex.sh` installs the required packages (tmux, fish, curl, git), configures tmux to launch Fish by default, installs the Fisher plugin manager plus `jorgebucaran/nvm.fish`, and drops the VS Code auto-attach logic into `~/.bashrc`. Each VS Code terminal attaches through its own grouped tmux session while sharing the common `vscode` window set, so switching panes in one terminal doesn’t hijack the others.

## Usage

1. Copy this repository (or at minimum `001-create-user.sh`) to the remote machine.
2. Create the agent account (defaults to `codex001`) as the existing administrator:

   ```bash
   sudo bash 001-create-user.sh
   ```

   Use `--user` to pick a different login and `--source-user` if you need to copy credentials from someone other than the invoking account.

   The script will mirror the source user’s SSH keys, grant passwordless sudo, clone this repo into the new user’s home (reusing the current remote if available), and run `002-setup-remote-vscode-codex.sh` as that user automatically.
3. Open VS Code Remote (or SSH) as the new user and launch an integrated terminal; it will attach to tmux automatically.

`002-setup-remote-vscode-codex.sh` is idempotent — rerun it any time (e.g. `sudo su - codex001`, then `bash ~/codex-vscode-remote/002-setup-remote-vscode-codex.sh`) to refresh the config blocks. Existing customisations outside the marked sections stay untouched. Need a different session name or want to skip package installs? Use the optional flags:

```bash
# Use a custom tmux session name instead of "vscode"
bash 002-setup-remote-vscode-codex.sh --session-name myproject

# Apply dotfile tweaks only (packages already installed)
bash 002-setup-remote-vscode-codex.sh --skip-packages
```

Session names are sanitised to alphanumeric/`._-` characters (spaces become underscores) so tmux accepts them.

## Requirements

- A Linux distribution with one of: `apt`, `dnf`, `yum`, or `pacman`. Other distros must install `tmux`, `fish`, `curl`, and `git` manually before running the script.
- Network access for package installs and fetching Fisher/nvm.fish.
- Optional: `sudo` if you are not running the script as root.

## What you get

- `~/.bashrc`: VS Code-aware tmux auto-attach block with per-workspace windows and per-terminal grouped sessions.
- `~/.tmux.conf`: default shell set to Fish (`default-command` and `default-shell`).
- `~/.config/fish`: ensures the directory exists and installs Fisher + `jorgebucaran/nvm.fish` so the Fish shell recognises `nvm` whenever you install it.

After the script finishes, open a new VS Code terminal (or `source ~/.bashrc`) to pick up the changes. Use `tmux list-sessions | grep vscode-client` to inspect individual client sessions if needed; tmux will recreate them automatically.
