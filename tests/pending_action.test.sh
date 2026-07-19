#!/usr/bin/env bash
# Tests for pending_action(): it must describe the tool the user is ACTUALLY
# being asked to approve/answer, never a stale, already-resolved tool_use left in
# the transcript by an earlier step.
#
# Regression: a permission notification once showed an old "git add && git commit"
# Bash command while the screen was actually on an AskUserQuestion, because the
# AskUserQuestion tool_use had not yet flushed to the transcript and the function
# returned the most recent *already-resolved* tool instead.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/telegram-notify.sh"
FIXTURES="$HERE/fixtures"

# Isolate from the real config/token, and keep the flush-wait poll short.
export TELEGRAM_NOTIFY_ENV="$(mktemp -u)"
export TELEGRAM_PENDING_TRIES=2
# shellcheck disable=SC1090
source "$SCRIPT"

pass=0 fail=0
field() { # field <json-or-empty> <jq-expr>
  local o="$1"
  [ -n "$o" ] || { printf 'EMPTY'; return; }
  jq -r "$2" <<<"$o" 2>/dev/null || printf 'EMPTY'
}
check() { # check <name> <got> <want>
  if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else printf 'FAIL - %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$3" "$2"; fail=$((fail + 1)); fi
}

# 1. Only a resolved Bash (+ trailing text) exists → nothing is pending.
out=$(pending_action "$FIXTURES/stale_resolved_bash.jsonl")
check "resolved-only transcript yields NO pending action" \
  "$(field "$out" '.tool // "EMPTY"')" "EMPTY"

# 2. A resolved Bash precedes an unresolved AskUserQuestion → report the question.
out=$(pending_action "$FIXTURES/pending_askquestion.jsonl")
check "unresolved AskUserQuestion wins over the older resolved Bash (tool)" \
  "$(field "$out" '.tool // "EMPTY"')" "AskUserQuestion"
check "unresolved AskUserQuestion reports its question text" \
  "$(field "$out" '.question // "EMPTY"')" "Which execution approach do you want?"

# 3. A single unresolved Bash → normal permission prompt still works.
out=$(pending_action "$FIXTURES/pending_bash.jsonl")
check "unresolved Bash is reported as pending (tool)" \
  "$(field "$out" '.tool // "EMPTY"')" "Bash"
check "unresolved Bash reports its command target" \
  "$(field "$out" '.target // "EMPTY"')" "rm -rf /tmp/scratch"

# 4. A user message whose content is a bare string (e.g. slash-command output)
#    must not break the resolved-id scan; the unresolved AskUserQuestion still wins.
out=$(pending_action "$FIXTURES/pending_with_string_user_content.jsonl")
check "string-content user message does not break iteration (tool)" \
  "$(field "$out" '.tool // "EMPTY"')" "AskUserQuestion"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
