#!/usr/bin/env bash
# Run one fresh `claude -p` session per unchecked step of a GitHub issue, driving
# the advance-issue-step skill, until no unchecked steps remain.
#
#   advance-issue-loop.sh [--here] [--max n] [--effort level] \
#       <issue-number> [max-sessions] [branch] [effort]
#
# Every session runs at the same reasoning effort, defaulting to medium. Pass
# one of low, medium, high, xhigh, or max to raise or lower it for a whole run.
# The session cap and the effort each have a flag as well as a positional slot,
# so raising one of them does not mean filling in the slots before it.
#
# One loop at a time per repository. A second run refuses to start rather than
# interleaving branch switches and pushes with the first, whose commits it could
# not tell apart from a confused session's own.
#
# Stops early if a session fails to tick its checkbox, so a confused session
# cannot cascade into the following steps. The tick is the authority on progress,
# not the commit: a step can turn out to be a verification - it asks whether
# something already holds, finds that it does, and has nothing to change. That is
# a finished step, and the loop reports it as one. A session that neither ticked
# nor committed did nothing at all, and that still stops the run.
#
# A step that has to be proven on the staging VPS is never run. Staging is
# deployed by hand and the proof is an observation in a browser against it, so
# the loop stops when it reaches one and says so, the same way it stops on an
# unmet gate. Deploy staging yourself and drive that step with the
# advance-issue-step-staging skill; rerun the loop afterwards if steps remain.
#
# Every issue gets its own branch. Starting an issue creates one, named from the
# issue title unless a name is given; resuming an issue whose branch already
# exists switches to it rather than starting over.
#
# Every run requires a clean tree. Starting an issue also requires the default
# branch checked out and every blocking issue closed. Refusing to stack a new
# issue on unmerged work is the point: dependencies are satisfied by merging
# them, not by branching off them, so the base a step is written against is the
# base it will be merged to. Resuming an existing issue branch skips the base and
# blocker checks.
#
# `--here` works the issue on the branch already checked out, whatever it is
# named, and skips those start-of-issue checks the same way resuming does. Use it
# when the work belongs on a branch that is already going - a scratch branch, or
# an issue whose steps continue work not yet merged.
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
#   herdr pane wait-output "$pane" --regex '==> session [0-9]+ done' --timeout 3600000
#   herdr pane wait-output "$pane" --match '==> no unchecked steps left' --timeout 86400000
#   herdr pane read       "$pane" --source recent --lines 40
#
# `--match` is a literal substring and `--regex` is a pattern; they are separate
# flags, so pass one or the other rather than both.
#
# Timeouts are milliseconds, and a step can take an hour, so size them for the
# work rather than the default.
#
# `wait-output` searches the existing snapshot before it polls, so it is not a
# wait for the *next* occurrence: a pattern already on screen returns at once.
# `==> session [0-9]+ done` therefore matches session 1 while session 4 is
# running. Wait on the exact text you mean - `==> session 4 done` - or narrow the
# snapshot with `--lines`. `pane read` is for what has already scrolled past.
#
# Because the loop reports its own state to herdr (see herdr_state below), the
# lifecycle is also waitable directly, without matching on output at all:
#
#   herdr agent wait "$pane" --until blocked --until done --timeout 86400000
#
# `done` is every step finished; `blocked` is any early stop. Note `--until`, and
# that omitting it waits for idle, done, or blocked.
#
# Every early stop prints a line starting with `!!` and notifies ntfy, so a
# `wait` that times out means slow, not dead - check `pane read` before assuming
# the run is gone.
#
# Between steps the loop looks at how full the usage windows are, reading the
# rate-limit report Claude Code puts on the session stream. Over 80% of either
# the 5-hour session limit or the weekly one - or whatever percentage
# ADVANCE_ISSUE_USAGE_THRESHOLD names - it stops before starting the next
# session and asks at the terminal whether to go on anyway. A session cut off
# mid-step by a limit ticks nothing and leaves a half-finished tree behind, so
# the loop would rather hand the decision back one step early. With no terminal
# to ask - and without jq, which is what reads the stream - it stops instead.
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

usage: advance-issue-loop.sh [--here] [--max n] [--effort level]
                            <issue-number> [max-sessions] [branch] [effort]
       advance-issue-loop.sh -h | --help

Options:
  --here         Work the issue on the currently checked-out branch instead of
                 cutting a new one, and skip the default-branch and blocker
                 checks. The working tree must still be clean. Refuses on a
                 detached HEAD or on the default branch itself,
                 and cannot be combined with an explicit branch argument.
  --max n        Same as the max-sessions argument, without having to fill the
                 slots before it.
  --effort level Same as the effort argument, without having to fill the slots
                 before it. Either form may be used, but not both at once.

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
  ADVANCE_ISSUE_USAGE_THRESHOLD
                 Percent of a usage window at which the loop stops between
                 sessions and asks before starting the next one (default 80).

Examples:
  advance-issue-loop.sh 54
  advance-issue-loop.sh --here 54
  advance-issue-loop.sh 54 --max 5
  advance-issue-loop.sh 54 --effort high
  advance-issue-loop.sh 54 20 "" high
  advance-issue-loop.sh 54 20 feat/issue-54-cutover max
EOF
}

# Options are pulled out wherever they appear, so `--here 54` and `54 --here`
# both work and the positional slots keep their meaning either way.
here=false
max_opt=""
effort_opt=""
args=()

# Both `--flag value` and `--flag=value` are accepted below; this is what the
# first form says when the value it needs is not there.
need_value() {
  echo "!! $1 needs a value" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --here | --current-branch)
      here=true
      ;;
    --max)
      shift
      [ $# -gt 0 ] || need_value --max
      max_opt="$1"
      ;;
    --max=*)
      max_opt="${1#*=}"
      ;;
    --effort)
      shift
      [ $# -gt 0 ] || need_value --effort
      effort_opt="$1"
      ;;
    --effort=*)
      effort_opt="${1#*=}"
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
if [ "${#args[@]}" -gt 4 ]; then
  echo "!! too many positional arguments; expected at most 4" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi

issue="${args[0]}"
branch_arg="${args[2]:-}"

# The flag and the positional say the same thing, so being given both is a
# contradiction rather than a precedence question to resolve quietly.
if [ -n "$max_opt" ] && [ -n "${args[1]:-}" ]; then
  echo "!! --max and the max-sessions argument ('${args[1]}') conflict; pass one or the other" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi
if [ -n "$effort_opt" ] && [ -n "${args[3]:-}" ]; then
  echo "!! --effort and the effort argument ('${args[3]}') conflict; pass one or the other" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi
max="${max_opt:-${args[1]:-20}}"
effort="${effort_opt:-${args[3]:-medium}}"

if ! [[ "$issue" =~ ^[1-9][0-9]*$ ]]; then
  echo "!! invalid issue number '$issue'; expected a positive integer" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi
if ! [[ "$max" =~ ^[1-9][0-9]*$ ]]; then
  echo "!! invalid max-sessions '$max'; expected a positive integer" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi
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

command -v git >/dev/null 2>&1 || {
  echo "!! required command not found: git" >&2
  exit 1
}
if [ -n "$branch_arg" ] && ! git check-ref-format --branch "$branch_arg" >/dev/null 2>&1; then
  echo "!! invalid branch name '$branch_arg'" >&2
  echo "   see: advance-issue-loop.sh --help" >&2
  exit 1
fi
repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
  echo "!! not inside a Git repository" >&2
  exit 1
}
repo=${repo_root##*/}
for required in gh claude curl; do
  command -v "$required" >/dev/null 2>&1 || {
    echo "!! required command not found: $required" >&2
    exit 1
  }
done
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
#
# herdr keeps that last seq per pane and source, and the source is fixed, so the
# guard spans runs rather than just this one. Counting from zero meant a second
# run in the same pane spent its whole life under the previous run's high-water
# mark and had every report dropped, leaving the sidebar frozen on whatever the
# old run last said - a finished loop still reading as `working`. Seconds since
# the epoch start above any earlier run and still step by one per report.
herdr_seq=$(date +%s)
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

# Ctrl-C is the pane being handed back, and it can arrive in the window between a
# session's commit and the push the loop would have done next. Push first, then
# stand down: everything else about the run is recoverable by rerunning it, and
# an unpushed commit under a ticked checkbox is not (see push_pending).
#
# The handler disarms itself so a second Ctrl-C during the push is not answered
# by a second handler, and guards the call because a signal can arrive before the
# functions it wants exist.
on_interrupt() {
  trap '' INT TERM
  echo
  command -v push_pending >/dev/null 2>&1 && push_pending
  herdr_release
  exit 130
}

trap on_interrupt INT TERM

# Every early exit goes through here, so no failure path can end up silent.
die() {
  echo "!! $1"
  # Blocked rather than idle: an early stop is waiting for a human, and the
  # sidebar should say so as loudly as ntfy does.
  herdr_state blocked "$1"
  notify "$repo #$issue stopped" urgent rotating_light "$1"
  exit 1
}

# One loop at a time per repository. Two would interleave branch switches and
# pushes, and neither could tell the other's commits from a confused session's
# own - the difference every check below this line is built to see.
#
# Non-blocking on purpose: a second run is a mistake to report, not a queue to
# join. The lock lives in the common git directory rather than the worktree, so
# two worktrees of one repository share it; they share the remote and the issue,
# which is what the guard is really about.
#
# Held on fd 9 for the life of the process, so it is released by exit however the
# run ends, including a kill the traps never see.
lock_dir=$(git -C "$repo_root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || lock_dir=""
[ -d "$lock_dir" ] || lock_dir="$repo_root/.git"
if command -v flock >/dev/null 2>&1; then
  exec 9>"$lock_dir/advance-issue-loop.lock" ||
    die "Could not open the run lock in $lock_dir."
  flock -n 9 ||
    die "Another advance-issue-loop is already running in $repo. Wait for it, or stop it first."
else
  echo "!! flock not found; running without the one-loop-per-repository guard" >&2
fi

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
  echo "!! jq not found; running without live progress or usage checks" >&2
fi

# Session output is short-lived and private to this run.
run_tmp=$(mktemp -d "${TMPDIR:-/tmp}/advance-issue-loop.XXXXXX") ||
  die "Could not create a temporary directory."
trap 'rm -rf -- "$run_tmp"' EXIT

stream_file=""
if [ -n "$stream" ]; then
  stream_file="$run_tmp/stream"
fi

# Claude Code ships a herdr integration: a SessionStart hook that tells herdr the
# pane now belongs to the session that just started. Every session this loop runs
# fires it, and herdr honours that claim over this script's own reports, without
# letting go the moment a headless `claude -p` exits. The loop's final report -
# the one that says done, or blocked, and the only one anybody is waiting on -
# therefore lands in a pane herdr still believes belongs to a running session and
# is dropped. The sidebar keeps the last state it did accept, `working`, forever.
#
# The pane belongs to the loop, not to the sessions it spawns, so the sessions
# run with the herdr environment hidden. The hook is a no-op without it - it
# exits unless HERDR_ENV, HERDR_SOCKET_PATH, and HERDR_PANE_ID are all set - and
# the reporting below is left as the pane's only voice. Nothing else is lost: a
# `claude -p` with no terminal has nothing to say to herdr anyway.
hide_herdr=(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH)

# run_session <prompt>
#
# Returns claude's own exit status, not the renderer's: a jq hiccup must not be
# reported as a failed step, and a failed step must not be hidden by a renderer
# that exited cleanly on partial input.
run_session() {
  if [ -z "$stream" ]; then
    "${hide_herdr[@]}" claude -p --permission-mode acceptEdits --effort "$effort" "$1"
    return $?
  fi

  # tee sits in the pipeline rather than in a background process substitution so
  # the capture is complete the moment the pipeline returns; read_usage below
  # then never races the writer.
  : >"$stream_file"
  "${hide_herdr[@]}" claude -p --output-format stream-json --verbose \
    --permission-mode acceptEdits --effort "$effort" "$1" |
    tee "$stream_file" |
    jq -r --unbuffered "$progress_filter"
  local rc=${PIPESTATUS[0]}
  return "$rc"
}

# Percent of each usage window, and when each one resets, as of the last session
# that ran. Empty until a session has reported: nothing is assumed about a window
# nobody has measured, and the gate below stays out of the way until then.
usage_threshold=${ADVANCE_ISSUE_USAGE_THRESHOLD:-80}
if ! [[ "$usage_threshold" =~ ^[0-9]+$ ]] || [ "$usage_threshold" -lt 1 ] ||
  [ "$usage_threshold" -gt 100 ]; then
  die "Invalid ADVANCE_ISSUE_USAGE_THRESHOLD '$usage_threshold'; expected a percentage between 1 and 100."
fi
limit_five=""
limit_seven=""
reset_five=0
reset_seven=0

# Claude Code emits a `rate_limit_event` on the stream whenever the numbers move,
# carrying both windows as fractions. Take the last one of the session.
#
# A session that moved nothing emits none, and then the previous reading stands:
# it is still the most recent thing known, and a missing event is not a reason to
# believe a window emptied.
read_usage() {
  [ -n "$stream" ] && [ -s "$stream_file" ] || return 0

  local line
  line=$(jq -r 'select(.type == "rate_limit_event")
                | .rate_limit_info.unifiedWindows // empty
                | [((.five_hour.utilization // 0) * 100 | round),
                   ((.seven_day.utilization // 0) * 100 | round),
                   (.five_hour.resetsAt // 0),
                   (.seven_day.resetsAt // 0)]
                | @tsv' "$stream_file" 2>/dev/null | tail -n1)
  [ -n "$line" ] || return 0

  IFS=$'\t' read -r limit_five limit_seven reset_five reset_seven <<<"$line"
}

# eta <epoch> -> 1h12m, 9m, <1m; empty when the reset time is unknown
eta() {
  local at=${1:-0} remaining
  [ "$at" -gt 0 ] 2>/dev/null || return 0
  remaining=$((at - $(date +%s)))
  ((remaining < 0)) && remaining=0
  if ((remaining >= 3600)); then
    printf '%dh%02dm' $((remaining / 3600)) $((remaining % 3600 / 60))
  elif ((remaining >= 60)); then
    printf '%dm' $((remaining / 60))
  else
    printf '<1m'
  fi
}

# usage_gate <next-session-number> <steps-still-open>
#
# A step that runs into a limit is worse than a step not started: the session
# dies partway, ticks nothing, and leaves whatever it had done in the tree. So
# past the threshold the loop stops and asks first.
#
# Asked on /dev/tty, not stdin: the loop is often started with its stdin pointed
# somewhere else entirely, and answering on stdin would then be impossible.
usage_gate() {
  local next=$1 open=$2 window pct resets where answer

  if [ -n "$limit_five" ] && [ "$limit_five" -ge "$usage_threshold" ]; then
    window="5-hour session limit"
    pct=$limit_five
    resets=$(eta "$reset_five")
  elif [ -n "$limit_seven" ] && [ "$limit_seven" -ge "$usage_threshold" ]; then
    window="7-day limit"
    pct=$limit_seven
    resets=$(eta "$reset_seven")
  else
    return 0
  fi

  where="$window at $pct%"
  [ -z "$resets" ] || where="$where (resets in $resets)"

  # Nobody to answer means nobody to wait for. Tested by opening the terminal
  # rather than by `[ -r /dev/tty ]`: the device node exists and is readable to
  # anyone, so the test passes in a session that has no controlling terminal at
  # all, and the open is the only thing that actually fails there.
  if ! { : <>/dev/tty; } 2>/dev/null; then
    die "$where, and no terminal to ask. Stopped before session $next with $open step(s) open; rerun to continue."
  fi

  echo "!! $where"
  herdr_state blocked "$where; waiting on you before session $next"
  notify "$repo #$issue usage $pct%" urgent hourglass \
    "$where. Session $next on $branch is waiting at the terminal: answer to go on, or run the next step yourself later."

  printf '   continue with session %s anyway? [y/N] ' "$next" >/dev/tty
  read -r answer </dev/tty || answer=""
  case "$answer" in
    y | Y | yes | YES)
      echo "==> continuing at $pct% of the $window"
      herdr_state working "resumed at $pct%"
      ;;
    *)
      die "$where. Stopped before session $next with $open step(s) open; rerun to continue."
      ;;
  esac
}

issue_body() {
  gh issue view "$issue" --json body -q .body
}

worktree_status() {
  git -C "$repo_root" status --porcelain=v1 --untracked-files=all --ignore-submodules=none
}

# Completion is announced to the user, to ntfy and to herdr, and must not be
# announced over commits that exist only on this machine. The loop pushes after
# every session, so anything ahead of the remote got there by a stop between a
# commit and its push - and the honest repair is the push itself, which is what
# the loop would have done had it not stopped.
#
# Whether anything is unpushed is asked of the remote, not of the tracking ref:
# that ref is only as fresh as the last fetch, and a stale one answers "already
# pushed" about a commit origin has never seen. A fetch that fails leaves the
# tracking ref as the best answer available, which is where this started.
unpushed() {
  local ahead
  git fetch --quiet origin "$branch" >/dev/null 2>&1 || true
  git rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null || return 0
  ahead=$(git rev-list --count "refs/remotes/origin/$branch..HEAD") || return 0
  [ "$ahead" -gt 0 ]
}

ensure_pushed() {
  unpushed || return 0
  git push origin "$branch" || die "Push of $branch failed."
}

# The same repair on the interrupt path, where dying is no use: the run is
# already over, and the only question left is whether the work survived it. A
# commit the last session made but never pushed is invisible to the next run -
# its checkbox is already ticked on the forge, so that run finds nothing to do
# and calls the issue complete over work that never left this machine.
push_pending() {
  [ -n "${branch:-}" ] || return 0
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || return 0
  [ "$(git branch --show-current)" = "$branch" ] || return 0
  unpushed || return 0

  echo "!! $branch has unpushed commits; pushing before standing down"
  git push origin "$branch" ||
    echo "!! push of $branch failed; its commits are still only on this machine"
}

# One pattern for a checkbox, shared by every helper below, and deliberately the
# same one the tick helper matches with (advance-issue-step's forge.sh). The
# writing-issues contract has no indented sub-checkbox, but the loop is the thing
# enforcing that contract and it cannot enforce it while disagreeing with the
# ticker about which box is next: forge.sh would tick the indented one, the
# loop's counts would not move, and the run would die saying nothing was ticked.
unchecked_re='^[[:space:]]*- \[ \]'
checkbox_re='^[[:space:]]*- \[[ xX]\]'

count_unchecked() {
  printf '%s\n' "$1" | grep -cE "$unchecked_re" || true
}

first_unchecked() {
  printf '%s\n' "$1" | grep -m1 -E "$unchecked_re"
}

checklist_lines() {
  printf '%s\n' "$1" | grep -E "$checkbox_re" | sed -E 's/^([[:space:]]*- \[)X\]/\1x]/' || true
}

# What a checkbox line reads as once the session has ticked it, indentation and
# all.
ticked() {
  printf '%s' "${1/- \[ \]/- [x]}"
}

# The step number a checkbox line carries, empty for one that carries none.
# Steps written to the writing-issues contract lead with `**Step N`, and that
# number is the step's identity.
step_number() {
  printf '%s\n' "$1" |
    sed -nE 's/^[[:space:]]*- \[[ xX]\][[:space:]]*\*\*[Ss]tep[[:space:]]+([0-9]+).*/\1/p'
}

# Whether two checklist lines are the same step in the same state.
#
# Identical lines obviously are. So are two lines carrying the same step number,
# whatever else changed between them: a session is free to fix a typo in the
# heading of the step it is doing, and comparing whole lines called that a
# session that never ticked its box - or worse, one that tampered with somebody
# else's. The number and the tick are not the session's to change, and those are
# what is compared. A step with no number has no such handle and is still matched
# exactly.
same_step() {
  local a=$1 b=$2 na nb sa=x sb=x
  [ "$a" = "$b" ] && return 0

  na=$(step_number "$a")
  nb=$(step_number "$b")
  [ -n "$na" ] && [ "$na" = "$nb" ] || return 1

  [[ "$a" =~ $unchecked_re ]] && sa=' '
  [[ "$b" =~ $unchecked_re ]] && sb=' '
  [ "$sa" = "$sb" ]
}

# Whether the step that was next has been ticked, in the body as it is now.
step_ticked() {
  local after=$1 want line
  want=$(ticked "$2")
  while IFS= read -r line; do
    same_step "$line" "$want" && return 0
  done < <(checklist_lines "$after")
  return 1
}

expected_checklist() {
  local changed=false line
  while IFS= read -r line; do
    if [ "$changed" = false ] && [[ "$line" =~ $unchecked_re ]]; then
      line=$(ticked "$line")
      changed=true
    fi
    printf '%s\n' "$line"
  done < <(checklist_lines "$1")
}

# Every checkbox that existed before the session must still be there after it,
# in the same order and the same state, with the next one ticked. Lines the
# session added are allowed only while they are unchecked: a step that uncovers
# work and writes it down as a follow-up box is an ordinary outcome, and an
# exact match of the whole checklist called that tampering.
checklist_preserved() {
  local before=$1 after=$2 line j=0
  local -a want=()
  while IFS= read -r line; do want+=("$line"); done < <(expected_checklist "$before")

  while IFS= read -r line; do
    if [ "$j" -lt "${#want[@]}" ] && same_step "$line" "${want[j]}"; then
      j=$((j + 1))
      continue
    fi
    # Not the line expected next, so it can only be an addition - and an
    # addition that is already ticked is a step nobody watched being done.
    [[ "$line" =~ $unchecked_re ]] || return 1
  done < <(checklist_lines "$after")

  [ "$j" -eq "${#want[@]}" ]
}

# Gates are written into the heading of the step they gate, per the
# writing-issues contract:
#
#   - [ ] **Step 7 - Cutover** (gated on Step 4)
#   - [ ] **Step 7 - Cutover** (gated on #12)
#   - [ ] **Step 7 - Cutover** (gated on #12, step 4)
#
# advance-issue-step resolves these before it implements; the loop resolves them
# again before spending a session, because the two checks cover different holes.
# The blockedBy check above is issue-level and runs only when an issue is
# started, so a resumed run would reach a gated step with nothing having looked
# at it. Checking here also stops a blocked run without burning a session to
# discover it.
#
# A step number is read in the order it was written: one that follows an issue
# reference in the same gate belongs to that issue, one that does not belongs to
# this issue. So "#12, step 4" asks after step 4 of #12, not step 4 here - which
# is how a gate on another issue's step used to block a run forever, the local
# step it appeared to name being the very step about to run.
#
# Naming a step narrows the gate to that step, so the issue holding it need not
# be closed. A bare issue reference is still met only once that issue closes.
#
# A gate whose issue cannot be read is reported as unread rather than as unmet:
# both stop the run, but only one of them is about the issue. Told apart because
# a rate limit, an outage or a typo in the reference all look exactly like an
# open blocker otherwise, and the run then stops with a reason that sends you
# looking at the wrong thing.
#
# Prints the unmet gates and returns 1; returns 0 when the next step is clear or
# carries no gate at all.
unmet_gates() {
  local body=$1 step gates unmet=""

  step=$(first_unchecked "$body")
  [ -n "$step" ] || return 0

  gates=$(printf '%s\n' "$step" | grep -oiE '\(gated on [^)]*\)')
  [ -n "$gates" ] || return 0

  # One gate at a time, so the issue a step is read against cannot leak out of
  # the gate that named it.
  local gate
  while IFS= read -r gate; do
    [ -n "$gate" ] || continue

    local -a refs=()
    local tok
    while IFS= read -r tok; do refs+=("$tok"); done < <(
      printf '%s\n' "$gate" | grep -oiE '#[0-9]+|step +[0-9]+'
    )

    local i next ctx="" n
    for ((i = 0; i < ${#refs[@]}; i++)); do
      tok=${refs[i]}
      next=${refs[i + 1]:-}

      if [ "${tok:0:1}" = '#' ]; then
        ctx=${tok#\#}
        # A step named next narrows this gate, and checking it subsumes the
        # state of the issue as a whole.
        case $next in
        [Ss][Tt][Ee][Pp]*) continue ;;
        esac
        local state
        if ! state=$(gh issue view "$ctx" --json state -q .state 2>/dev/null); then
          unmet="${unmet:+$unmet; }#$ctx could not be read from GitHub"
        elif [ "$state" != "CLOSED" ]; then
          unmet="${unmet:+$unmet; }#$ctx is not closed"
        fi
        continue
      fi

      # A gate on a step is met once that step is ticked, in the referenced
      # issue's body or in this one's. The trailing [^0-9] keeps "Step 1" from
      # matching "Step 10".
      n=${tok##* }
      if [ -n "$ctx" ]; then
        # Read into a variable rather than piped into grep: a pipeline reports
        # grep's status, so an unreadable issue and an unticked step are the
        # same answer, and a network blip stops the run saying the wrong thing.
        local ctx_body
        if ! ctx_body=$(gh issue view "$ctx" --json body -q .body 2>/dev/null); then
          unmet="${unmet:+$unmet; }#$ctx could not be read from GitHub"
        elif ! printf '%s\n' "$ctx_body" |
          grep -qiE "^[[:space:]]*- \[[xX]\] \*\*Step ${n}[^0-9]"; then
          unmet="${unmet:+$unmet; }#$ctx step $n is not ticked"
        fi
      else
        printf '%s\n' "$body" | grep -qiE "^[[:space:]]*- \[[xX]\] \*\*Step ${n}[^0-9]" ||
          unmet="${unmet:+$unmet; }Step $n is not ticked"
      fi
    done
  done < <(printf '%s\n' "$gates")

  [ -n "$unmet" ] || return 0
  printf '%s' "$unmet"
  return 1
}

# The last step of an issue written to the writing-issues contract is "Prove it
# on staging": no code changes, and the check is an observation in a browser
# against a real deployment of the staging VPS. That deployment is the user's -
# they run the deploy, the migration, the restart - and the observation wants
# eyes on a page. A headless session handed such a step can only do one of two
# wrong things: deploy the host itself, or convince itself the proof passed
# without ever seeing it. So the loop refuses the step and hands it back, for
# the advance-issue-step-staging skill to drive with the user present.
#
# Matched on the step heading alone. A step whose bullets merely mention staging
# - a note for whoever writes the rollout, say - is ordinary work and runs like
# any other; only a step that names staging as its business is held back.
#
# Prints the step heading and returns 0 when the next step is a staging proof;
# returns 1 otherwise.
staging_step() {
  local body=$1 step

  step=$(first_unchecked "$body")
  [ -n "$step" ] || return 1

  printf '%s\n' "$step" | grep -qi 'staging' || return 1
  printf '%s' "$step" | sed -E 's/^[[:space:]]*- \[ \][[:space:]]*//; s/\*\*//g'
}

# Derive a branch name from the issue title. Drops a leading "Phase 1.2 - " so
# the name describes the work rather than its place in a plan.
derive_branch() {
  local title slug
  title=$(gh issue view "$issue" --json title -q .title) || return 1
  slug=$(printf '%s\n' "$title" |
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
fi

initial_status=$(worktree_status) || die "Could not inspect the working tree."
[ -z "$initial_status" ] ||
  die "Working tree is dirty; clean it before running issue #$issue."

# An issue is identified by its number, not by the exact branch name: a branch
# named by hand belongs to the issue just as much as a derived one does, and
# resuming must find it rather than start the issue over on a second branch.
existing=""
if [ -n "$branch_arg" ]; then
  git show-ref --verify --quiet "refs/heads/$branch_arg" && existing="$branch_arg"
else
  mapfile -t issue_branches < <(
    git for-each-ref --format='%(refname:short)' "refs/heads/feat/issue-$issue-*"
  )
  if [ "${#issue_branches[@]}" -gt 1 ]; then
    branch_list=$(printf '%s, ' "${issue_branches[@]}")
    branch_list=${branch_list%, }
    die "Multiple local branches match issue #$issue: $branch_list. Pass the branch explicitly."
  fi
  existing="${issue_branches[0]:-}"
fi
if [ -n "$branch_arg" ]; then
  branch="$branch_arg"
elif [ -n "$existing" ]; then
  branch="$existing"
else
  branch=$(derive_branch) || die "Could not read the title of issue #$issue from GitHub."
fi

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
  default_branch=$(resolve_default_branch)

  # A new issue starts from the default branch. Anything else means unmerged
  # work is in the base, which is exactly the dependency this refuses to stack.
  [ "$base" = "$default_branch" ] ||
    die "Refusing to start issue #$issue from '$base'. Merge that work into '$default_branch' and check it out first."

  # Blocking issues must be closed. Closed is not the same as merged, but the
  # base check above covers the merge; this covers the ones not yet finished.
  open_blockers=$(gh issue view "$issue" --json blockedBy \
    -q '[.blockedBy.nodes[]? | select(.state == "OPEN") | "#\(.number)"] | join(", ")' 2>/dev/null) ||
    die "Could not read blockers for issue #$issue from GitHub."
  [ -z "$open_blockers" ] ||
    die "Issue #$issue is blocked by $open_blockers. Finish and merge those first."

  echo "==> starting issue #$issue on new branch $branch, cut from $base ($(git rev-parse --short HEAD))"
  git switch -c "$branch" || die "Could not create the branch $branch."
fi

# Counted once, over ticked and unticked alike, so progress is reported against
# the whole issue. A resumed run says 6/9 rather than restarting the count at
# whatever was left when it began.
initial_body=$(issue_body) || die "Could not read issue #$issue from GitHub."
total=$(printf '%s\n' "$initial_body" | grep -cE "$checkbox_re" || true)

for ((i = 1; i <= max; i++)); do
  before_body=$(issue_body) || die "Could not read issue #$issue from GitHub."
  before_open=$(count_unchecked "$before_body")
  if [ "$before_open" -eq 0 ]; then
    echo "==> no unchecked steps left after $((i - 1)) session(s)"
    ensure_pushed
    # herdr turns a reported idle that follows working into `done`, which is the
    # state it means by finished-but-not-yet-looked-at. Exactly right here.
    herdr_state idle "every step done on $branch"
    notify "$repo #$issue complete" high white_check_mark \
      "Every step done on $branch. Ready to review and integrate."
    exit 0
  fi

  gates=$(unmet_gates "$before_body") ||
    die "Next step of #$issue cannot start: $gates. $before_open step(s) still open."

  # Before the usage gate, because this stop has nothing to do with how much of
  # the window is left: the step is not this loop's to run at any budget.
  if step_title=$(staging_step "$before_body"); then
    die "Next step of #$issue is a staging proof ('$step_title'), which the loop does not run: staging is deployed by hand and the proof is an observation against it. Deploy staging on $branch, then drive the step with the advance-issue-step-staging skill. $before_open step(s) still open."
  fi

  # After the gates and before the work: a run that stops here has pushed
  # everything the last session did and left the next step untouched.
  usage_gate "$i" "$before_open"

  session_status=$(worktree_status) || die "Could not inspect the working tree before session $i."
  [ -z "$session_status" ] || die "Working tree became dirty before session $i."
  before_head=$(git rev-parse HEAD) || die "Could not inspect HEAD before session $i."
  before_step=$(first_unchecked "$before_body")
  echo "==> session $i starting at $effort effort: $before_open step(s) remaining"
  herdr_state working "session $i, $((total - before_open))/$total done"

  run_session "Use the advance-issue-step skill to implement the next unchecked step of GitHub issue #$issue. Stay on the current branch ($branch); do not create, switch, or merge branches, and do not open a pull request." ||
    die "Session $i exited non-zero. $before_open step(s) still open."

  read_usage

  current_branch=$(git branch --show-current)
  [ "$current_branch" = "$branch" ] ||
    die "Session $i switched from $branch to ${current_branch:-a detached HEAD}."

  after_head=$(git rev-parse HEAD) || die "Could not inspect HEAD after session $i."
  git merge-base --is-ancestor "$before_head" "$after_head" ||
    die "Session $i rewrote or discarded existing history."
  committed=false
  [ "$after_head" = "$before_head" ] || committed=true

  # Pushed the moment the commit is known to be sound, and before any check that
  # can still stop the run. Everything below this line is about the issue body
  # rather than the commit, and a commit held behind one of those checks is a
  # commit stranded on this machine: the checkbox is already ticked on the forge,
  # so the next run finds nothing left to do and reports the issue complete
  # having never pushed it. That includes the dirty-tree check immediately below,
  # which a step is entitled to trip - a spec left uncommitted on purpose, a
  # generated file the repo does not ignore - and which says nothing about
  # whether the commit belongs on the branch.
  if [ "$committed" = true ]; then
    git push origin "$branch" ||
      die "Push of $branch failed after session $i."
  fi

  session_status=$(worktree_status) || die "Could not inspect the working tree after session $i."
  [ -z "$session_status" ] || die "Session $i left new uncommitted changes."

  after_body=$(issue_body) || die "Could not read issue #$issue from GitHub."
  after_open=$(count_unchecked "$after_body")

  # The next checkbox, and only that checkbox, is the authority on completion.
  # Asked of the box itself rather than of the open count: a session that ticks
  # its own box and writes down a follow-up leaves that count where it was, and
  # counting was how the run came to say "committed but ticked no checkbox"
  # about a session that had ticked exactly the right one.
  if ! step_ticked "$after_body" "$before_step"; then
    if [ "$after_open" -lt "$before_open" ]; then
      die "Session $i did not complete the next checkbox."
    elif [ "$committed" = true ]; then
      die "Session $i committed but did not tick the next checkbox. $before_open step(s) still open."
    fi
    die "Session $i produced neither a commit nor a ticked checkbox. $before_open step(s) still open."
  fi
  checklist_preserved "$before_body" "$after_body" ||
    die "Session $i changed checkboxes other than the next one."

  # A ticked step with no commit is a verification: the step asked whether
  # something already held and found that it did. Said out loud rather than
  # passed over in silence, because it is also what a session looks like when it
  # ticks a step it only convinced itself of, and that is worth a second look
  # when the branch is reviewed.
  if [ "$committed" = false ]; then
    echo "==> session $i changed nothing: verification step, ticked with no commit"
  fi

  # A step that uncovered work and wrote it down is legitimate, but it moves the
  # finish line, so it is said out loud and the denominator follows the issue
  # rather than the count the run started with.
  added=$((after_open - (before_open - 1)))
  if [ "$added" -gt 0 ]; then
    echo "==> session $i added $added follow-up step(s)"
  fi
  total=$((total + added))

  echo "==> session $i done: $after_open step(s) remaining"
  if [ "$committed" = true ]; then
    notify "$repo #$issue step done" low heavy_check_mark \
      "$((total - after_open))/$total on $branch. $(git log --oneline -1)"
  else
    notify "$repo #$issue step done" low heavy_check_mark \
      "$((total - after_open))/$total on $branch. Verification step, no commit."
  fi
done

final_body=$(issue_body) || die "Could not read issue #$issue from GitHub."
remaining=$(count_unchecked "$final_body")
if [ "$remaining" -eq 0 ]; then
  echo "==> no unchecked steps left after $max session(s)"
  ensure_pushed
  herdr_state idle "every step done on $branch"
  notify "$repo #$issue complete" high white_check_mark \
    "Every step done on $branch. Ready to review and integrate."
  exit 0
fi

die "Hit the $max session cap with $remaining step(s) still open."
