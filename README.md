# Oma-Pi

#TODO: 

 - remove the unneeded config files from the omadots - https://github.com/omacom-io/omadots/refs/heads/master/install.sh
 - could just install specfic config files (not nvim)


A headless setup for debian based systems like Raspberry Pi OS Lite and Ubuntu in the spirit of Omarchy/[Omaterm](https://github.com/omacom-io/omaterm). This has only been tested on a Raspberry Pi 5 with 8GB ram and SSD storage.

## Requirements

- Base Raspberry Pi OS Lite, Debian or Ubuntu installation
- Harden the RPi / VM by following: 
  - [chrisapproved.com](https://chrisapproved.com/blog/raspberry-pi-hardening.html) blog post or other similar advice. The repo is on [GitLab](https://gitlab.com/cgoff/raspberry-pi-hardening) but was last updated Aug 2019
  - [Raspberry Pi Security Hardening Complete Guide](https://ohyaan.github.io/tips/raspberry_pi_security_hardening_complete_guide/)
  - [Raspberry Pi hardening tips](https://raspberrytips.com/security-tips-raspberry-pi/)
- Internet connection
- `sudo` privileges

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/woodcox/oma-pi/main/install | bash

```

## What it sets up

- **Shell**: Bash with starship prompt, fzf, eza, zoxide
- **Editors**: [Helix editor](https://helix-editor.com/) installed from official GitHub release binaries (`~/.local/bin/hx` + `~/.config/helix/runtime`)
- **Dev tools**: deno, docker, git, github-cli, lazygit, lazydocker, tmux, btop, jq and kitty-terminfo
- **Optional AI tools**: opencode, claude-code
- **Networking**: SSH, tailscale
- **Git**: Interactive config for user name/email, helpful aliases

## Interactive prompts

During installation you'll be asked for:

- Git user name
- Git email address

And you'll be offered to setup:

- GitHub
- Root level user permissions for Docker
- SSH public keys
- Tailscale
- Optional AI assistants (opencode, claude-code)

> Warning - Before you install Docker, make sure you consider the security implications and firewall incompatibilities of ufw on https://docs.docker.com/engine/install/debian/#firewall-limitations

> Security note: the installer asks whether you want to add your user to the `docker` group which grants root-level privileges to the user. For details on how this impacts security in your system, see [Docker Daemon Attack Surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface). If you decline, use `sudo docker ...`.
