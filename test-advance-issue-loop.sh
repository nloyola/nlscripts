#!/usr/bin/env bash

set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$script_dir/advance-issue-loop.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/advance-issue-loop-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

failures=0

fail() {
  printf 'not ok - %s\n' "$1"
  failures=$((failures + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
}

setup_case() {
  local name=$1 root="$tmp/$1"
  mkdir -p "$root/bin" "$root/state"

  git init --quiet --bare "$root/origin.git"
  git init --quiet --initial-branch=main "$root/repo"
  git -C "$root/repo" config user.name Test
  git -C "$root/repo" config user.email test@example.com
  printf 'initial\n' >"$root/repo/tracked"
  git -C "$root/repo" add tracked
  git -C "$root/repo" commit --quiet -m initial
  git -C "$root/repo" remote add origin "$root/origin.git"
  git -C "$root/repo" switch --quiet -c feat/test
  git -C "$root/repo" push --quiet --set-upstream origin feat/test

  cat >"$root/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [ "${TEST_GH_BODY_FAILURE:-}" = 1 ] && [[ "$*" == *"--json body"* ]]; then
  printf '%s\n' 'simulated GitHub failure' >&2
  exit 1
fi
if [ "${TEST_GH_BLOCKER_FAILURE:-}" = 1 ] && [[ "$*" == *"--json blockedBy"* ]]; then
  printf '%s\n' 'simulated GitHub failure' >&2
  exit 1
fi
if [ "${TEST_GH_TITLE_FAILURE:-}" = 1 ] && [[ "$*" == *"--json title"* ]]; then
  printf '%s\n' 'simulated GitHub failure' >&2
  exit 1
fi
case "$*" in
  *"--json body"*) cat "$TEST_STATE/body" ;;
  *"--json title"*) printf '%s\n' 'Test issue' ;;
  *"--json blockedBy"*) printf '\n' ;;
  *"--json state"*) printf '%s\n' 'CLOSED' ;;
  *) printf 'unexpected gh invocation: %s\n' "$*" >&2; exit 2 ;;
esac
EOF

  cat >"$root/bin/claude" <<'EOF'
#!/usr/bin/env bash
python3 - "$TEST_STATE/body" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
body = path.read_text()
mode = os.environ.get('TEST_CLAUDE_MODE', 'normal')
if mode == 'tick-all':
    body = body.replace('- [ ]', '- [x]')
elif mode == 'tick-two-add-one':
    body = body.replace('- [ ]', '- [x]') + '- [ ] **Step 3 - Unplanned work**\n'
elif mode == 'add-followup':
    body = body.replace('- [ ]', '- [x]', 1) + '- [ ] **Step 2 - Work this uncovered**\n'
elif mode == 'tick-second':
    first = body.find('- [ ]')
    second = body.find('- [ ]', first + 1)
    body = body[:second] + body[second:].replace('- [ ]', '- [x]', 1)
else:
    body = body.replace('- [ ]', '- [x]', 1)
path.write_text(body)
PY

case "${TEST_CLAUDE_MODE:-normal}" in
  dirty)
    printf 'unfinished\n' >left-behind
    ;;
  dirty-after-commit)
    printf 'session\n' >>session-work
    git add session-work
    git commit --quiet -m 'complete step'
    printf 'unfinished\n' >left-behind
    ;;
  dirty-outside)
    printf 'unfinished\n' >"$(git rev-parse --show-toplevel)/outside-subdirectory"
    ;;
  switch-branch)
    git switch --quiet -c escaped
    printf 'session\n' >>session-work
    git add session-work
    git commit --quiet -m 'complete step elsewhere'
    ;;
  rewrite-history)
    git reset --quiet --hard HEAD~1
    ;;
  verify)
    ;;
  *)
    printf 'session\n' >>session-work
    git add session-work
    git commit --quiet -m 'complete step'
    ;;
esac
printf '%s\n' '{"type":"result","subtype":"success","num_turns":1,"duration_ms":1,"result":"done"}'
EOF

  cat >"$root/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TEST_STATE/notify.log"
exit 0
EOF

  chmod +x "$root/bin/gh" "$root/bin/claude" "$root/bin/curl"
  printf '%s\n' '- [ ] **Step 1 - Complete work**' >"$root/state/body"
  printf '%s' "$root"
}

test_completion_on_last_allowed_session() {
  local root output rc=0
  root=$(setup_case completion-at-cap)
  output="$root/output"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    fail "completion on the last allowed session exits successfully"
    printf '  exit: %s\n' "$rc"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi

  if ! grep -q '^==> no unchecked steps left after 1 session(s)$' "$output"; then
    fail "completion on the last allowed session reports completion"
    return
  fi

  pass "completion on the last allowed session"
}

test_github_body_failure_stops_run() {
  local root output rc=0
  root=$(setup_case github-body-failure)
  output="$root/output"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_GH_BODY_FAILURE=1 NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    fail "GitHub body failure stops the run"
    return
  fi

  if ! grep -q '^!! Could not read issue #1 from GitHub\.$' "$output"; then
    fail "GitHub body failure explains the stop"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi

  pass "GitHub body failure stops the run"
}

test_blocker_query_failure_stops_new_issue() {
  local root output rc=0
  root=$(setup_case blocker-query-failure)
  output="$root/output"
  git -C "$root/repo" switch --quiet main

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_GH_BLOCKER_FAILURE=1 NTFY_TOPIC="test" \
      "$script" 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    fail "blocker query failure stops a new issue"
    return
  fi

  if ! grep -q '^!! Could not read blockers for issue #1 from GitHub\.$' "$output"; then
    fail "blocker query failure explains the stop"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi

  pass "blocker query failure stops a new issue"
}

test_title_query_failure_stops_new_issue() {
  local root output rc=0
  root=$(setup_case title-query-failure)
  output="$root/output"
  git -C "$root/repo" switch --quiet main

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_GH_TITLE_FAILURE=1 NTFY_TOPIC="test" \
      "$script" 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Could not read the title of issue #1 from GitHub." "$output"; then
    fail "title query failure stops a new issue"
    return
  fi
  pass "title query failure stops a new issue"
}

assert_arguments_rejected() {
  local name=$1 expected=$2
  shift 2
  local root output rc=0
  root=$(setup_case "$name")
  output="$root/output"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" "$@") >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "$expected" "$output"; then
    fail "$name"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi
  pass "$name"
}

test_argument_validation() {
  assert_arguments_rejected invalid-issue "!! invalid issue number 'nope'" --here nope
  assert_arguments_rejected invalid-max "!! invalid max-sessions 'nope'" --here 1 nope
  assert_arguments_rejected extra-argument "!! too many positional arguments" --here 1 1 "" low extra
}

test_invalid_branch_name_is_rejected() {
  local root output rc=0
  root=$(setup_case invalid-branch)
  output="$root/output"
  git -C "$root/repo" switch --quiet main

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" 1 1 bad..branch low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! invalid branch name 'bad..branch'" "$output"; then
    fail "invalid branch name is rejected"
    return
  fi
  pass "invalid branch name is rejected"
}

test_ambiguous_issue_branches_are_rejected() {
  local root output rc=0
  root=$(setup_case ambiguous-branches)
  output="$root/output"
  git -C "$root/repo" branch feat/issue-1-alpha main
  git -C "$root/repo" branch feat/issue-1-beta main
  git -C "$root/repo" switch --quiet main

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] ||
     ! grep -Fq "!! Multiple local branches match issue #1: feat/issue-1-alpha, feat/issue-1-beta." "$output"; then
    fail "ambiguous issue branches are rejected"
    return
  fi
  pass "ambiguous issue branches are rejected"
}

assert_session_rejected() {
  local name=$1 mode=$2 expected=$3
  local root output rc=0
  root=$(setup_case "$name")
  output="$root/output"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE="$mode" NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "$expected" "$output"; then
    fail "$name"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi
  pass "$name"
}

test_session_branch_switch_is_rejected() {
  assert_session_rejected branch-switch switch-branch \
    "!! Session 1 switched from feat/test to escaped."
}

test_session_uncommitted_changes_are_rejected() {
  assert_session_rejected uncommitted-work dirty \
    "!! Session 1 left new uncommitted changes."
}

test_here_rejects_preexisting_dirtiness() {
  local root output rc=0
  root=$(setup_case dirty-here)
  output="$root/output"
  printf 'before\n' >"$root/repo/preexisting-dirty"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=verify NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Working tree is dirty; clean it before running issue #1." "$output"; then
    fail "--here rejects pre-existing dirtiness"
    return
  fi
  pass "--here rejects pre-existing dirtiness"
}

test_new_dirtiness_outside_starting_subdirectory_is_rejected() {
  local root output rc=0
  root=$(setup_case dirty-outside-subdirectory)
  output="$root/output"
  mkdir "$root/repo/subdirectory"

  (cd "$root/repo/subdirectory" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=dirty-outside NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Session 1 left new uncommitted changes." "$output"; then
    fail "new dirtiness outside the starting subdirectory is rejected"
    return
  fi
  pass "new dirtiness outside the starting subdirectory is rejected"
}

test_multiple_completed_checkboxes_are_rejected() {
  local root output rc=0
  root=$(setup_case multiple-checkboxes)
  output="$root/output"
  printf '%s\n' \
    '- [ ] **Step 1 - Complete work**' \
    '- [ ] **Step 2 - Complete more work**' >"$root/state/body"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=tick-all NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Session 1 changed checkboxes other than the next one." "$output"; then
    fail "multiple completed checkboxes are rejected"
    return
  fi
  pass "multiple completed checkboxes are rejected"
}

test_compensated_checkbox_changes_are_rejected() {
  local root output rc=0
  root=$(setup_case compensated-checkboxes)
  output="$root/output"
  printf '%s\n' \
    '- [ ] **Step 1 - Complete work**' \
    '- [ ] **Step 2 - Complete more work**' >"$root/state/body"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=tick-two-add-one NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Session 1 changed checkboxes other than the next one." "$output"; then
    fail "compensated checkbox changes are rejected"
    return
  fi
  pass "compensated checkbox changes are rejected"
}

test_wrong_completed_checkbox_is_rejected() {
  local root output rc=0
  root=$(setup_case wrong-checkbox)
  output="$root/output"
  printf '%s\n' \
    '- [ ] **Step 1 - Complete work**' \
    '- [ ] **Step 2 - Complete more work**' >"$root/state/body"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=tick-second NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Session 1 did not complete the next checkbox." "$output"; then
    fail "completing the wrong checkbox is rejected"
    return
  fi
  pass "completing the wrong checkbox is rejected"
}

test_rewritten_history_is_rejected() {
  local root output rc=0
  root=$(setup_case rewritten-history)
  output="$root/output"
  printf 'second\n' >>"$root/repo/tracked"
  git -C "$root/repo" add tracked
  git -C "$root/repo" commit --quiet -m second
  git -C "$root/repo" push --quiet

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=rewrite-history NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Session 1 rewrote or discarded existing history." "$output"; then
    fail "rewritten history is rejected"
    return
  fi
  pass "rewritten history is rejected"
}

# A step that ticks its own box and writes down the work it uncovered is an
# ordinary outcome. Counting open boxes cannot see it - the count does not move -
# and the loop used to die claiming nothing had been ticked.
test_followup_checkbox_is_accepted() {
  local root output line rc=0
  root=$(setup_case followup-checkbox)
  output="$root/output"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=add-followup NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  # The cap is hit with the added step still open, so the run exits non-zero -
  # correctly, and separately from what this is testing.
  if ! grep -Fq '==> session 1 added 1 follow-up step(s)' "$output" ||
     ! grep -Fq '==> session 1 done: 1 step(s) remaining' "$output"; then
    fail "a follow-up checkbox is accepted"
    printf '  exit: %s\n' "$rc"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi

  # The denominator follows the issue, so the added step is counted rather than
  # reported as 1/1 with a step still open.
  if ! grep -Fq '1/2 on feat/test' "$root/state/notify.log"; then
    fail "a follow-up checkbox moves the progress denominator"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$root/state/notify.log"
    return
  fi

  pass "a follow-up checkbox is accepted"
}

# The loop and advance-issue-step's forge.sh have to agree on what a checkbox
# looks like. forge.sh allows leading whitespace; the loop anchored at column 0,
# so an indented box was invisible to it and the run reported the issue done
# without running a single session.
test_indented_checkbox_is_seen() {
  local root output line rc=0
  root=$(setup_case indented-checkbox)
  output="$root/output"
  printf '%s\n' '  - [ ] **Step 1 - Complete work**' >"$root/state/body"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ] || ! grep -Fq '==> session 1 starting' "$output" ||
     ! grep -Fq '==> session 1 done: 0 step(s) remaining' "$output"; then
    fail "an indented checkbox is seen"
    printf '  exit: %s\n' "$rc"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi
  pass "an indented checkbox is seen"
}

# A markdown link bullet is not a checkbox. Counting it inflated the denominator
# of every progress line, so a finished issue never read as finished.
test_link_bullet_is_not_counted() {
  local root output line rc=0
  root=$(setup_case link-bullet)
  output="$root/output"
  printf '%s\n' \
    '- [RFC 9110](https://example.com/rfc9110)' \
    '- [ ] **Step 1 - Complete work**' >"$root/state/body"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ] || ! grep -Fq '1/1 on feat/test' "$root/state/notify.log"; then
    fail "a markdown link bullet is not counted as a step"
    printf '  exit: %s\n' "$rc"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi
  pass "a markdown link bullet is not counted as a step"
}

# The checkbox is ticked on the forge before the loop looks at the working tree,
# so a stop there must not leave the commit behind it here: the next run would
# find no open step, report the issue complete, and never push.
test_commit_is_pushed_before_the_run_can_stop() {
  local root output rc=0 remote_head local_head
  root=$(setup_case push-before-stop)
  output="$root/output"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" TEST_CLAUDE_MODE=dirty-after-commit NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Session 1 left new uncommitted changes." "$output"; then
    fail "a stranded commit is pushed before the run can stop"
    return
  fi

  local_head=$(git -C "$root/repo" rev-parse HEAD)
  remote_head=$(git -C "$root/repo" rev-parse refs/remotes/origin/feat/test)
  if [ "$local_head" != "$remote_head" ]; then
    fail "a stranded commit is pushed before the run can stop"
    printf '  local %s != origin %s\n' "$local_head" "$remote_head"
    return
  fi
  pass "a stranded commit is pushed before the run can stop"
}

# Completion is announced to the user and to ntfy. Announcing it over commits
# that never left the machine is the failure that check exists for.
test_completion_does_not_announce_unpushed_work() {
  local root output line rc=0 remote_head local_head
  root=$(setup_case completion-pushes)
  output="$root/output"
  printf '%s\n' '- [x] **Step 1 - Complete work**' >"$root/state/body"
  printf 'stranded\n' >>"$root/repo/tracked"
  git -C "$root/repo" add tracked
  git -C "$root/repo" commit --quiet -m 'stranded by an earlier stop'

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" --here 1 1 "" low) >"$output" 2>&1 || rc=$?

  local_head=$(git -C "$root/repo" rev-parse HEAD)
  remote_head=$(git -C "$root/repo" rev-parse refs/remotes/origin/feat/test 2>/dev/null)
  if [ "$rc" -ne 0 ] || [ "$local_head" != "$remote_head" ]; then
    fail "completion does not announce unpushed work"
    printf '  exit: %s  local %s != origin %s\n' "$rc" "$local_head" "$remote_head"
    while IFS= read -r line; do printf '  %s\n' "$line"; done <"$output"
    return
  fi
  pass "completion does not announce unpushed work"
}

test_non_repository_is_rejected() {
  local root="$tmp/non-repository" output="$tmp/non-repository-output" rc=0
  mkdir -p "$root"

  (cd "$root" && NTFY_TOPIC="test" "$script" --here 1) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! not inside a Git repository" "$output"; then
    fail "non-repository working directory is rejected"
    return
  fi
  pass "non-repository working directory is rejected"
}

test_missing_dependency_is_rejected() {
  local root output rc=0
  root=$(setup_case missing-gh)
  output="$root/output"
  rm "$root/bin/gh"
  ln -s "$(command -v bash)" "$root/bin/bash"
  ln -s "$(command -v git)" "$root/bin/git"

  (cd "$root/repo" &&
    PATH="$root/bin" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" --here 1) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! required command not found: gh" "$output"; then
    fail "missing dependency is rejected"
    return
  fi
  pass "missing dependency is rejected"
}

test_temporary_directory_failure_is_reported() {
  local root output rc=0
  root=$(setup_case mktemp-failure)
  output="$root/output"
  cat >"$root/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$root/bin/mktemp"

  (cd "$root/repo" &&
    PATH="$root/bin:$PATH" TEST_STATE="$root/state" NTFY_TOPIC="test" \
      "$script" --here 1) >"$output" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ] || ! grep -Fq "!! Could not create a temporary directory." "$output" ||
     grep -Fq 'unbound variable' "$output"; then
    fail "temporary directory failure is reported"
    return
  fi
  pass "temporary directory failure is reported"
}

test_non_repository_is_rejected
test_missing_dependency_is_rejected
test_temporary_directory_failure_is_reported
test_completion_on_last_allowed_session
test_github_body_failure_stops_run
test_blocker_query_failure_stops_new_issue
test_title_query_failure_stops_new_issue
test_argument_validation
test_invalid_branch_name_is_rejected
test_ambiguous_issue_branches_are_rejected
test_session_branch_switch_is_rejected
test_session_uncommitted_changes_are_rejected
test_here_rejects_preexisting_dirtiness
test_new_dirtiness_outside_starting_subdirectory_is_rejected
test_multiple_completed_checkboxes_are_rejected
test_compensated_checkbox_changes_are_rejected
test_wrong_completed_checkbox_is_rejected
test_rewritten_history_is_rejected
test_followup_checkbox_is_accepted
test_indented_checkbox_is_seen
test_link_bullet_is_not_counted
test_commit_is_pushed_before_the_run_can_stop
test_completion_does_not_announce_unpushed_work

if [ "$failures" -gt 0 ]; then
  printf '%s test(s) failed\n' "$failures" >&2
  exit 1
fi

printf 'all tests passed\n'
