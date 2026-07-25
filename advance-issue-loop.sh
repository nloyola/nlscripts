#!/usr/bin/env bash
# Run one fresh `claude -p` session per unchecked step of a GitHub issue, driving
# the advance-issue-step skill, until no unchecked steps remain.
#
#   advance-issue-loop.sh <issue-number> [max-sessions] [branch] [effort]
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
# Push notifications go to ntfy as each step lands, when every step is done, and
# on any early stop. Every abnormal exit notifies, so silence means the loop is
# still working rather than dead.
#
# The topic is looked up fresh on every notification, so it can be added to a
# running loop:
#
#   1. NTFY_TOPIC in the environment
#   2. NTFY_TOPIC in the repository's .env      <- gitignored, per-project
#   3. the first line of ~/.config/ntfy/topic
#
# NTFY_URL, from the environment or .env, overrides the server (default
# https://ntfy.sh). With no topic configured the loop notifies nothing and is
# otherwise unchanged.
#
# An ntfy.sh topic is a shared secret: anyone who knows it can read and post to
# it. Keep it in .env, never in a committed file, and pick an unguessable name.

set -uo pipefail

usage() {
  cat <<'EOF'
Run one fresh `claude -p` session per unchecked step of a GitHub issue, driving
the advance-issue-step skill, until no unchecked steps remain.

usage: advance-issue-loop.sh <issue-number> [max-sessions] [branch] [effort]
       advance-issue-loop.sh -h | --help

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
                 first line of ~/.config/ntfy/topic. Unset means no notifying.
  NTFY_URL       ntfy server, from the environment or .env (default
                 https://ntfy.sh).

Examples:
  advance-issue-loop.sh 54
  advance-issue-loop.sh 54 5
  advance-issue-loop.sh 54 20 "" high
  advance-issue-loop.sh 54 20 feat/issue-54-cutover max
EOF
}

case "${1:-}" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 1
    ;;
esac

issue="$1"
max="${2:-20}"
branch_arg="${3:-}"
effort="${4:-medium}"

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

# notify <title> <priority> <tags> <message>
notify() {
  local topic url
  topic="${NTFY_TOPIC:-$(from_env_file NTFY_TOPIC)}"
  if [ -z "$topic" ] && [ -r "$HOME/.config/ntfy/topic" ]; then
    topic=$(head -n1 "$HOME/.config/ntfy/topic")
  fi
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

# Every early exit goes through here, so no failure path can end up silent.
die() {
  echo "!! $1"
  notify "$repo #$issue stopped" urgent rotating_light "$1"
  exit 1
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

# An issue gets its own branch, so a run started from the wrong place cannot
# quietly pile one issue's commits onto another issue's branch.
base=$(git rev-parse --abbrev-ref HEAD)

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
  echo "==> already on $branch, resuming issue #$issue"
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
    die "Working tree is dirty; commit or stash before starting issue #$issue."

  default_branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  default_branch="${default_branch#origin/}"
  [ -n "$default_branch" ] || default_branch=main

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
    notify "$repo #$issue complete" high white_check_mark \
      "Every step done on $branch. Ready to review and integrate."
    exit 0
  fi

  gates=$(unmet_gates) ||
    die "Next step of #$issue is gated: $gates. $before_open step(s) still open."

  before_head=$(git rev-parse HEAD)
  echo "==> session $i starting at $effort effort: $before_open step(s) remaining"

  claude -p --permission-mode acceptEdits --effort "$effort" \
    "Use the advance-issue-step skill to implement the next unchecked step of GitHub issue #$issue. Stay on the current branch ($branch); do not create, switch, or merge branches, and do not open a pull request." ||
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
