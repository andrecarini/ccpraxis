## macOS host

- The Bash tool's shell is zsh. A glob that matches nothing aborts the command (`no matches found`), so quote a pattern meant for another program (`find . -name '*.md'`); a word starting with `=` expands to a command's path (`=====` fails), so quote it; an unquoted `$var` is not word-split. Run bash syntax through `bash -c '...'` or a script file.
- `/bin/bash` and `/bin/sh` are bash 3.2: no `declare -A`, `${var,,}`, `read -N`, `mapfile`, `$EPOCHSECONDS` or `globstar`; `"${arr[@]}"` of an empty array is unbound under `set -u`; a heredoc inside `$(...)` with an unbalanced `)` misparses. Hook scripts must work on 3.2.
- The userland is BSD: `sed -i ''`, `stat -f %m` (not `stat -c %Y`), `date -v-1d` and `date -r <epoch>` (not `date -d`), `ps -o etime=` (no `etimes`). There is no `timeout`, `setsid` or `flock`; use perl: `perl -e 'alarm shift; exec @ARGV' 30 cmd` (exit 142 on timeout), `perl -MPOSIX -e 'fork && exit; setsid; exec @ARGV' cmd`, and `flock` from `Fcntl` in a perl script.
- `grep` and `find` in the Bash tool are Claude Code's own wrappers and skip gitignored files. Search gitignored directories (`.ccpraxis-local-data/`, for one) with `command grep -r` and `command find`.
- `/tmp` is `/private/tmp`, `/var` is `/private/var`, and `$TMPDIR` is under `/var/folders/`. `realpath`, `pwd -P` and perl's `abs_path` return the `/private` form: canonicalise both sides before comparing or prefix-matching paths.
- APFS is case-insensitive: `Foo` and `foo` are one file. Compare paths case-insensitively; perl's `Cwd::abs_path` keeps the case you typed.
- Claude Code's credentials are in the login Keychain (item `Claude Code-credentials`), not in `~/.claude/.credentials.json`. Never read the secret (`security find-generic-password -w`): it can raise a GUI prompt and prints the token.
- Never run `pbcopy` or `pbpaste` unasked: they touch the user's clipboard, and even `pbcopy </dev/null` empties it.
- Homebrew is at `/opt/homebrew`. A `brew install` is a host install like any other; the dev-tooling rule above applies.
- A PATH change reaches the Bash tool only in a new Claude Code session, which takes a fresh snapshot of the shell. A line added to `~/.zshrc`, or a `brew install`, is invisible until then.
