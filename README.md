# Oma-Pi

A minimal setup for debian based systems like Raspberry Pi OS Lite and Ubuntu in the spirit of Omarchy/[Omaterm](https://github.com/omacom-io/omaterm). This has only been tested on a Raspberry Pi 5 with 8GB ram and SSD storage.

## Requirements

- Base Raspberry Pi OS Lite, Debian or Ubuntu server installation
- Harden the RPi / VM by following: 
  - [chrisapproved.com](https://chrisapproved.com/blog/raspberry-pi-hardening.html) blog post or other similar advice. The repo is on [GitLab](https://gitlab.com/cgoff/raspberry-pi-hardening) but was last updated Aug 2019
  - [Raspberry Pi Security Hardening Complete Guide](https://ohyaan.github.io/tips/raspberry_pi_security_hardening_complete_guide/)
  - [Raspberry Pi hardening tips](https://raspberrytips.com/security-tips-raspberry-pi/)

`security.sh` automates the hardening those three guides describe, if you would rather not do it by hand.
- Internet connection
- `sudo` privileges

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/woodcox/oma-pi/main/install.sh | bash

```

## Security hardening

```bash
git clone https://github.com/woodcox/oma-pi.git
cd oma-pi

./security.sh --dry-run     # read the plan, change nothing
sudo ./security.sh           # do it
```

`security.sh` applies the advice from the three hardening guides linked under Requirements:
sshd hardening, ufw with only the ports you actually run exposed, fail2ban, automatic
security updates, AppArmor, and kernel and network sysctls. File-integrity monitoring
(aide) is opt-in — ask for it by name, since building the baseline reads the whole
filesystem. Add `--report` to save the resulting audit to `~/security-audit/`.

```bash
./security.sh --list                 # available tasks
sudo ./security.sh ssh firewall      # just these two
sudo ./security.sh --yes             # take the recommended defaults
./test/security-test.sh              # 35 tests, no root needed
```

Some deliberate choices worth knowing before you run it:

- **It will not lock you out.** Before disabling SSH passwords it looks for a
  non-root account with an `authorized_keys` entry that `ssh-keygen` actually
  accepts. An empty file, a truncated paste or a private key pasted in all look
  like a key to a naive check, and the result is a headless Pi you cannot reach.
  With no usable key it stops and asks — and that question defaults to *no*, so
  neither `--yes` nor `--force` can talk its way past it. Every config is
  validated before its service restarts, and rolled back if it fails.
- **Prompts use `gum`**, reading `/dev/tty` directly, so they still appear when
  the script is iterating over ports or accounts. Without a terminal at all it
  says so and takes the documented default rather than silently guessing.
- **Docker ports are detected.** Published container ports bypass ufw through
  the `DOCKER-USER` chain. The script identifies them via `docker ps`, offers
  them to you by name, and warns that ufw does not cover them.
- **`net.ipv4.ip_forward` is left alone** when the Docker service is *running*,
  since the container bridge needs it. If Docker is installed but stopped when
  you run the script, forwarding is turned off; start Docker and re-run if that
  matters. There is a test that fails if this ever regresses.
- **`AllowTcpForwarding` stays on**, because `config/shell/fns/ssh-port-forwarding`
  depends on it.
- **Wi-Fi and Bluetooth are not disabled.** That needs a `/boot/config.txt`
  dtoverlay and a reboot, and getting it wrong drops the box off the network you
  are managing it over. The exact lines are printed at the end of a run.

## What it sets up

- **Shell**: Bash with starship prompt, fzf, eza, zoxide
- **Editors**: [Helix editor](https://helix-editor.com/) installed from official GitHub release binaries (`~/.local/bin/hx` + `~/.config/helix/runtime`)
- **Dev tools**: deno, docker, git, github-cli, lazygit, lazydocker, tmux, btop, jq and kitty-terminfo
- **Optional AI tools**: opencode, claude-code, hermes-agent
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
- Optional AI assistants (opencode, claude-code and hermes-agent)

> Warning - Before you install Docker, make sure you consider the security implications and firewall incompatibilities of ufw on https://docs.docker.com/engine/install/debian/#firewall-limitations

> Security note: the installer adds the user to the `docker` group which grants root-level privileges to the user. For details on how this impacts security in your system, see [Docker Daemon Attack Surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface). If you decline, use `sudo docker ...`.

## Commands
See the [Omaterm manual](https://learn.omacom.io/2/the-omarchy-manual/106/terminal) for relevant commands and [hotkeys](https://learn.omacom.io/4/the-omapi-manual/113/hotkeys) for using:

 - `omapi-setup`: Git name and email and github cli
 - `omapi-refresh`: Reinstall Oma-pi with initial configs
 - `omapi-ssh`: Add SSH key for remote access
 - `omapi-theme`: Switch helix editor themes

 - [opencode](https://opencode.ai/): alias `c`
 - Claude: alias `cx=printf "\033[2J\033[3J\033[H" && claude --permission-mode bypassPermissions`
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
