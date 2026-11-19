#!/usr/bin/env bash
# Set up a dev environment on a fresh Ubuntu/Debian machine.
#
#   ./bootstrap.sh [options]
#
#   --profile server|workstation   server: shell + CLI tools only (EC2, remote boxes)
#                                  workstation: server + GUI apps, fonts, VS Code
#                                  default: workstation when a local display is
#                                  present, server otherwise
#   --identity kinsol|personal     default git identity / GitHub key (passed to dotfiles' init.sh)
#                                  required on first run unless stdin is a terminal
#   --only <step>[,<step>...]      run only these steps (see STEPS below)
#   --dry-run                      print what would run, change nothing
#   -h, --help                     show this help
#
# Env overrides: DOTFILES_REPO, DOTFILES_DIR (default: a "dotfiles" folder next to denv)
#
# Every step is safe to re-run: it checks before it changes anything.
set -euo pipefail

STEPS=(base shell dotfiles ssh gui vscode)
GUI_STEPS=" gui vscode "

DENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_REPO="${DOTFILES_REPO:-https://github.com/dtempleman/dotfiles.git}"
DOTFILES_PUSH_URL="git@github.com-personal:dtempleman/dotfiles.git"
# next to denv, e.g. ~/kemple/projects/denv -> ~/kemple/projects/dotfiles
DOTFILES_DIR="${DOTFILES_DIR:-$(dirname "$DENV_DIR")/dotfiles}"

profile="" identity="" only="" dry_run=0

usage() { sed -n '2,17s/^# \{0,1\}//p' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)  profile="${2:?}"; shift 2 ;;
        --identity) identity="${2:?}"; shift 2 ;;
        --only)     only="${2:?}"; shift 2 ;;
        --dry-run)  dry_run=1; shift ;;
        -h|--help)  usage 0 ;;
        *) echo "unknown option: $1" >&2; usage 1 ;;
    esac
done

# ---------------------------------------------------------------- helpers ---

WARNINGS=()
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; WARNINGS+=("$*"); }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# run <cmd...>: execute, or just print it under --dry-run
run() {
    if [[ $dry_run -eq 1 ]]; then printf '    [dry-run] %s\n' "$*"; else "$@"; fi
}

# backup <path>: move a file or link aside to <path>.bak, never overwriting
# an earlier backup (uses .bak.1, .bak.2, ... instead)
backup() {
    local dst="$1.bak" n=1
    while [[ -e $dst || -L $dst ]]; do dst="$1.bak.$n"; n=$((n + 1)); done
    log "backing up $1 -> $dst"
    run mv "$1" "$dst"
}

# the identity a dotfiles/.gitconfig.local selects (kinsol|personal), or nothing
current_identity() {
    local f="$DOTFILES_DIR/.gitconfig.local"
    [[ -f $f ]] || return 0
    grep -v '^[[:space:]]*#' "$f" | grep -oE '(kinsol|personal)\.gitconfig' | head -1 | sed 's/\.gitconfig//' || true
}

valid_identity() { [[ $1 == kinsol || $1 == personal ]]; }

# read a package list: drop comments and blank lines
pkgs() { sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$DENV_DIR/packages/$1"; }

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

check_os() {
    [[ $(uname -s) == Linux ]] || die "unsupported OS: $(uname -s) (denv supports Ubuntu/Debian only)"
    have apt-get || die "unsupported Linux: need apt-get (Ubuntu/Debian)"
}

# install a list of apt packages; if the batch fails, retry one by one
# so a single missing package (e.g. on an older release) is only a warning
pm_install() {
    [[ $# -eq 0 ]] && return 0
    # --no-remove: fail rather than uninstall anything to resolve a conflict
    local cmd=($SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-remove)
    run "${cmd[@]}" "$@" && return 0
    warn "batch install failed, retrying packages individually"
    local p
    for p in "$@"; do run "${cmd[@]}" "$p" || warn "could not install $p"; done
}

# ------------------------------------------------------------------ steps ---

# base: apt packages: essentials (git, curl, tmux, stow, build tools),
# the CLI tools the dotfiles use (eza, zoxide, fzf, ripgrep, fd) and docker
step_base() {
    run $SUDO apt-get update -q
    local packages
    packages="$(pkgs apt.txt)"
    # an existing Docker (e.g. docker-ce from Docker's own repo) conflicts with
    # Ubuntu's docker.io packages: keep it and skip ours
    if have docker; then
        log "docker already installed ($(docker --version 2>/dev/null | cut -d, -f1)), skipping the docker packages"
        packages="$(grep -v '^docker' <<< "$packages")"
    fi
    pm_install $packages
    docker_group
}

# let the current user run docker without sudo (applies from the next login)
docker_group() {
    local user
    user="$(id -un)"
    [[ $EUID -eq 0 ]] && return 0
    getent group docker >/dev/null || { [[ $dry_run -eq 1 ]] || warn "no docker group, skipping"; return 0; }
    id -nG "$user" | tr ' ' '\n' | grep -qx docker && return 0
    log "adding $user to the docker group (log out and back in to use docker without sudo)"
    run $SUDO usermod -aG docker "$user"
}

# shell: oh-my-posh (not in apt), then bash as login shell
step_shell() {
    if ! have oh-my-posh && [[ ! -x $HOME/.local/bin/oh-my-posh ]]; then
        # download first so a failed curl is caught (curl | bash would hide it)
        local installer
        installer="$(mktemp)"
        run mkdir -p "$HOME/.local/bin"
        if run curl -fsSL -o "$installer" https://ohmyposh.dev/install.sh &&
           run bash "$installer" -d "$HOME/.local/bin"; then
            :
        else
            warn "oh-my-posh install failed; re-run with --only shell to retry"
        fi
        rm -f "$installer"
    fi

    local bash_path=/bin/bash
    # -ef: /bin/bash and /usr/bin/bash are the same file on Ubuntu
    if [[ -n ${SHELL:-} && $SHELL -ef $bash_path ]]; then
        return 0
    fi
    grep -qx "$bash_path" /etc/shells || run sh -c "echo '$bash_path' | $SUDO tee -a /etc/shells >/dev/null"
    log "setting login shell to $bash_path"
    run $SUDO chsh -s "$bash_path" "$(id -un)" || warn "chsh failed, run it manually"
}

# dotfiles: clone, back up files that would block stow, stow, run init.sh
step_dotfiles() {
    if [[ ! -d $DOTFILES_DIR/.git ]]; then
        run mkdir -p "$(dirname "$DOTFILES_DIR")"
        run git clone "$DOTFILES_REPO" "$DOTFILES_DIR"
        # cloned over HTTPS (works before any SSH key exists); push over SSH
        run git -C "$DOTFILES_DIR" remote set-url --push origin "$DOTFILES_PUSH_URL"
    else
        log "dotfiles already at $DOTFILES_DIR"
    fi
    [[ $dry_run -eq 1 && ! -d $DOTFILES_DIR ]] && { log "skipping stow in dry-run (no clone yet)"; return 0; }

    # --no-folding: link files, never whole directories. Without it, on a fresh
    # machine ~/.ssh itself becomes a symlink into the repo and keys generated
    # later would be written inside the dotfiles checkout.
    local stow_cmd=(stow --no-folding -t "$HOME" .)
    run install -d -m 700 "$HOME/.ssh"

    # stow refuses to replace real files (a fresh machine's ~/.bashrc) or
    # symlinks it didn't make (e.g. links into an old checkout): move them aside
    local target
    while read -r target; do
        [[ -z $target ]] && continue
        if [[ -L $HOME/$target && $HOME/$target -ef $DOTFILES_DIR/$target ]]; then
            # already points at the right file (e.g. made by init.sh): just replace it
            run rm "$HOME/$target"
        else
            backup "$HOME/$target"
        fi
    done < <(cd "$DOTFILES_DIR" && "${stow_cmd[@]:0:1}" -n "${stow_cmd[@]:1}" 2>&1 |
        sed -n -e 's/.*over existing target \([^ ]*\) since.*/\1/p' \
               -e 's/.*existing target is neither a link nor a directory: \(.*\)/\1/p' \
               -e 's/.*existing target is not owned by stow: \(.*\)/\1/p')

    (cd "$DOTFILES_DIR" && run "${stow_cmd[@]}")

    # denv and dotfiles are personal repos: give them the personal identity and
    # GitHub key wherever they live (the ~/kemple folder rule only covers ~/kemple)
    local repo
    for repo in "$DENV_DIR" "$DOTFILES_DIR"; do
        [[ -d $repo/.git ]] || continue
        run git -C "$repo" config include.path "~/.config/git/kemple-dir.gitconfig"
    done

    local current
    current="$(current_identity)"
    if [[ -z $identity && -n $current ]]; then
        identity="$current"
        log "identity already set to $identity"
    fi
    if [[ -z $identity ]]; then
        [[ -t 0 ]] || die "--identity kinsol|personal is required for a non-interactive first run"
        until valid_identity "$identity"; do
            read -rp "default identity for this machine [kinsol/personal]: " identity
        done
    fi

    # -f regenerates the local files when switching to a different identity
    if [[ -n $current && $current != "$identity" ]]; then
        log "switching default identity: $current -> $identity"
        run "$DOTFILES_DIR/init.sh" -f "$identity"
    else
        run "$DOTFILES_DIR/init.sh" "$identity"
    fi
}

# ssh: make sure the GitHub key the ssh config expects for this identity is
# usable: from a forwarded agent (ssh -A) if one can reach GitHub, otherwise
# by generating a new key
step_ssh() {
    [[ -z $identity ]] && identity="$(current_identity)"
    local key
    case "$identity" in
        kinsol)   key="$HOME/.ssh/keys/kinsol/id_rsa_github_dtempleman" ;;
        personal) key="$HOME/.ssh/keys/personal/id_rsa_github_daniel_personal" ;;
        "") log "no identity set, skipping key setup"; return 0 ;;
    esac
    if [[ -f $key ]]; then
        log "key exists: $key"; return 0
    fi
    if [[ -f $key.pub ]]; then
        log "using forwarded agent key: $key.pub"; return 0
    fi
    forwarded_github_key "$key" && return 0
    run mkdir -p "$(dirname "$key")"
    run chmod 700 "$HOME/.ssh"
    # ed25519 despite the id_rsa_ filename: the name is what ~/.ssh/config points at
    run ssh-keygen -t ed25519 -N "" -C "$(id -un)@$(hostname)-$identity" -f "$key"
    [[ $dry_run -eq 1 ]] && return 0
    log "add this public key to GitHub (Settings > SSH and GPG keys):"
    cat "$key.pub"
}

# forwarded_github_key <key path>: when connected with ssh -A, find the agent key
# that GitHub accepts and save its public half as <key path>.pub. ~/.ssh/config
# sets IdentitiesOnly, so ssh only offers an agent key whose .pub sits at the
# configured IdentityFile path. Returns 1 if there is no such key.
forwarded_github_key() {
    local key="$1" pub line out
    # only a forwarded agent counts: a desktop keyring agent isn't forwarding
    [[ -n ${SSH_CONNECTION:-} && -n ${SSH_AUTH_SOCK:-} ]] || return 1
    pub="$(mktemp)"
    while read -r line; do
        printf '%s\n' "$line" > "$pub"
        out="$(ssh -F /dev/null -i "$pub" -o IdentitiesOnly=yes -o BatchMode=yes \
                   -o StrictHostKeyChecking=accept-new -T git@github.com 2>&1 || true)"
        if [[ $out == *"successfully authenticated"* ]]; then
            log "forwarded agent key works for GitHub (${out%%!*}); saving it as $key.pub"
            run mkdir -p "$(dirname "$key")"
            run cp "$pub" "$key.pub"
            rm -f "$pub"
            return 0
        fi
    done < <(ssh-add -L 2>/dev/null || true)
    rm -f "$pub"
    return 1
}

# gui: workstation apps, editor, Nerd Font
step_gui() {
    pm_install $(pkgs apt-gui.txt)
    if have snap; then
        have code || run $SUDO snap install code --classic
    else
        warn "snap not available: install VS Code manually"
    fi
    install_nerd_font
}

install_nerd_font() {
    local dir="$HOME/.local/share/fonts/JetBrainsMonoNerd" tmp
    # done only if font files are there (an empty dir means an earlier failure)
    compgen -G "$dir/*.ttf" >/dev/null && return 0
    log "installing JetBrainsMono Nerd Font"
    # download and unpack into a temp dir, move into place only on success
    tmp="$(mktemp -d)"
    if run curl -fsSL -o "$tmp/font.tar.xz" \
           https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz &&
       run mkdir -p "$tmp/font" &&
       run tar -xJf "$tmp/font.tar.xz" -C "$tmp/font"; then
        run mkdir -p "$(dirname "$dir")"
        run rm -rf "$dir"
        run mv "$tmp/font" "$dir"
        if have fc-cache; then run fc-cache -f "$dir"; fi
    else
        warn "Nerd Font download failed; re-run with --only gui to retry"
    fi
    rm -rf "$tmp"
}

# vscode: install the extensions listed in dotfiles' vscode-extensions.txt.
# settings.json is linked by the dotfiles step (stow), like any other config.
step_vscode() {
    have code || { warn "code CLI not found, skipping"; return 0; }
    local list="$DOTFILES_DIR/vscode-extensions.txt"
    [[ -f $list ]] || { warn "$list not found (run the dotfiles step), skipping"; return 0; }
    local installed ext
    if ! installed="$(code --list-extensions 2>/dev/null)"; then
        warn "'code --list-extensions' failed, skipping VS Code setup"; return 0
    fi
    installed="$(tr 'A-Z' 'a-z' <<< "$installed")"
    for ext in $(sed -e 's/#.*//' "$list"); do
        grep -qx "$(tr 'A-Z' 'a-z' <<< "$ext")" <<< "$installed" ||
            run code --install-extension "$ext" || warn "could not install extension $ext"
    done
}

# ------------------------------------------------------------------- main ---

check_os

if [[ -z $profile ]]; then
    # a display over ssh (ssh -X) doesn't make a server a workstation
    if [[ -z ${SSH_CONNECTION:-} && -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
        profile=workstation
    else
        profile=server
    fi
fi
[[ $profile == server || $profile == workstation ]] || die "unknown profile: $profile"
[[ -z $identity ]] || valid_identity "$identity" || die "unknown identity: $identity"

if [[ -n $only ]]; then
    IFS=, read -ra selected <<< "$only"
    for s in "${selected[@]}"; do [[ " ${STEPS[*]} " == *" $s "* ]] || die "unknown step: $s"; done
else
    selected=("${STEPS[@]}")
fi

log "profile=$profile identity=${identity:-<unset>} steps=${selected[*]}$([[ $dry_run -eq 1 ]] && echo ' (dry run)')"

for s in "${selected[@]}"; do
    if [[ $profile == server && $GUI_STEPS == *" $s "* && -z $only ]]; then
        continue
    fi
    log "step: $s"
    "step_$s"
done

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    log "done with ${#WARNINGS[@]} warning(s):"
    for w in "${WARNINGS[@]}"; do printf '    - %s\n' "$w"; done
else
    log "done."
fi
log "open a new shell to pick up the changes."
