# denv plan

denv turns a fresh machine into a working dev environment with one command.
It works the same on a personal laptop, a work machine, and a remote Ubuntu box such as EC2.
It supports Ubuntu/Debian only (written against Ubuntu 24.04). macOS is not supported.

## Split between denv and dotfiles

The two repos stay separate. Each has one job.

| Repo | Job | Contains |
| --- | --- | --- |
| **denv** | Provisions the machine: installs things | `bootstrap.sh` and package lists |
| **dotfiles** | Configures the machine: what the tools read | bash, git, ssh, tmux, oh-my-posh, tilix and VS Code config, managed with GNU stow, plus `init.sh` for per-machine identity |

denv clones dotfiles and stows it. It does not copy config files into itself. The copies of ghostty, aerospace, zsh and bash config that used to be in `config/` were removed because they had drifted from dotfiles.

Why not merge them:

- On a shared server or a short-lived box, `git clone dotfiles && stow .` alone is often enough. That path should not depend on the package installer.
- On a machine denv doesn't support, the dotfiles still work on their own.
- denv clones dotfiles instead of adding it as a submodule, so you can edit and push dotfiles from a live machine without submodule pointer churn.

## Layout

```
denv/
├── bootstrap.sh          entry point; every step is safe to re-run
├── Makefile              wrapper: make server IDENTITY=kinsol, make dotfiles
├── packages/
│   ├── apt.txt           Ubuntu/Debian: essentials, CLI tools, python, docker
│   └── apt-gui.txt       Ubuntu/Debian workstation extras
└── docs/plan.md
```

## Usage

```shell
git clone https://github.com/dtempleman/denv.git && cd denv
./bootstrap.sh --identity personal                   # profile chosen from the machine
./bootstrap.sh --profile server --identity kinsol    # EC2 / headless
./bootstrap.sh --only dotfiles,vscode                # selected steps only
./bootstrap.sh --dry-run                             # print the commands, change nothing
```

### Remote machines (EC2)

Connect with agent forwarding, then run the bootstrap by hand:

```shell
ssh -A ubuntu@<host>
git clone https://github.com/dtempleman/denv.git && ./denv/bootstrap.sh --profile server --identity kinsol
```

With `ssh -A`, git on the instance uses your local GitHub key, so the `ssh` step doesn't create a new key there.

### Options

- **Profile.**
  - `server`: shell, git, tmux and CLI tools only.
  - `workstation`: everything in `server`, plus GUI apps, a Nerd Font and VS Code.
  - Default: `workstation` when a local display is present, otherwise `server`. A display forwarded over `ssh -X` doesn't count.
- **Identity** (`kinsol` or `personal`). Passed to dotfiles' `init.sh`, which sets the default git identity and GitHub key. The `~/kinsol` and `~/kemple` folder rules still apply on top.

### Steps

Steps run in this order:

| Step | What it does |
| --- | --- |
| `base` | Installs everything in `apt.txt`, including Docker and Docker Compose, and adds you to the `docker` group (takes effect at your next login). |
| `shell` | Installs oh-my-posh (official installer, into `~/.local/bin`), since apt doesn't have it. Then sets bash as the login shell. |
| `dotfiles` | Clones dotfiles over HTTPS into a `dotfiles` folder next to denv (override with `DOTFILES_DIR`) and sets the push URL to SSH. Sets the personal git identity on both denv and dotfiles, so commits to them are personal wherever they are cloned. Moves conflicting real files (such as `~/.bashrc`) to `*.bak`. Runs `stow --no-folding` and then `init.sh <identity>`. |
| `ssh` | Makes sure the GitHub key the dotfiles ssh config expects for the identity is usable. If you connected with `ssh -A` and a forwarded key can reach GitHub, it saves that key's public half at the expected path (needed because the ssh config sets `IdentitiesOnly`). Otherwise it generates a new key and prints the public key to add to GitHub. |
| `gui` | Workstation profile only. Installs `apt-gui.txt` (tilix), VS Code from snap, and a Nerd Font. |
| `vscode` | Workstation profile only. Installs the extensions listed in dotfiles' `vscode-extensions.txt`. VS Code's `settings.json` lives in dotfiles too and is linked by the `dotfiles` step. |

### Adding a tool

Add one line to `packages/apt.txt` (or `apt-gui.txt` for desktop-only apps), then run `make base`.

## Design decisions

- **apt only.** Tools come from Ubuntu's own packages, so they are the versions that Ubuntu release ships.
  - oh-my-posh isn't in apt, so the `shell` step installs it.
  - On Ubuntu, fd's binary is `fdfind`.
- **`stow --no-folding`.** Plain `stow .` links a whole directory when the target directory does not exist yet. On a fresh machine that made `~/.ssh` a symlink into the dotfiles repo, which broke `init.sh` and meant new SSH keys would have been written inside the dotfiles checkout. With `--no-folding`, stow only ever links individual files. The bootstrap also creates `~/.ssh` with mode 700 before stowing.
- **Secrets never go in either repo.** Keys are generated on each machine, and on EC2 you use agent forwarding (`ssh -A`) instead. If more secrets are needed later, pull them at bootstrap time from 1Password CLI (`op`) or AWS SSM Parameter Store.
- **Package lists are plain data**, so adding a tool is a one-line change and needs no code.
- **Two package lists.** `apt-gui.txt` is separate from `apt.txt` so headless servers (EC2) never install desktop apps.
- **bash only.** zsh, powerlevel10k and the zsh plugins were removed; bash is the login shell and oh-my-posh is its prompt.
- **No macOS.** Support was removed to keep one code path. The bootstrap stops with an error on anything other than Ubuntu/Debian.

## Status

- **bash is the login shell.** dotfiles has a `.bash_profile` (login shells such as SSH sessions read it instead of `.bashrc`) and `.bashrc` now has zoxide, the eza `ls` alias and arrow-key history search. Checked on Ubuntu 24.04: a login shell loads `.bashrc` once and all three work.
- **Verified once.** The server profile was run twice on a clean Ubuntu 24.04 container as a non-root sudo user. Both runs succeeded, and the second run changed nothing. eza, zoxide, fzf, rg, fdfind and python3 were all on PATH. (That run predates removing zsh and macOS.)
- **Never run.** The workstation profile.

## Next steps

### denv

- **Linux workstation.** VS Code comes from snap. Check this on a real desktop install.
- **Optional devcontainer.** A `devcontainer.json` that runs `bootstrap.sh --profile server --only base,shell,dotfiles` would give the same shell inside Codespaces or VS Code Dev Containers.
- **Consider chezmoi later.** It is worth switching to if the per-machine differences outgrow the `init.sh` + `.example` approach. Its templates handle per-machine differences natively.
