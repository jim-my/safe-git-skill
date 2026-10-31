# shellcheck shell=bash
# gitenv.sh — shell single source of truth for scrubbing ambient git env vars
# (#1687, generalizing #1656; python twin: agent-skills/bin/gitenv.py).
#
# agent-skills shell helpers scope git with `git -C "$REPO_ROOT"` (or a
# `rev-parse --show-toplevel` bootstrap). Ambient git env vars — leaked by a git
# hook's temporary-index context or a caller that exports them — OVERRIDE that
# explicit scoping and silently resolve every git call against a DIFFERENT
# repository (#1656 proved this live). `scrub_git_env` unsets them in the current
# shell so `-C "$REPO_ROOT"` (or cwd) is always authoritative. Source this once
# and call `scrub_git_env` before the first git invocation.
#
# Leak-var set matches gitenv.py: Git's `rev-parse --local-env-vars` contract,
# plus discovery/namespace variables that can redirect an explicit repository
# operation. No agent-skills helper legitimately consumes ambient repo-local
# overrides.
#
# Sourcing: every consumer reaches this one file by a path relative to its own
# resolved directory — do not enumerate the shapes here, since each new consumer
# depth would silently falsify the list (#1721 added three at a new depth).
# The rule: resolve YOUR OWN directory first, then walk to
# agent-skills/g-review/scripts/lib/gitenv.sh. Examples, not an inventory —
# each cites a consumer that actually uses that shape:
#   g-review/scripts/*:  . "$SCRIPT_DIR/lib/gitenv.sh"                    (review-with-model)
#   bin/*             :  . "$SCRIPT_DIR/../g-review/scripts/lib/gitenv.sh" (g-review-wrapper)
#
# One exception: safe-git/lib/gitenv.sh is a byte copy, so safe-git runs from a plain
# copy of its directory. test/gitenv_sweep_test.sh fails if the two differ.
#
# Resolve the directory the way YOUR entry point is actually reached. A consumer
# invoked through an install symlink (safe-git, via ~/.local/bin) must walk the
# symlink chain first — `dirname "${BASH_SOURCE[0]}"` yields the install dir there
# and would miss this file.
#
# Two entry points, and they have different call contracts:
#   scrub_git_env       — call once before the first git invocation. Unsets in
#                         the CURRENT shell (see the caveat on default_repo_root).
#   default_repo_root   — self-contained; scrubs inside its own subshell, so a
#                         consumer that only needs a root does NOT have to call
#                         scrub_git_env first.

_GIT_ENV_LEAK_VARS=(
  GIT_ALTERNATE_OBJECT_DIRECTORIES
  GIT_CONFIG
  GIT_CONFIG_PARAMETERS
  GIT_CONFIG_COUNT
  GIT_OBJECT_DIRECTORY
  GIT_DIR
  GIT_WORK_TREE
  GIT_IMPLICIT_WORK_TREE
  GIT_GRAFT_FILE
  GIT_INDEX_FILE
  GIT_NO_REPLACE_OBJECTS
  GIT_REPLACE_REF_BASE
  GIT_PREFIX
  GIT_SHALLOW_FILE
  GIT_COMMON_DIR
  GIT_CEILING_DIRECTORIES
  GIT_DISCOVERY_ACROSS_FILESYSTEM
  GIT_NAMESPACE
)

# Unset every git repo-override env var in the current shell so a later
# `git -C <repo>` cannot be redirected by inherited git env. `unset` of an
# already-unset name is a no-op even under `set -u`.
scrub_git_env() {
  unset "${_GIT_ENV_LEAK_VARS[@]}"
}

# The checkout the calling script's own FILE lives in. Exposed so a helper that
# must NOT follow CWD (see skill-harness-run) can say so explicitly rather than
# hand-rolling the derivation gitenv_sweep_test.sh forbids outside this module.
# Symlink hops before `script_repo_root` gives up. Named rather than a bare 40 in
# the loop condition so the refusal message below can quote the same number.
_GITENV_SYMLINK_HOPS=40

script_repo_root() {
  # Plain error text: an escaped quote or a nested ${...} inside a ${1:?msg}
  # message makes bash mis-parse where the expansion ends and leaves the message's
  # own trailing characters IN the value (caught live — the value came back as
  # `<path>"}`). Harmless under the old dirname-only walk, since
  # `dirname '<dir>/f"}'` == `dirname '<dir>/f'`; it matters now because the
  # corrupted value fails the `[ -L ]` test below, so the chain is never walked and
  # this fix would be inert.
  local script_file="${1:?script_repo_root: pass BASH_SOURCE[0]}" src target hops=0
  # Resolve the FILE through its symlink chain. `pwd -P` below already resolves
  # DIRECTORY symlinks but never the final component, so a helper reached through
  # an install symlink outside the checkout (skillbin, ~/.local/bin) carries the
  # install path in ${BASH_SOURCE[0]} and the dirname walk goes up from the install
  # dir — measured `/tmp` for a fixture under /tmp/<x>/installbin. python's
  # Path(...).resolve() already followed the chain; this owner and gitenv.rb did not.
  #
  # Plain `readlink` in a loop, NEVER `readlink -f`: `-f` is a GNU extension absent
  # on macOS/BSD, which this repo supports (`just bootstrap-macos-prereqs`), and its
  # absence degrades SILENTLY back to the install-dir root. Same idiom and the same
  # reason as bin/skillbin and safe-git/bin/safe-git — the latter names this exact
  # failure, and safe-git SOURCES this file, so it ships on this very path.
  # `hops` bounds a symlink cycle: this is a library on a guard path, and a hang is
  # not a better failure than a fallback.
  src="$script_file"
  while command -v readlink >/dev/null 2>&1 && [ -L "$src" ] && [ "$hops" -lt "$_GITENV_SYMLINK_HOPS" ]; do
    hops=$((hops + 1))
    # Check readlink's STATUS, not just its output. A nonzero exit with empty stdout
    # left `target` empty, the relative arm below then built `<dir-of-src>/` with
    # nothing appended, the loop exited because that path is no longer a symlink, and
    # the function returned `<dir>/../..` at rc=0 with no diagnostic. Distinct from
    # the hop-cap branch below: that one handles a cycle, this one a readlink that
    # simply failed. Reproduced with a stubbed failing readlink returning `/`.
    if ! target="$(readlink "$src" 2>/dev/null)" || [ -z "$target" ]; then
      printf 'gitenv: refusing to derive a repo root — readlink failed on %s\n' "$src" >&2
      return 1
    fi
    case "$target" in
      /*) src="$target" ;;
      *)  src="$(cd "$(dirname "$src")" 2>/dev/null && pwd)/$target" ;;
    esac
  done
  # Hitting the cap while still ON a symlink means the chain was never resolved, so
  # `$src` is an intermediate link, not the real file. Deriving `<src>/../..` from it
  # returns a WRONG ROOT at rc=0 with no diagnostic — this owner failing open on its
  # own cycle guard, while the python owner raises. A guard that reports success
  # with the wrong answer is worse than one that hangs, which is what the cap exists
  # to prevent.
  if [ -L "$src" ]; then
    printf 'gitenv: refusing to derive a repo root from an unresolved symlink chain (>%s hops): %s\n' \
      "$_GITENV_SYMLINK_HOPS" "$script_file" >&2
    return 1
  fi
  (cd "$(dirname "$src")/../.." && pwd -P)
}

# Repo trust is decided by the SCRIPT'S OWN checkout, never by anything the
# untrusted directory says about itself (twin of gitenv.py's note). Two earlier
# designs were forged in review: a content marker (`mkdir -p agent-skills/bin`) and
# `git -C <cwd> rev-parse --git-common-dir` (a planted `.git/commondir` echoes the
# trusted path back). The worktree registry below is read from the trusted side.
#
# Records are NUL-delimited (`-z`) and parsed as records, not lines: a registered
# worktree whose path contains a newline must still match, and `prunable` entries
# (a worktree whose directory was moved or deleted) are skipped — git stops
# reporting `prunable` once any repo occupies the vacated path, so a stale entry
# would otherwise re-grant trust to whatever now sits there.
_trusted_checkouts() {
  local script_root="${1:?_trusted_checkouts: pass the script root}"
  local field path prunable git_rc i
  # Plain indexed array + index arithmetic. `mapfile`/`readarray` are bash 4+ and
  # `-d ''` is 4.4+, and `${arr[-1]}` is 4+ — the first version of this gate used
  # both, so on macOS's stock bash 3.2 it produced NO records at all and every
  # helper silently fell back to the script's own checkout. That is #1827's
  # original bug, reintroduced on a platform this repo supports
  # (`just bootstrap-macos-prereqs`), by the change meant to harden this function.
  local records=()
  path=""; prunable=0; git_rc=1
  # Records are emitted ONLY when git exited 0. gitenv.py refuses the whole set on
  # `proc.returncode != 0` before trusting a record; this owner had no equivalent
  # gate, so a git that printed a matching record and then FAILED still granted
  # trust here while python and ruby refused it.
  #
  # `$( )` strips the NULs this parse depends on and a process substitution reports
  # no status, so git's status is appended as one extra NUL-delimited field behind a
  # sentinel. Records are BUFFERED rather than printed as they are parsed, because
  # the status arrives last and a record already written cannot be retracted.
  #
  # Pure bash throughout: no cat/head/mktemp, so this owner keeps working on a
  # minimal PATH.
  while IFS= read -r -d '' field; do
    case "$field" in
      "__gitenv_rc__"*)
        git_rc="${field#__gitenv_rc__}"
        ;;
      "")
        if [ -n "$path" ] && [ "$prunable" = 0 ]; then
          records[${#records[@]}]="$path"
        fi
        path=""; prunable=0
        ;;
      "worktree "*) path="${field#worktree }" ;;
      prunable*)    prunable=1 ;;
    esac
  done < <(scrub_git_env
           LC_ALL=C git -C "$script_root" worktree list --porcelain -z 2>/dev/null
           printf '\0__gitenv_rc__%s\0' "$?")
  # Flush a trailing record that arrived without its separator.
  if [ -n "$path" ] && [ "$prunable" = 0 ]; then
    records[${#records[@]}]="$path"
  fi
  [ "$git_rc" = 0 ] || return 1
  i=0
  while [ "$i" -lt "${#records[@]}" ]; do
    printf '%s\0' "${records[$i]}"
    i=$((i + 1))
  done
}

# Absolute --git-common-dir for the repo at $1, else empty. Read FROM the
# candidate, so not trustworthy alone (a planted .git/commondir forges it); used
# only as the second half of the AND in default_repo_root.
_git_common_dir() {
  (scrub_git_env; LC_ALL=C git -C "${1:?}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
}

# True when $1 is a live LINKED worktree of the repo whose common dir is $2. A
# genuine linked worktree's .git is a FILE containing `gitdir: <common>/worktrees/<n>`;
# a repo created at a vacated but still-registered path has a .git DIRECTORY.
_is_live_linked_worktree() {
  local candidate="${1:?}" common="${2:?}" target worktrees
  [ -f "$candidate/.git" ] || return 1
  target="$(sed -n 's/^gitdir:[[:space:]]*//p' "$candidate/.git" 2>/dev/null | head -n 1)"
  [ -n "$target" ] || return 1
  # A relocatable worktree may record a RELATIVE gitdir, relative to the worktree
  # directory rather than this process's CWD.
  case "$target" in /*) ;; *) target="$candidate/$target" ;; esac
  target="$(cd "$target" 2>/dev/null && pwd -P || true)"
  worktrees="$(cd "$common/worktrees" 2>/dev/null && pwd -P || true)"
  [ -n "$target" ] && [ -n "$worktrees" ] || return 1
  case "$target/" in "$worktrees"/*) ;; *) [ "$target" = "$worktrees" ] || return 1 ;; esac
  # "Under worktrees/" is not enough: a squatter can point at a DIFFERENT, real
  # worktree's admin dir and inherit its validity. Require the admin dir's own
  # backpointer — trusted-side data — to name THIS candidate.
  # `recorded=""` is load-bearing: when the redirection below FAILS (absent or
  # unreadable gitdir) `read` never runs, so an uninitialized local stays UNSET
  # and the `${recorded%...}` on the next line dies under `set -u` with
  # "unbound variable" — aborting all nine `set -u` consumers BEFORE the
  # fail-closed `[ -n "$recorded" ] || return 1` arm can run. Reproduced: an admin
  # dir with commondir but no gitdir made this abort where py and rb both return
  # false. Do NOT move the default onto the read as `|| recorded=""`: `read -d ''`
  # returns nonzero at EOF on a SUCCESSFUL whole-file read, so that wipes the value.
  local recorded="" resolved_recorded resolved_dotgit
  # Read with the shell's own redirection and split with parameter expansion: no
  # cat/head/dirname/basename, so the owner keeps working on a minimal PATH (the
  # no-python3 fixture caught a basename dependency here).
  # `read -r -d ''` reads to NUL, i.e. the whole file, so an internal newline in a
  # worktree path survives — plain `read -r` stops at the first newline and
  # truncated the backpointer exactly as ruby's `lines.first` did. It returns
  # nonzero at EOF while still setting the variable, hence the `|| true`. Still no
  # cat/head, so the owner keeps working on a minimal PATH.
  IFS= read -r -d '' recorded < "$target/gitdir" 2>/dev/null || true
  # Remove git's terminating newline. NOT exact parity with py/rb: the
  # `$( )` on the resolved_recorded line below strips ALL trailing newlines, so
  # bash accepts a backpointer with two or more where py and rb reject it.
  # Harmless (writing that file already requires trusted-side access, which is
  # this check's premise) but do not read the line below as byte-exact parity.
  recorded="${recorded%$'\n'}"
  [ -n "$recorded" ] || return 1
  # The backpointer may be RELATIVE, and it is relative to the ADMIN DIR.
  case "$recorded" in /*) ;; *) recorded="$target/$recorded" ;; esac
  resolved_recorded="$(cd "${recorded%/*}" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "${recorded##*/}" || true)"
  resolved_dotgit="$(cd "$candidate" 2>/dev/null && printf '%s/.git' "$(pwd -P)" || true)"
  [ -n "$resolved_recorded" ] && [ "$resolved_recorded" = "$resolved_dotgit" ]
}

# Default audit root for a helper the caller gave no --root (#1827). Prefers the
# checkout containing CWD, so a bare run from a ticket worktree audits that
# worktree instead of the main checkout that $AGENT_SKILLS_BIN / skillbin resolve
# the helper's FILE to. See gitenv.py's DEFAULT AUDIT ROOT block for the
# tracked-vs-untracked discriminator.
#
# $1 = the calling script's own path (pass "${BASH_SOURCE[0]}").
#
# The scrub runs inside this function's command substitution, NOT in the caller's
# shell: `scrub_git_env` unsets globally, and skill-harness-run cds to the root
# and then execs arbitrary manifest steps (claude/install.sh, claude/hooks/*.sh)
# that are not agent-skills helpers and must keep the caller's environment.
default_repo_root() {
  local script_root cwd_root listed
  # DELEGATE, never re-derive. This hand-rolled a second copy of the script-root
  # walk — same file, 88 lines below the owner — so the symlink-chain fix landed in
  # `script_repo_root` and left this one with the old dirname walk AND the old
  # broken `${1:?}` message, while gitenv.py and gitenv.rb both delegate and
  # inherited it. Two live bash consumers (bin/pyspark-behavior-harness,
  # bin/skill-token-usage) reach the root through here, so the duplicate was the
  # one that mattered. One derivation per language is execution contract 1 of
  # #1827's plan; a second copy in the same file is how that contract broke.
  script_root="$(script_repo_root "${1:?default_repo_root: pass BASH_SOURCE[0]}")"
  cwd_root="$(scrub_git_env; LC_ALL=C git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cwd_root" ]; then
    cwd_root="$(cd "$cwd_root" 2>/dev/null && pwd -P || true)"
    if [ -n "$cwd_root" ]; then
      while IFS= read -r -d '' listed; do
        [ -n "$listed" ] || continue
        # A registered path ending in a NEWLINE cannot be compared safely in this
        # owner, so it is never trusted. `$( )` strips ALL trailing newlines, and
        # `cwd_root` above was captured that way, so a worktree registered at
        # `/tmp/alias<LF>` collapsed onto its UNREGISTERED sibling `/tmp/alias`:
        # planting that sibling with a `.git` file pointing at the registered
        # worktree's admin dir made this owner return the PLANTED path as the audit
        # root, while gitenv.py and gitenv.rb both correctly fell back to the
        # script root. Reproduced against all three owners (#1827).
        #
        # Skipping is the fail-closed direction and matches what
        # warn_if_cwd_outside's comment already claims for this limitation: the
        # cost is that this owner cannot AUDIT a newline-named worktree (it falls
        # back to the script root), never that it trusts the wrong tree. Byte-exact
        # parity with py/rb needs NUL-terminated capture throughout and is filed on
        # #1860 — do not read this skip as parity.
        case "$listed" in
          *$'\n') continue ;;
        esac
        listed="$(cd "$listed" 2>/dev/null && pwd -P || true)"
        if [ -n "$listed" ] && [ "$listed" = "$cwd_root" ]; then
          # BOTH checks: registry membership alone trusts a foreign repo squatting
          # a stale registered path; object-store agreement alone is forgeable via
          # a planted .git/commondir. Each was defeated in review on its own.
          local cwd_common script_common main_root
          cwd_common="$(_git_common_dir "$cwd_root")"
          script_common="$(_git_common_dir "$script_root")"
          if [ -n "$script_common" ] && [ "$cwd_common" = "$script_common" ]; then
            # The main checkout is <common>/.. and legitimately has a .git DIRECTORY;
            # anything else must be a live LINKED worktree, which rejects a repo
            # squatting a stale registered path.
            main_root="$(cd "$script_common/.." 2>/dev/null && pwd -P || true)"
            if [ "$cwd_root" = "$main_root" ] || _is_live_linked_worktree "$cwd_root" "$script_common"; then
              printf '%s\n' "$cwd_root"
              return 0
            fi
          fi
          break
        fi
      done < <(_trusted_checkouts "$script_root")
    fi
  fi
  printf '%s\n' "$script_root"
}

# Announce on stderr when the EFFECTIVE root is not the tree the operator is in.
# Call after option parsing, with the root actually being used. Returns 0 when it
# warned, 1 when silent, so a test can assert both arms.
warn_if_cwd_outside() {
  local root="${1:-}" cwd cwd_root resolved_root
  # An empty or unusable root, or an unreadable CWD, is UNDETERMINED — announce it
  # rather than returning silently, which would contradict this function's own
  # invariant two lines down and reproduce the pass-on-doubt hole (#1827 round 12).
  if [ -z "$root" ]; then
    printf 'warning: no audit root resolved — pass this helper'\''s explicit target option\n' >&2
    return 0
  fi
  resolved_root="$(cd "$root" 2>/dev/null && pwd -P || true)"
  if [ -z "$resolved_root" ]; then
    printf 'warning: audit root %s could not be resolved — pass this helper'\''s explicit target option\n' "$root" >&2
    return 0
  fi
  root="$resolved_root"
  if ! cwd="$(pwd -P 2>/dev/null)" || [ -z "$cwd" ]; then
    printf 'warning: auditing %s, but the current directory could not be resolved\n' "$root" >&2
    return 0
  fi
  # Compare CHECKOUTS, not filesystem ancestry: this repo keeps worktrees UNDER
  # the main checkout, so an ancestry test stayed silent on exactly the wrong-tree
  # fallback this warning exists to announce (#1827 final review).
  # Silent ONLY on a positive determination (the checkout containing CWD resolved
  # AND equals the audited root). git missing, a failed probe, or CWD in no
  # checkout are all UNDETERMINED, and undetermined must not read as "inside".
  #
  # Known bash-owner limitation: `$(...)` strips ALL trailing newlines, so a
  # worktree path that itself ends in a newline byte cannot round-trip here. The
  # python and ruby owners preserve it; this one degrades to a warning, which is
  # the safe direction.
  cwd_root="$(scrub_git_env; LC_ALL=C git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$cwd_root" ]; then
    cwd_root="$(cd "$cwd_root" 2>/dev/null && pwd -P || true)"
    [ "$cwd_root" != "$root" ] || return 1
  fi
  printf 'warning: auditing %s, but you are in %s — pass this helper'\''s explicit target option to choose deliberately\n' \
    "$root" "$cwd" >&2
  return 0
}
