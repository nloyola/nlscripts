#!/usr/bin/env bash
# Run one fresh `claude -p` session per unchecked step of a GitHub issue, driving
# the advance-issue-step skill, until no unchecked steps remain.
#
#   advance-issue-loop.sh <issue-number> [max-sessions]
#
# Stops early if a session produces no commit or fails to tick its checkbox,
# so a confused session cannot cascade into the following steps.
#
# Push notifications go to ntfy on two occasions only: every step done, and any
# early stop. Per-step progress goes to stdout, not to your phone. Every abnormal
# exit notifies, so silence means the loop is still working rather than dead.
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

issue="${1:?usage: advance-issue-loop.sh <issue-number> [max-sessions]}"
max="${2:-20}"

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

repo=$(basename "$repo_root")
branch=$(git rev-parse --abbrev-ref HEAD)
echo "==> issue #$issue on branch $branch"

for ((i = 1; i <= max; i++)); do
  before_open=$(unchecked)
  if [ "$before_open" -eq 0 ]; then
    echo "==> no unchecked steps left after $((i - 1)) session(s)"
    notify "$repo #$issue complete" high white_check_mark \
      "Every step done on $branch. Ready for a PR."
    exit 0
  fi

  before_head=$(git rev-parse HEAD)
  echo "==> session $i starting: $before_open step(s) remaining"

  claude -p --permission-mode acceptEdits \
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
done

die "Hit the $max session cap with $(unchecked) step(s) still open."
