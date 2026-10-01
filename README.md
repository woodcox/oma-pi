# Oma-Pi

A minimal setup for debian based systems like Raspberry Pi OS Lite and Ubuntu in the spirit of Omarchy/[Omaterm](https://github.com/omacom-io/omaterm). This has only been tested on a Raspberry Pi 5 with 8GB ram and SSD storage.

## Requirements

- Base Raspberry Pi OS Lite, Debian or Ubuntu server installation
  - Tested on Raspberry Pi OS Lite / Debian 12 (bookworm).
  - **Ubuntu 24.04 (noble) or newer.** Ubuntu moved sshd to systemd socket
    activation in 22.10. On 24.04 and later a `Port` change in
    `sshd_config` is read by a systemd generator, so `omapi-harden` can move
    the port by reloading and restarting `ssh.socket`. On 22.10 through
    23.10 there is no such generator: `ssh.socket` uses a fixed
    `ListenStream=22`, the `Port` directive is ignored, and the script would
    report a port move that never happened. Those three releases are not
    supported.
  - On Ubuntu, `nnn` lives in `universe`, which a stock server image does not
    enable. The installer skips it and says so rather than failing the run.
    Enable it with `sudo add-apt-repository universe` to get the file manager.
- Harden the RPi / VM by following: 
  

  - `omapi-harden` automates the hardening those three guides describe, 

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/woodcox/oma-pi/main/install.sh | bash

```

## What it sets up

- **Shell**: Bash with starship prompt, fzf, eza, zoxide
- **Files**: nnn as the interactive file manager
- **Editor**: [MS Edit](https://github.com/microsoft/edit) installed from official GitHub release binaries as `~/.local/bin/msedit`, the default `$EDITOR`
- **Optional editor**: [Fresh](https://getfresh.dev) (`~/.local/bin/fresh`)
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
- Optional editor (Fresh)
- Optional AI assistants (opencode, claude-code and hermes-agent)

> Warning - Before you install Docker, make sure you consider the security implications and firewall incompatibilities of ufw on https://docs.docker.com/engine/install/debian/#firewall-limitations

> Security note: the installer adds the user to the `docker` group which grants root-level privileges to the user. For details on how this impacts security in your system, see [Docker Daemon Attack Surface](https://docs.docker.com/engine/security/#docker-daemon-attack-surface). If you decline, use `sudo docker ...`.

## Commands
See the [Omaterm manual](https://learn.omacom.io/2/the-omarchy-manual/106/terminal) for relevant commands and [hotkeys](https://learn.omacom.io/4/the-omapi-manual/113/hotkeys) for using:

 - `omapi-setup`: Git name and email and github cli
 - `omapi-refresh`: Reinstall Oma-pi with initial configs
 - `omapi-ssh`: Add SSH key for remote access
 - `omapi-harden`: One-time security hardening — run `omapi-harden --dry-run` first. See security hardening section for further details

 - [opencode](https://opencode.ai/): alias `c`
 - Claude: alias `cx=printf "\033[2J\033[3J\033[H" && claude --permission-mode bypassPermissions`
 - Hermes: alias `ha=hermes`
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
      - `lta` for a nested listing with hidden files
 - [Btop](https://github.com/aristocratos/btop)
 - [nnn](https://github.com/jarun/nnn) file manager
 - [tldr](https://tldr.sh/)

## Security hardening

After installing you can run `omapi-harden` which applies the following hardening: 
sshd hardening, ufw with only the ports you actually run exposed, fail2ban, automatic
security updates, AppArmor, and kernel and network sysctls. 

File-integrity monitoring (aide) is opt-in — ask for it by name, since building the baseline reads the whole
filesystem. Add `--report` to save the resulting audit to `~/security-audit/`.

Run it under `sudo`, with the full path as the validator also needs
root to read `/etc/ufw/after.rules` (`0640 root:root`); without it the
`DOCKER-USER` rules are reported as unverified rather than checked.

```bash
sudo /home/[user]/.local/bin/omapi-harden --list       # available tasks
sudo /home/[user]/.local/bin/omapi-harden ssh firewall  # just these two
sudo /home/[user]/.local/bin/omapi-harden --yes         # take the recommended defaults
./test/omapi-harden-test.sh              # test suite does not need root access
```

If you would rather do it by hand, please see the three hardening guides below:
  - [chrisapproved.com](https://chrisapproved.com/blog/raspberry-pi-hardening.html) blog post or other similar advice. The repo is on [GitLab](https://gitlab.com/cgoff/raspberry-pi-hardening) but was last updated Aug 2019
  - [Raspberry Pi Security Hardening Complete Guide](https://ohyaan.github.io/tips/raspberry_pi_security_hardening_complete_guide/)
  - [Raspberry Pi hardening tips](https://raspberrytips.com/security-tips-raspberry-pi/)

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
- **Docker and ufw are reconciled.** Docker writes its own DNAT and ACCEPT
  rules ahead of ufw's, so a published port is reachable from the internet no
  matter what ufw says — `ufw deny 8080` does not stop it. The script installs
  the [`DOCKER-USER` rules from
  chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker) into
  `/etc/ufw/after.rules`, which closes every published port by default, then
  offers each one by container name. Opening one takes a `ufw route allow`
  rule, which matches on the **container** port, not the host port. The
  block is appended to the file rather than prepended, because ufw restores
  `after.rules` as a single ruleset and a `COMMIT` in the middle would leave
  ufw's own rules outside any table. `after6.rules` gets the same treatment
  when ufw has IPv6 enabled, so the bypass is not just closed on one family.
  The rules are written inline rather than by installing the upstream script — it is a
  handful of static iptables lines, and fetching and running a third-party
  script as root on every hardened box is a supply-chain risk. The upstream
  block markers are used verbatim, so `ufw-docker check` and `ufw-docker
  uninstall` still recognise it if you install the real tool later.
  See [this write-up](https://blog.jarrousse.org/2023/03/18/how-to-use-ufw-firewall-with-docker-containers/)
  for the background.
- **Automatic updates reach the kernel too.** `Allowed-Origins` normally gets
  `debian:bookworm-security` and nothing else, but on a Pi the kernel, the
  bootloader and the EEPROM are not Debian packages — they come from
  `archive.raspberrypi.com`, which publishes no `-security` suite at all, only
  `bookworm` main. Omitting it means `linux-image-*`, `rpi-eeprom` and
  `raspi-firmware` never get a patch, unattended-upgrades stays green, and
  nothing anywhere says so. So the archive is added when it is configured, with
  its Origin and Suite read out of apt rather than hardcoded — a wrong value
  produces a config that looks right and matches nothing. Docker, tailscale,
  github-cli, charm and gierens are deliberately **not** added; auto-upgrading
  those unattended is how a working stack dies at 3am, and they are not where
  this box's kernel-level exposure lives. Anything `apt upgrade` defers because
  it needs a new dependency is named out loud, because that class of hold is
  silent by nature. `--report` also flags a kernel image in `/boot` that no
  package owns — the signature of `rpi-update`, which installs a kernel outside
  apt's management so it quietly stops receiving patches. That check is scoped
  to kernel images: a Pi's `initrd.img-*`, `cmdline.txt` and `overlays` are
  untracked by design, and a check that fires on every machine is one nobody
  reads.
- **`net.ipv4.ip_forward` is left alone** when the Docker service is *running*,
  since the container bridge needs it. If Docker is installed but stopped when
  you run the script, forwarding is turned off; start Docker and re-run if that
  matters. There is a test that fails if this ever regresses.
- **`AllowTcpForwarding` stays on**, because `config/shell/fns/ssh-port-forwarding`
  depends on it.
- **Wi-Fi and Bluetooth are not disabled.** That needs a `/boot/config.txt`
  dtoverlay and a reboot, and getting it wrong drops the box off the network you
  are managing it over. The exact lines are printed at the end of a run.
