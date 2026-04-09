# Piterm

An omakase headless setup for Raspberry Pi OS Lite and Ubuntu-on-Pi hosts in the spirit of Omarchy by DHH.

## Requirements

- Base Raspberry Pi OS Lite or Ubuntu installation
- Internet connection
- `sudo` privileges

## Install

```bash
curl -fsSL https://piterm.org/install | bash
```

## What it sets up

- **Shell**: Bash with starship prompt, fzf, eza, zoxide
- **Editors**: Helix
  - Installed from official GitHub release binaries (`~/.local/bin/hx` + `~/.config/helix/runtime`)
- **Dev tools**: deno, docker, github-cli, lazygit, lazydocker
- **Optional AI tools**: opencode, claude-code
- **Networking**: SSH, tailscale
- **Git**: Interactive config for user name/email, helpful aliases

> Security note: installer asks whether you want to add your user to the `docker` group. If you decline, use `sudo docker ...`.

## Interactive prompts

During installation you'll be asked for:

- Git user name
- Git email address

And you'll be offered to setup:

- Optional AI assistants (opencode, claude-code)
- Tailscale
- GitHub
- SSH public keys
