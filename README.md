# dotfiles-cli

`dotfiles`: set up a machine from a dotfiles repo and keep it linked. macOS, WSL and Linux.

The tool is generic and holds no config. What it links lives in your dotfiles repo, which can stay
private: `dotfiles init` clones it with your own git credentials. No repo yet? `dotfiles init --new`
creates a starter one.

## Quick start

```sh
brew install joeygrasso/joeygrasso/dotfiles

# Existing repo (GitHub shorthand clones over SSH; add --https for a public repo without SSH keys)
dotfiles init you/dotfiles
dotfiles bootstrap

# Or start one
dotfiles init --new                 # ~/repos/dotfiles with a commented starter manifest
# move files in, add manifest lines, then:
dotfiles install -n                 # preview
dotfiles install
```

## Install

```sh
brew install joeygrasso/joeygrasso/dotfiles
```

Or run it from a clone, e.g. on a fresh machine before Homebrew exists:

```sh
git clone https://github.com/joeygrasso/dotfiles-cli.git
dotfiles-cli/bin/dotfiles --help
```

## Usage

```sh
dotfiles init [-d DIR] [--https] <repo>   # clone a repo: URL, path, or owner/name on GitHub
dotfiles init --new [-d DIR]      # create a starter repo
dotfiles bootstrap [-w NAME]      # set up the machine from whatever the repo contains
dotfiles install [-n] [-w NAME]   # link only; -n is a dry run
dotfiles update [-n]              # git pull --ff-only, then re-link
dotfiles plugins                  # clone the manifest's `clone` entries
dotfiles dir                      # print the repo path
```

`init` has no built-in repo; set `$DOTFILES_REPO` to skip typing it. Repos go to `$DOTFILES_DIR`,
else `~/repos/dotfiles`. Other commands find the repo via `$DOTFILES_DIR`, `$DOTFILES`, the path recorded by the last
`install` (`~/.config/dotfiles/repo`), then `~/repos/dotfiles`.

Files that would be replaced are moved to `~/.dotfiles-backup/<timestamp>/`, never overwritten.

## Examples

**Adopt an existing machine.** Your repo is already cloned, just not at `~/repos/dotfiles`:

```sh
export DOTFILES_DIR=~/code/dotfiles   # only needed until the first install records the path
dotfiles install -n                   # preview links, backups and hooks; changes nothing
dotfiles install
dotfiles dir                          # now finds the repo without DOTFILES_DIR
```

Anything `install` replaces is moved to `~/.dotfiles-backup/<timestamp>/`. Diff the backups against
the linked versions if you want to keep a machine-specific setting, e.g. in a local include file your
config sources (`~/.gitconfig.local`, `~/.zshrc.local`).

**New machine, full setup:**

```sh
dotfiles init you/dotfiles            # owner/name clones over SSH; --https for public repos
dotfiles bootstrap                    # Aptfile, Brewfiles, plugins, links, mise, login shell
dotfiles bootstrap --work acme        # same, plus work/acme.* and work/Brewfile.acme
```

**Links only, or plugins only:**

```sh
dotfiles install                      # just the manifest's link/merge lines (+ hooks)
dotfiles plugins                      # just the manifest's clone lines
```

**Keep machines in sync:**

```sh
dotfiles update -n                    # pull, then preview the re-link
dotfiles update                       # pull and re-link, re-applying installed work profiles
cd "$(dotfiles dir)"                  # edit, commit, push from the checkout
```

**Try someone else's repo safely:**

```sh
dotfiles init -d /tmp/their-dots them/dotfiles   # init lists any hooks it found
DOTFILES_DIR=/tmp/their-dots dotfiles install -n # see what would change; runs no repo code
```

## The dotfiles repo

A dotfiles repo is any directory with a `manifest` at its root:

```
# comment
link   zsh/zshrc             .zshrc                    # symlink ~/.zshrc -> <repo>/zsh/zshrc
merge  claude/settings.json  .claude/settings.json     # deep-merge JSON (needs jq), keeps local keys
clone  https://github.com/ohmyzsh/ohmyzsh.git  .oh-my-zsh   # shallow clone if missing
```

Sources are relative to the repo, destinations relative to `$HOME`. Absolute paths, `~` and `..`
are rejected, and the whole manifest is checked before anything changes.

Optional, by convention:

| Path | Used by |
|---|---|
| `Aptfile`, `Aptfile.wsl` | `bootstrap` on Linux/WSL: `sudo apt-get install` (package names only; `.wsl` only on WSL) |
| `Brewfile`, `Brewfile.macos` | `bootstrap`: installs Homebrew if needed, then `brew bundle` (`.macos` only on macOS) |
| `hooks/pre-install`, `hooks/post-install` | run by `install`, `update` and `bootstrap` around linking |
| `work/<name>.rc` | `--work <name>`: linked to `~/.config/dotfiles/work.d/<name>.rc` for your shell to source |
| `work/<name>.ssh` | linked to `~/.ssh/config.d/<name>` |
| `work/<name>.install` | run after linking the profile, e.g. to fetch secrets from a password manager |
| `work/Brewfile.<name>` | `bootstrap --work <name>` |

`update` re-applies every profile found in `~/.config/dotfiles/work.d/`.

`bootstrap` only does what the repo asks for: no Aptfile means no apt, no Brewfile means no Homebrew,
`mise install` runs only if the manifest links a mise config (`.config/mise/*`, `.mise.toml`,
`.tool-versions`), and on Linux/WSL the login shell becomes zsh only if the manifest links `.zshrc`.

## Security model

- The CLI contains no hosts, credentials or personal config; keep those in your (private) dotfiles repo.
- Hooks and `work/*.install` are executables from your dotfiles repo and run as you. Treat push access
  to that repo like shell access to your machines.
- `init` lists a cloned repo's hooks with a warning. Hooks don't run on a dry run (`-n`); they are
  listed instead, so `dotfiles install -n` is a safe first look at someone else's repo.
- `bootstrap` runs the official Homebrew installer only when the repo has a Brewfile, and
  `sudo apt-get install` only with an Aptfile, whose entries must be plain package names.

## Development

`bin/dotfiles` must stay compatible with bash 3.2 (stock macOS): no associative arrays, `mapfile`,
`${var,,}`, or empty arrays under `set -u`. `test/smoke.sh` runs against a temporary `$HOME` with
fake `brew`/`sudo`/`apt-get`/`chsh`/`mise`, so it never changes the machine; CI runs it on Ubuntu and
macOS (`/bin/bash` 3.2) plus shellcheck.

Release: bump `VERSION` in `bin/dotfiles`, tag `vX.Y.Z`, then update `url` and `sha256` in
`dotfiles.rb` in the tap.
