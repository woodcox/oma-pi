# Oma-Pi

A minimal setup for debian based systems like Raspberry Pi OS Lite and Ubuntu in the spirit of Omarchy/[Omaterm](https://github.com/omacom-io/omaterm). This has only been tested on a Raspberry Pi 5 with 8GB ram and SSD storage.

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
curl -fsSL https://raw.githubusercontent.com/woodcox/oma-pi/main/install.sh | bash

```

## What it sets up

- **Shell**: Bash with starship prompt, fzf, eza, zoxide
- **Editors**: [Helix editor](https://helix-editor.com/) installed from official GitHub release binaries (`~/.local/bin/hx` + `~/.config/helix/runtime`)
- **Dev tools**: deno, docker, git, github-cli, lazygit, lazydocker, tmux, btop, jq and kitty-terminfo
- **Optional AI tools**: opencode, claude-code, codex
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

## Commands
See the [Omaterm manual](https://learn.omacom.io/2/the-omarchy-manual/106/terminal) for relevant commands and [hotkeys](https://learn.omacom.io/4/the-omapi-manual/113/hotkeys) for using:

 - `omapi-setup`: Git name and email and github cli
 - `omapi-refresh`: Reinstall Oma-pi with initial configs
 - `omapi-ssh`: Add SSH key for remote access
 - `omapi-theme`: Switch helix editor themes

 - [opencode](https://opencode.ai/): alias `c`
 - Claude: alias `cx=printf "\033[2J\033[3J\033[H" && claude --allow-dangerously-skip-permissions`
 - Docker: alias `d`
 - Lazydocker: alias `lzd`
 - Tmux alias: 
      - `t=tmux attach || tmux new -s Work`
      - `ic=tdl c`
      - `ix=tdl cx`
      - `icx=tdl c cx`
 - Github: alias `gh`
 - Git alias:   
      - `g=git`
      - `gcm=git commit -m`
      - `gcam=git commit -a -m`
 - [Fzf](https://junegunn.github.io/fzf/): alias `ff`
 - [Zoxide](https://github.com/ajeetdsouza/zoxide): alias `cd`
 - [Eza](https://eza.rocks/) alias:
      - `ls`
      - `lt` for listing of two-deep levels of nesting
      - `lsa` for listing including hidden files
      -  `lta` for a nested listing with hidden files
 - [Btop](https://github.com/aristocratos/btop)
 - [tldr](https://tldr.sh/)