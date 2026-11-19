# denv

Bootstraps a dev environment on Ubuntu/Debian: packages, CLI tools, shell, [dotfiles](https://github.com/dtempleman/dotfiles) and VS Code.

```shell
git clone https://github.com/dtempleman/denv.git && cd denv
./bootstrap.sh --identity personal                  # laptop / desktop
./bootstrap.sh --profile server --identity kinsol   # EC2 or other headless box
./bootstrap.sh --help
```

`--identity kinsol|personal` sets the machine's default git name/email and GitHub SSH key, via the dotfiles' `init.sh`. Use `kinsol` on work machines and `personal` on your own. Repos under `~/kinsol` and `~/kemple` always use their own identity, whatever the default.

On a remote box, connect with `ssh -A` first so git uses your local GitHub key. For the design and next steps, see [docs/plan.md](docs/plan.md).
