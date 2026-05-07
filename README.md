# Omaterm

An Omakase Terminal Setup For Arch/Debian/Ubuntu/Fedora by DHH

## Requirements

- Base Arch/Debian/Ubuntu/Fedora Linux installation
- Internet connection
- `sudo` privileges

## Install

```bash
curl -fsSL https://omaterm.org/install | bash
```

## What it sets up

- **Shell**: Bash with starship prompt, fzf, eza, zoxide
- **Editors**: Neovim (LazyVim), opencode, claude-code
- **Dev tools**: mise, docker, github-cli, lazygit, lazydocker
- **Networking**: SSH, tailscale
- **Git**: Interactive config for user name/email, helpful aliases

## Docker

```bash
docker run -it -v omaterm-home:/home/omaterm ghcr.io/omacom-io/omaterm
```

The named volume persists your home directory across container restarts, including git config, gh auth, shell history, and projects.

## Interactive prompts

During installation you'll be asked for:

- Git user name
- Git email address

And you'll be offered to setup:

- Tailscale
- GitHub
- SSH public keys
