#!/usr/bin/env bash
# Smoke tests for bin/dotfiles against a throwaway $HOME and a fixture dotfiles repo.
# Usage: test/smoke.sh
set -euo pipefail

CLI_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/dotfiles"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run the CLI under the bash running this test (CI runs /bin/bash 3.2 on macOS), not whatever
# `env bash` finds first on PATH.
CLI="$TMP/dotfiles"
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$BASH" "$CLI_PATH" > "$CLI"
chmod +x "$CLI"

export HOME="$TMP/home"
unset DOTFILES DOTFILES_DIR DOTFILES_REPO
mkdir -p "$HOME"

pass=0
check() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    echo "FAIL: $desc" >&2
    exit 1
  fi
}
fails() { ! "$@"; }

# Fixture repo
REPO="$TMP/repo"
mkdir -p "$REPO/zsh" "$REPO/claude" "$REPO/hooks" "$REPO/work"
echo "# zshrc" > "$REPO/zsh/zshrc"
echo '{"a":1}' > "$REPO/claude/settings.json"
echo "# acme" > "$REPO/work/acme.rc"
echo "Host acme" > "$REPO/work/acme.ssh"
printf '#!/bin/sh\ntouch "$HOME/pre-install-ran"\n' > "$REPO/hooks/pre-install"
printf '#!/bin/sh\ntouch "$HOME/acme-install-ran"\n' > "$REPO/work/acme.install"
chmod +x "$REPO/hooks/pre-install" "$REPO/work/acme.install"
cat > "$REPO/manifest" <<'EOF'
# fixture
link  zsh/zshrc             .zshrc
merge claude/settings.json  .claude/settings.json   # trailing comment
EOF
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q -m init

# Basics
check "bare invocation prints usage" bash -c "'$CLI' | grep -q USAGE"
check "--version" bash -c "'$CLI' --version | grep -q '^v'"
check "unknown command fails" fails "$CLI" nope
check "unknown flag fails" fails "$CLI" install --bogus
check "missing --work value fails" fails "$CLI" install --work
check "repo not found fails" fails "$CLI" dir

# init: needs a repo, expands owner/name shorthand, warns about hooks
check "init without repo fails" fails "$CLI" init -d "$TMP/none"
check "init without repo explains" bash -c "'$CLI' init -d '$TMP/none' 2>&1 | grep -q 'Which repo'"
# GIT_ALLOW_PROTOCOL=file makes git refuse ssh/https instantly, so no network is touched
check "shorthand expands to SSH" bash -c "GIT_ALLOW_PROTOCOL=file '$CLI' init -d '$TMP/x' someone/dots 2>&1 | grep -q 'git@github.com:someone/dots.git'"
check "--https shorthand" bash -c "GIT_ALLOW_PROTOCOL=file '$CLI' init --https -d '$TMP/x' someone/dots 2>&1 | grep -q 'https://github.com/someone/dots.git'"
check "DOTFILES_REPO is the default" bash -c "GIT_ALLOW_PROTOCOL=file DOTFILES_REPO=a/b '$CLI' init -d '$TMP/x' 2>&1 | grep -q 'git@github.com:a/b.git'"
check "init clones a path" "$CLI" init -d "$TMP/clone" "$REPO"
check "clone has manifest" test -f "$TMP/clone/manifest"
check "init warns about hooks" bash -c "rm -rf '$TMP/clone2'; '$CLI' init -d '$TMP/clone2' '$REPO' 2>&1 | grep -q 'hooks/pre-install'"

# init --new scaffolds a repo
check "init --new" "$CLI" init --new -d "$TMP/new"
check "--new wrote manifest" test -f "$TMP/new/manifest"
check "--new made a git repo" test -d "$TMP/new/.git"
check "--new example hook is inert" test ! -x "$TMP/new/hooks/pre-install"
check "--new refuses non-empty dir" fails "$CLI" init --new -d "$TMP/new"
check "--new rejects a repo arg" fails "$CLI" init --new -d "$TMP/new2" some/repo
check "starter manifest parses" env DOTFILES_DIR="$TMP/new" "$CLI" install -n
export DOTFILES_DIR="$TMP/clone"

check "dir prints repo" bash -c "[[ \$('$CLI' dir) == '$TMP/clone' ]]"
check "unknown profile fails" fails "$CLI" install -n -w nope
check "bad profile name fails" fails "$CLI" install -n -w '../x'

# Dry run changes nothing and doesn't run hooks
echo "old" > "$HOME/.zshrc"
check "dry run" "$CLI" install -n -w acme
check "dry run left .zshrc alone" test ! -L "$HOME/.zshrc"
check "dry run skipped hooks" test ! -e "$HOME/pre-install-ran"

# Real install
check "install" "$CLI" install -w acme
check ".zshrc linked" test "$(readlink "$HOME/.zshrc")" = "$TMP/clone/zsh/zshrc"
check "old .zshrc backed up" bash -c "grep -q old '$HOME'/.dotfiles-backup/*/.zshrc"
check "json created" test -f "$HOME/.claude/settings.json"
check "work rc linked" test -L "$HOME/.config/dotfiles/work.d/acme.rc"
check "work ssh linked" test -L "$HOME/.ssh/config.d/acme"
check "pre-install hook ran" test -e "$HOME/pre-install-ran"
check "work install hook ran" test -e "$HOME/acme-install-ran"
check "repo recorded" test "$(cat "$HOME/.config/dotfiles/repo")" = "$TMP/clone"

# Recorded path is used when no env var points at the repo
check "dir via recorded path" env -u DOTFILES_DIR bash -c "[[ \$('$CLI' dir) == '$TMP/clone' ]]"

# JSON merge keeps local keys
if command -v jq >/dev/null; then
  echo '{"local":true}' > "$HOME/.claude/settings.json"
  check "re-install" "$CLI" install
  check "json merged" jq -e '.a == 1 and .local == true' "$HOME/.claude/settings.json"
fi

# update re-applies installed profiles
rm "$HOME/acme-install-ran"
check "update" "$CLI" update
check "update re-ran work hook" test -e "$HOME/acme-install-ran"

# bootstrap runs only the steps the repo asks for. Fake system tools record their calls.
FAKE="$TMP/fakebin"
CALLS="$TMP/calls"
mkdir -p "$FAKE"
for tool in brew sudo apt-get chsh mise zsh; do
  printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$tool" "$CALLS" > "$FAKE/$tool"
  chmod +x "$FAKE/$tool"
done
bootstrap() { : > "$CALLS"; PATH="$FAKE:$PATH" SHELL=/bin/bash "$CLI" bootstrap "$@"; }
called() { grep -q "^$1" "$CALLS"; }

check "bare bootstrap" bootstrap
check "  no brew without a Brewfile" fails called brew
check "  no apt without an Aptfile" fails called sudo
check "  no mise without a mise config" fails called mise
if [[ $(uname -s) == Linux ]]; then
  check "  chsh because .zshrc is linked" called "chsh -s"
fi

echo 'brew "jq"' > "$TMP/clone/Brewfile"
echo "zsh git  # comment" > "$TMP/clone/Aptfile"
echo "link zsh/zshrc .config/mise/config.toml" >> "$TMP/clone/manifest"
check "full bootstrap" bootstrap
check "  brew bundle" called "brew bundle --file=$TMP/clone/Brewfile"
check "  mise install" called "mise install"
if [[ $(uname -s) == Linux ]]; then
  check "  apt install from Aptfile" called "sudo apt-get install -y zsh git"
  echo 'zsh; rm -rf /' > "$TMP/clone/Aptfile"
  check "  rejects shell syntax in Aptfile" fails bootstrap
fi
rm -f "$TMP/clone/Brewfile" "$TMP/clone/Aptfile"

# Manifest validation: nothing changes when a line is bad
for bad in "link zsh/zshrc /etc/passwd" "link ../x .x" "link zsh/zshrc ../.x" \
           "link zsh/zshrc ~/.x" "bogus a b" "link onlyone" "link a b c"; do
  echo "$bad" > "$TMP/clone/manifest"
  check "rejects manifest line: $bad" fails "$CLI" install
done

echo "ok: $pass checks passed (bash $BASH_VERSION)"
