#!/usr/bin/env bash
# Tests for open_editor(): on a headless / non-interactive host (no GUI opener, no
# controlling TTY, and no $VISUAL/$EDITOR) it must NOT launch a blocking terminal
# editor (nano/vi) -- those need a terminal and would hang when `--edit` is run
# without a TTY (e.g. from the slash command). Instead it prints the config path
# and returns non-zero. An explicitly set $EDITOR is always honored.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../scripts/telegram-notify.sh"

export TELEGRAM_NOTIFY_ENV="$(mktemp -u)"   # isolate from the real config/token
# shellcheck disable=SC1090
source "$SCRIPT"

TMP="$(mktemp -d)"
CFG="$TMP/telegram.env"; : > "$CFG"

pass=0 fail=0
check() { if [ "$2" = "$3" ]; then printf 'ok   - %s\n' "$1"; pass=$((pass + 1))
  else printf 'FAIL - %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$3" "$2"; fail=$((fail + 1)); fi; }

# Force the Linux/other branch regardless of the host OS.
uname() { echo Linux; }

# 1. Headless: no display, no editor env, non-interactive stdin/stdout, and both
#    nano and vi "available" as stubs -- neither may be launched.
NANO_MARK="$TMP/nano.called"; VI_MARK="$TMP/vi.called"
nano() { echo called > "$NANO_MARK"; }
vi()   { echo called > "$VI_MARK"; }
unset VISUAL EDITOR DISPLAY WAYLAND_DISPLAY 2>/dev/null || true

out=$(open_editor "$CFG" </dev/null); rc=$?
check "headless: returns non-zero (launched no editor)" "$([ "$rc" -ne 0 ] && echo yes || echo no)" "yes"
check "headless: did NOT run nano" "$([ -e "$NANO_MARK" ] && echo ran || echo skipped)" "skipped"
check "headless: did NOT run vi"   "$([ -e "$VI_MARK" ] && echo ran || echo skipped)" "skipped"
check "headless: printed the config path" "$(printf '%s' "$out" | grep -qF "$CFG" && echo yes || echo no)" "yes"

# 2. An explicit $EDITOR is honored (even non-interactively).
ED_MARK="$TMP/editor.arg"
cat > "$TMP/fake-editor.sh" <<EOF
#!/usr/bin/env bash
printf '%s' "\$1" > "$ED_MARK"
EOF
chmod +x "$TMP/fake-editor.sh"
export EDITOR="$TMP/fake-editor.sh"
open_editor "$CFG" </dev/null; rc=$?
check "explicit \$EDITOR is invoked with the file" "$(cat "$ED_MARK" 2>/dev/null)" "$CFG"
check "explicit \$EDITOR path returns success" "$rc" "0"
unset EDITOR

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
