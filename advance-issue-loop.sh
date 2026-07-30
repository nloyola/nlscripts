#!/usr/bin/env bash
# Run one fresh `claude -p` session per unchecked step of a GitHub issue, driving
# the advance-issue-step skill, until no unchecked steps remain.
#
#   advance-issue-loop.sh [--here] <issue-number> [max-sessions] [branch] [effort]
#
# Every session runs at the same reasoning effort, defaulting to medium. Pass
# one of low, medium, high, xhigh, or max to raise or lower it for a whole run.
#
# Stops early if a session produces no commit or fails to tick its checkbox,
# so a confused session cannot cascade into the following steps.
#
# Every issue gets its own branch. Starting an issue creates one, named from the
# issue title unless a name is given; resuming an issue whose branch already
# exists switches to it rather than starting over.
#
# Starting an issue requires a clean tree, the default branch checked out, and
# every blocking issue closed. Refusing to stack a new issue on unmerged work is
# the point: dependencies are satisfied by merging them, not by branching off
# them, so the base a step is written against is the base it will be merged to.
# Resuming an existing issue branch skips these checks.
#
# `--here` works the issue on the branch already checked out, whatever it is
# named, and skips those start-of-issue checks the same way resuming does. Use it
# when the work belongs on a branch that is already going - a scratch branch, or
# an issue whose steps continue work not yet merged. It is the one way to run an
# issue from a dirty tree, so the uncommitted changes are yours to account for:
# the first step that commits will sweep up anything it happens to touch.
#
# Each session streams a line per tool call as it works, so the terminal shows
# what the step is doing while it does it rather than only once it ends. Needs
# jq; without it the loop still runs, just quietly.
#
# Running it in herdr
# -------------------
#
# Open a pane and type the command. There is nothing to set up:
#
#   advance-issue-loop.sh 54
#
# The one rule is the pane. Give the loop a pane of its own and do not run it
# from inside an agent's conversation, because the point of the loop is that
# every step gets a fresh session, and an agent that drives it carries every
# step's context in its own window - the thing the loop exists to avoid.
#
# The pane reports itself to herdr's sidebar as it goes: working while a session
# runs, done when every step is finished, blocked on an early stop. It has to say
# so explicitly, because herdr infers a working agent from the OSC title the
# claude TUI sets, and the sessions here are headless `claude -p` with no TUI and
# no title. Without the reporting the pane sits at idle for the whole run and an
# hour of work looks like an asleep pane.
#
# Driving it from an agent, or from a script
# -----------------------------------------
#
# Everything below is for a caller with no keyboard, which can only address a
# pane by id. If you are typing, ignore it: $here and $pane are scratch shell
# variables belonging to these examples, and the script itself reads nothing but
# NTFY_TOPIC and NTFY_URL.
#
# Split a pane and start the loop in it. `pane split` prints the id of the pane
# it created at .result.pane.pane_id, so capture that rather than typing an id:
# herdr's ids compact when panes close, so an id from an earlier layout can
# belong to a different pane later. `herdr pane list` is the way back to current
# ones.
#
#   here=$(herdr pane list | jq -r '.result.panes[] | select(.focused) | .pane_id')
#   pane=$(herdr pane split "$here" --direction right --no-focus |
#            jq -r '.result.pane.pane_id')
#   herdr pane run "$pane" "advance-issue-loop.sh 54"
#
# $pane is what every command below wants. For the split output
#
#   {"id":"cli:pane:split","result":{"pane":{...,"pane_id":"w1J:p4",...}}}
#
# it is w1J:p4 - the pane_id inside result.pane, not the tab_id, terminal_id, or
# workspace_id alongside it.
#
# Then watch the pane without sitting on it. These are the lines worth waiting
# for - every one of them is printed by this script, so they are stable:
#
#   herdr wait output "$pane" --match '==> session [0-9]+ done' --regex --timeout 3600000
#   herdr wait output "$pane" --match '==> no unchecked steps left' --timeout 86400000
#   herdr pane read  "$pane" --source recent --lines 40
#
# Timeouts are milliseconds, and a step can take an hour, so size them for the
# work rather than the default. `wait output` matches future output only, so
# start the wait before the step you mean to catch, and use `pane read` for what
# has already scrolled past.
#
# Every early stop prints a line starting with `!!` and notifies ntfy, so a
# `wait` that times out means slow, not dead - check `pane read` before assuming
# the run is gone.
#
# Push notifications go to ntfy as each step lands, when every step is done, and
# on any early stop. Every abnormal exit notifies, so silence means the loop is
# still working rather than dead.
#
# The topic comes from the first of these that is set:
#
#   1. NTFY_TOPIC in the environment
#   2. NTFY_TOPIC in the repository's .env      <- gitignored, per-project
#   3. the first line of ~/.config/ntfy/topic
#
# A run with no topic anywhere refuses to start. It is looked up fresh on every
# notification even so, so it can be repointed mid-run.
#
# NTFY_URL, from the environment or .env, overrides the server (default
# https://ntfy.sh).
#
# An ntfy.sh topic is a shared secret: anyone who knows it can read and post to
# it. Keep it in .env, never in a committed file, and pick an unguessable name.

set -uo pipefail

usage() {
  cat <<'EOF'
Run one fresh `claude -p` session per unchecked step of a GitHub issue, driving
the advance-issue-step skill, until no unchecked steps remain.

usage: advance-issue-loop.sh [--here] <issue-number> [max-sessions] [branch] [effort]
       advance-issue-loop.sh -h | --help

Options:
  --here         Work the issue on the currently checked-out branch instead of
                 cutting a new one, and skip the start-of-issue checks: a clean
                 tree, the default branch as the base, and closed blockers.
                 Refuses on a detached HEAD or on the default branch itself,
                 and cannot be combined with an explicit branch argument.

Arguments:
  issue-number   GitHub issue to work through, in the current repository.
  max-sessions   Cap on sessions before the loop gives up (default 20).
  branch         Branch to work on. Defaults to the existing
                 feat/issue-<n>-* branch if there is one, otherwise a new
                 branch named from the issue title. Pass "" to keep the
                 default while setting the effort.
  effort         Reasoning effort for every session: low, medium, high,
                 xhigh, or max (default medium).

Environment:
  NTFY_TOPIC     ntfy topic for step, completion, and early-stop notifications.
                 Falls back to NTFY_TOPIC in the repository's .env, then to the
                 first line of ~/.config/ntfy/topic. Required: with no topic
                 from any of the three the loop refuses to start.
  NTFY_URL       ntfy server, from the environment or .env (default
                 https://ntfy.sh).

Examples:
  advance-issue-loop.sh 54
  advance-issue-loop.sh --here 54
  advance-issue-loop.sh 54 5
  advance-issue-loop.sh 54 20 "" high
  advance-issue-loop.sh 54 20 feat/issue-54-cutover max
EOF
}

# Options are pulled out wherever they appear, so `--here 54` and `54 --here`
# both work and the positional slots keep their meaning either way.
here=false
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --here | --current-branch)
      here=true
      ;;
    --)
      shift
      while [ $# -gt 0 ]; do
        args+=("$1")
        shift
      done
      break
      ;;
    -*)
      echo "!! unknown option '$1'" >&2
      echo "   see: advance-issue-loop.sh --help" >&2
      exit 1
      ;;
    *)
      args+=("$1")
      ;;
  esac
  shift
done

if [ "${#args[@]}" -eq 0 ]; then
  usage >&2
  exit 1
fi

issue="${args[0]}"
max="${args[1]:-20}"
branch_arg="${args[2]:-}"
effort="${args[3]:-medium}"

# --here names the branch by pointing at it; a second name would contradict it.
if [ "$here" = true ] && [ -n "$branch_arg" ]; then
  echo "!! --here and an explicit branch argument ('$branch_arg') conflict; pass one or the other" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi

# Checked here rather than left to claude: an invalid level should cost nothing,
# not fail once per session after the branch has already been created.
case "$effort" in
  low|medium|high|xhigh|max) ;;
  *)
    echo "!! invalid effort '$effort'; expected low, medium, high, xhigh, or max" >&2
    echo "   see: advance-issue-loop.sh --help" >&2
    exit 1
    ;;
esac

repo_root=$(git rev-parse --show-toplevel)
env_file="$repo_root/.env"

# Read one KEY=value from .env. Parsed rather than sourced: .env is a config
# file, not a script, and sourcing it would run whatever it contains.
from_env_file() {
  [ -r "$env_file" ] || return 0
  sed -n "s/^[[:space:]]*${1}[[:space:]]*=[[:space:]]*//p" "$env_file" |
    tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

resolve_topic() {
  local topic
  topic="${NTFY_TOPIC:-$(from_env_file NTFY_TOPIC)}"
  if [ -z "$topic" ] && [ -r "$HOME/.config/ntfy/topic" ]; then
    topic=$(head -n1 "$HOME/.config/ntfy/topic")
  fi
  printf '%s' "$topic"
}

# A loop nobody can hear is a loop nobody is watching: it runs unattended for
# hours, and every early stop - the failure this whole script is shaped around
# reporting - lands in silence. Refuse to start rather than run blind.
if [ -z "$(resolve_topic)" ]; then
  echo "!! no ntfy topic configured; refusing to start" >&2
  echo "   set NTFY_TOPIC, or add it to $env_file, or write it to $HOME/.config/ntfy/topic" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi

# notify <title> <priority> <tags> <message>
notify() {
  local topic url
  # Resolved per call so the topic can be repointed mid-run. Still guarded: it
  # was present at startup, but .env can be edited under a running loop.
  topic=$(resolve_topic)
  [ -n "$topic" ] || return 0

  url="${NTFY_URL:-$(from_env_file NTFY_URL)}"
  url="${url:-https://ntfy.sh}"

  curl -fsS -m 10 \
    -H "Title: $1" \
    -H "Priority: $2" \
    -H "Tags: $3" \
    -d "$4" \
    "$url/$topic" >/dev/null 2>&1 || true
}

# herdr detects a working agent from the OSC terminal title its TUI sets, and the
# agent here is `claude -p`: headless, no TUI, no title. Nothing matches, so the
# pane falls back to `idle` for the whole run and an hour of work reads as an
# asleep pane in the sidebar. The loop knows its own state exactly, so it says so
# rather than being guessed at.
#
# herdr_state <idle|working|blocked> [message]
#
# A no-op outside herdr, and never fatal: a sidebar that is wrong must not stop
# the work. `--seq` is a staleness guard, so it has to increase monotonically -
# reports that go backwards are dropped as out of order.
herdr_seq=0
herdr_state() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0

  local args
  herdr_seq=$((herdr_seq + 1))
  args=(report-agent "$HERDR_PANE_ID"
    --source advance-issue-loop
    --agent "issue #$issue"
    --state "$1"
    --seq "$herdr_seq")
  [ -z "${2:-}" ] || args+=(--message "$2")

  herdr pane "${args[@]}" >/dev/null 2>&1 || true
}

# Ctrl-C means the pane has been handed back, so hand the state back with it:
# stand down from working, then drop authority and let herdr's own detection
# describe whatever runs there next. Releasing while still reporting `working`
# would strand the sidebar on a session that is no longer running.
herdr_release() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0

  herdr_state idle "interrupted"
  herdr pane release-agent "$HERDR_PANE_ID" \
    --source advance-issue-loop --agent "issue #$issue" >/dev/null 2>&1 || true
}

trap 'herdr_release; exit 130' INT TERM

# Every early exit goes through here, so no failure path can end up silent.
die() {
  echo "!! $1"
  # Blocked rather than idle: an early stop is waiting for a human, and the
  # sidebar should say so as loudly as ntfy does.
  herdr_state blocked "$1"
  notify "$repo #$issue stopped" urgent rotating_light "$1"
  exit 1
}

# `claude -p` in its default text format prints nothing until the session ends,
# so a step that takes twenty minutes shows twenty minutes of an empty terminal.
# That reads the same as a hung loop, and this loop is meant to be watched while
# it runs unattended. The stream-json format emits an event per turn instead;
# this renders those events as one line per tool call and per reply.
#
# The final report is printed in full: it is the same handoff the session posts
# as an issue comment, and it is what tells you whether the step went the way
# the body planned.
progress_filter=$(
  cat <<'JQ'
def oneline: tostring | gsub("[\r\n\t]+"; " ") | gsub("  +"; " ");
def pad($n): . + ((" " * ($n - length)) // "");
def clip($n): if (length > $n) then .[0:$n - 1] + "…" else . end;
def line($tag): "  · " + ($tag | pad(9)) + .;

if .type == "assistant" then
  .message.content[]?
  | if .type == "tool_use" then
      (.name as $tag
       | (.input.command // .input.file_path // .input.pattern // .input.skill
          // .input.description // .input.prompt // .input.url // "")
       | oneline | clip(100) | line($tag))
    elif .type == "text" and (.text | test("[^[:space:]]")) then
      (.text | oneline | clip(100) | line("reply"))
    else empty end
elif .type == "result" then
  ("" | line("result")) + .subtype
    + " in \(.num_turns) turns, \(((.duration_ms // 0) / 1000) | round)s",
  ((.result // "") | select(test("[^[:space:]]")) | split("\n")[] | "    " + .)
else empty end
JQ
)

# Rendering the stream needs jq. Falling back rather than refusing: thin output
# is a worse loop, not a broken one, and the loop's own reporting still works.
stream=1
if ! command -v jq >/dev/null 2>&1; then
  stream=""
  echo "!! jq not found; running without live progress" >&2
fi

# run_session <prompt>
#
# Returns claude's own exit status, not the renderer's: a jq hiccup must not be
# reported as a failed step, and a failed step must not be hidden by a renderer
# that exited cleanly on partial input.
run_session() {
  if [ -z "$stream" ]; then
    claude -p --permission-mode acceptEdits --effort "$effort" "$1"
    return $?
  fi

  claude -p --output-format stream-json --verbose \
    --permission-mode acceptEdits --effort "$effort" "$1" |
    jq -r --unbuffered "$progress_filter"
  local rc=${PIPESTATUS[0]}
  return "$rc"
}

unchecked() {
  gh issue view "$issue" --json body -q .body | grep -c '^- \[ \]' || true
}

# Gates are written into the heading of the step they gate, per the
# writing-issues contract:
#
#   - [ ] **Step 7 - Cutover** (gated on Step 4)
#   - [ ] **Step 7 - Cutover** (gated on #12)
#
# advance-issue-step resolves these before it implements; the loop resolves them
# again before spending a session, because the two checks cover different holes.
# The blockedBy check above is issue-level and runs only when an issue is
# started, so a resumed run would reach a gated step with nothing having looked
# at it. Checking here also stops a blocked run without burning a session to
# discover it.
#
# Prints the unmet gates and returns 1; returns 0 when the next step is clear or
# carries no gate at all.
unmet_gates() {
  local body step gates n ref unmet=""

  body=$(gh issue view "$issue" --json body -q .body)
  step=$(printf '%s\n' "$body" | grep -m1 '^- \[ \]')
  [ -n "$step" ] || return 0

  gates=$(printf '%s\n' "$step" | grep -oiE '\(gated on [^)]*\)')
  [ -n "$gates" ] || return 0

  # A gate on another step of this issue is met once that step is ticked. The
  # trailing [^0-9] keeps "Step 1" from matching "Step 10".
  while read -r n; do
    [ -n "$n" ] || continue
    printf '%s\n' "$body" | grep -qiE "^- \[[xX]\] \*\*Step ${n}[^0-9]" ||
      unmet="${unmet:+$unmet; }Step $n is not ticked"
  done < <(printf '%s\n' "$gates" | grep -oiE 'step +[0-9]+' | grep -oE '[0-9]+')

  # A gate on another issue is met only once that issue is closed.
  while read -r ref; do
    [ -n "$ref" ] || continue
    [ "$(gh issue view "$ref" --json state -q .state 2>/dev/null)" = "CLOSED" ] ||
      unmet="${unmet:+$unmet; }#$ref is not closed"
  done < <(printf '%s\n' "$gates" | grep -oE '#[0-9]+' | tr -d '#')

  [ -n "$unmet" ] || return 0
  printf '%s' "$unmet"
  return 1
}

repo=$(basename "$repo_root")

# Derive a branch name from the issue title. Drops a leading "Phase 1.2 - " so
# the name describes the work rather than its place in a plan.
derive_branch() {
  local slug
  slug=$(gh issue view "$issue" --json title -q .title |
    sed -E 's/^[[:space:]]*[Pp]hase[[:space:]]+[0-9]+(\.[0-9]+)*[[:space:]]*[-:][[:space:]]*//' |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' |
    cut -c1-40 | sed -E 's/-+$//')
  [ -n "$slug" ] || slug=work
  printf 'feat/issue-%s-%s' "$issue" "$slug"
}

# Where finished issues land, so never where an issue's steps are written.
resolve_default_branch() {
  local d
  d=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  d="${d#origin/}"
  printf '%s' "${d:-main}"
}

# An issue gets its own branch, so a run started from the wrong place cannot
# quietly pile one issue's commits onto another issue's branch.
base=$(git rev-parse --abbrev-ref HEAD)

# --here names the branch by pointing at it, which is the same thing as passing
# its name, so it resolves to a branch argument and takes the resume path below.
if [ "$here" = true ]; then
  [ "$base" != HEAD ] ||
    die "--here needs a branch checked out; HEAD is detached."

  # Every step commits and pushes. On the default branch that is a push straight
  # to the trunk, one per step, with no chance to review the issue as a whole.
  [ "$base" != "$(resolve_default_branch)" ] ||
    die "Refusing to work issue #$issue directly on '$base'. --here is for a feature branch: check one out, or drop --here to have one cut for you."

  branch_arg="$base"

  # The dirty-tree check is skipped, not passed. Say so, because the first step
  # that commits will sweep up whatever it happens to touch.
  dirty=$(git status --porcelain)
  if [ -n "$dirty" ]; then
    echo "==> note: working tree is dirty and --here does not stop for it:"
    printf '%s\n' "$dirty" | sed 's/^/      /'
  fi
fi

# An issue is identified by its number, not by the exact branch name: a branch
# named by hand belongs to the issue just as much as a derived one does, and
# resuming must find it rather than start the issue over on a second branch.
existing=""
if [ -n "$branch_arg" ]; then
  git show-ref --verify --quiet "refs/heads/$branch_arg" && existing="$branch_arg"
else
  existing=$(git for-each-ref --format='%(refname:short)' "refs/heads/feat/issue-$issue-*" | head -1)
fi
branch="${branch_arg:-${existing:-$(derive_branch)}}"

if [ "$branch" = "$base" ]; then
  if [ "$here" = true ]; then
    echo "==> --here: working issue #$issue on the current branch $branch ($(git rev-parse --short HEAD))"
  else
    echo "==> already on $branch, resuming issue #$issue"
  fi
elif [ -n "$existing" ]; then
  echo "==> resuming issue #$issue on existing branch $branch"
  git switch "$branch" || die "Could not switch to the existing branch $branch."
else
  # Starting a new issue. Everything below refuses rather than improvises: a
  # wrong base is not visible in the commits it produces, so it has to be caught
  # here or not at all.

  # Uncommitted work would be carried onto a branch it does not belong to and
  # attributed to this issue by the first step that commits.
  [ -z "$(git status --porcelain)" ] ||
    die "Working tree is dirty; commit or stash before starting issue #$issue, or pass --here to work it on '$base' as it stands. Note that 'git stash' leaves untracked files behind - 'git stash -u' includes them."

  default_branch=$(resolve_default_branch)

  # A new issue starts from the default branch. Anything else means unmerged
  # work is in the base, which is exactly the dependency this refuses to stack.
  [ "$base" = "$default_branch" ] ||
    die "Refusing to start issue #$issue from '$base'. Merge that work into '$default_branch' and check it out first."

  # Blocking issues must be closed. Closed is not the same as merged, but the
  # base check above covers the merge; this covers the ones not yet finished.
  open_blockers=$(gh issue view "$issue" --json blockedBy \
    -q '[.blockedBy.nodes[]? | select(.state == "OPEN") | "#\(.number)"] | join(", ")' 2>/dev/null)
  [ -z "$open_blockers" ] ||
    die "Issue #$issue is blocked by $open_blockers. Finish and merge those first."

  echo "==> starting issue #$issue on new branch $branch, cut from $base ($(git rev-parse --short HEAD))"
  git switch -c "$branch" || die "Could not create the branch $branch."
fi

# Counted once, over ticked and unticked alike, so progress is reported against
# the whole issue. A resumed run says 6/9 rather than restarting the count at
# whatever was left when it began.
total=$(gh issue view "$issue" --json body -q .body | grep -c '^- \[')

for ((i = 1; i <= max; i++)); do
  before_open=$(unchecked)
  if [ "$before_open" -eq 0 ]; then
    echo "==> no unchecked steps left after $((i - 1)) session(s)"
    # herdr turns a reported idle that follows working into `done`, which is the
    # state it means by finished-but-not-yet-looked-at. Exactly right here.
    herdr_state idle "every step done on $branch"
    notify "$repo #$issue complete" high white_check_mark \
      "Every step done on $branch. Ready to review and integrate."
    exit 0
  fi

  gates=$(unmet_gates) ||
    die "Next step of #$issue is gated: $gates. $before_open step(s) still open."

  before_head=$(git rev-parse HEAD)
  echo "==> session $i starting at $effort effort: $before_open step(s) remaining"
  herdr_state working "session $i, $((total - before_open))/$total done"

  run_session "Use the advance-issue-step skill to implement the next unchecked step of GitHub issue #$issue. Stay on the current branch ($branch); do not create, switch, or merge branches, and do not open a pull request." ||
    die "Session $i exited non-zero. $before_open step(s) still open."

  [ "$(git rev-parse HEAD)" != "$before_head" ] ||
    die "Session $i produced no commit. $before_open step(s) still open."

  after_open=$(unchecked)
  [ "$after_open" -lt "$before_open" ] ||
    die "Session $i committed but ticked no checkbox. $before_open step(s) still open."

  git push origin "$branch" ||
    die "Push of $branch failed after session $i."

  echo "==> session $i done: $after_open step(s) remaining"
  notify "$repo #$issue step done" low heavy_check_mark \
    "$((total - after_open))/$total on $branch. $(git log --oneline -1)"
done

die "Hit the $max session cap with $(unchecked) step(s) still open."
