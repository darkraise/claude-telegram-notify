#!/usr/bin/env bash
# Sends Claude Code hook events to Telegram.
#   Hook mode:  reads hook JSON on stdin, dispatches on hook_event_name
#   --discover: lists chats/topics the bot can see, to find your IDs
#   --test:     sends a test message to the configured destination
#   --edit:     opens the config file in your default editor
set -uo pipefail

# Config and mutable state live in a stable per-user home, NOT beside the script:
# installed as a plugin the script directory is replaced on every update and is
# shared read-only across accounts. Resolve a home that works on Linux, macOS,
# and Windows Git Bash; override the whole location with TELEGRAM_NOTIFY_HOME.
notify_home() {
  if [ -n "${TELEGRAM_NOTIFY_HOME:-}" ]; then printf '%s' "$TELEGRAM_NOTIFY_HOME"; return; fi
  local h="${HOME:-}"
  if [ -z "$h" ] && [ -n "${USERPROFILE:-}" ]; then
    h=$(cygpath -u "$USERPROFILE" 2>/dev/null || printf '%s' "$USERPROFILE")
  fi
  printf '%s/.telegram-notify' "$h"
}
TELEGRAM_NOTIFY_HOME="$(notify_home)"
CONFIG_FILE="${TELEGRAM_NOTIFY_ENV:-$TELEGRAM_NOTIFY_HOME/telegram.env}"
STATE_DIR="$TELEGRAM_NOTIFY_HOME/state"

# First run: create the home and seed a commented config template with an EMPTY
# token, so hooks stay silent until you configure it. Never overwrites an
# existing file, and skips seeding when TELEGRAM_NOTIFY_ENV points elsewhere.
seed_config() {
  mkdir -p "$TELEGRAM_NOTIFY_HOME" 2>/dev/null || return 0
  [ -n "${TELEGRAM_NOTIFY_ENV:-}" ] && return 0
  [ -f "$CONFIG_FILE" ] && return 0
  cat > "$CONFIG_FILE" 2>/dev/null <<'EOF'
# Telegram notification config for the Claude Code telegram-notify plugin.
# Keep this file private -- it holds your bot token.

# From @BotFather, looks like 123456789:AAE...  (required; empty = notifications off)
TELEGRAM_BOT_TOKEN=

# Target chat id. Supergroups are negative, e.g. -1001234567890
# Find it with the /telegram-notify command, or:  telegram-notify.sh --discover
TELEGRAM_CHAT_ID=

# Forum topic ("channel") id inside the group. Empty posts to the main thread.
TELEGRAM_TOPIC_ID=

# Topic routing: "shared" (all -> TELEGRAM_TOPIC_ID) or "per-project" (each git
# repo auto-creates its own topic; non-repos use the shared topic). per-project
# needs the bot to be a group ADMIN with the Manage Topics right.
TELEGRAM_TOPIC_MODE=shared

# --- Optional LLM turn summaries (OFF by default) ----------------------------
# Leave TELEGRAM_LLM_URL empty to disable. Set it to an OpenAI-compatible base
# URL to summarize turn-end messages into 1-2 sentences; if the gateway is
# unreachable the notification still sends using the message's own lead text.
TELEGRAM_LLM_URL=
TELEGRAM_LLM_MODEL=auto/best-fast
TELEGRAM_LLM_API_KEY=
TELEGRAM_LLM_TIMEOUT=12
TELEGRAM_LLM_MAX_TOKENS=512

# Header labels. Machine name defaults to this host's hostname; account label is
# auto-derived from CLAUDE_CONFIG_DIR (blank for the default account). Uncomment
# to override. To label multiple accounts sharing THIS file, prefer the map:
#   TELEGRAM_ACCOUNT_LABELS={".claude":"main",".claude-alt":"alt"}
# TELEGRAM_MACHINE_NAME=my-laptop
# TELEGRAM_ACCOUNT_LABEL=work

# Set to 1 to append a trace of each hook firing to debug.log in this folder.
# TELEGRAM_DEBUG=1
EOF
  chmod 600 "$CONFIG_FILE" 2>/dev/null || true
}
seed_config

# shellcheck disable=SC1090
[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
: "${TELEGRAM_BOT_TOKEN:=}" "${TELEGRAM_CHAT_ID:=}" "${TELEGRAM_TOPIC_ID:=}"
# LLM summaries are OFF unless TELEGRAM_LLM_URL is set: a LAN or other gateway
# won't exist on every machine, and an empty URL avoids a per-turn timeout.
: "${TELEGRAM_LLM_URL:=}" "${TELEGRAM_LLM_MODEL:=auto/best-fast}"
: "${TELEGRAM_LLM_API_KEY:=}" "${TELEGRAM_LLM_TIMEOUT:=12}" "${TELEGRAM_LLM_MAX_TOKENS:=512}"
: "${TELEGRAM_MAX_CHARS:=3500}"
# Topic routing. "shared": every message goes to TELEGRAM_TOPIC_ID. "per-project":
# each git repo gets its own auto-created topic; non-repos use TELEGRAM_TOPIC_ID.
: "${TELEGRAM_TOPIC_MODE:=shared}"
: "${TELEGRAM_TOPIC_MAP:=$TELEGRAM_NOTIFY_HOME/topics.json}"
# Machine label in the header, so you can tell which host needs attention.
# Defaults to this machine's hostname; set a friendly name to override.
: "${TELEGRAM_MACHINE_NAME:=$(hostname 2>/dev/null)}"
: "${TELEGRAM_MACHINE_NAME:=${COMPUTERNAME:-unknown}}"

# Account label in the header, distinguishing multiple Claude accounts on one
# host. Auto-derived from CLAUDE_CONFIG_DIR: the default account (~/.claude, or
# no override) shows nothing; ~/.claude-alt shows "alt". Force with
# TELEGRAM_ACCOUNT_LABEL (set it empty to disable); an optional
# TELEGRAM_ACCOUNT_LABELS JSON map keyed by config-dir basename wins over the
# derivation and is the right way to label accounts sharing one config file.
resolve_account_label() {
  if [ "${TELEGRAM_ACCOUNT_LABEL+set}" = "set" ]; then
    printf '%s' "$TELEGRAM_ACCOUNT_LABEL"; return 0
  fi
  local dir="${CLAUDE_CONFIG_DIR:-}" base mapped
  [ -n "$dir" ] || return 0
  base=$(basename "$dir")
  if [ -n "${TELEGRAM_ACCOUNT_LABELS:-}" ]; then
    mapped=$(jq -r --arg k "$base" '.[$k] // empty' <<<"$TELEGRAM_ACCOUNT_LABELS" 2>/dev/null)
    [ -n "$mapped" ] && { printf '%s' "$mapped"; return 0; }
  fi
  base="${base#.}"
  case "$base" in
    claude)   return 0 ;;
    claude-*) printf '%s' "${base#claude-}" ;;
    *)        printf '%s' "$base" ;;
  esac
}
TELEGRAM_ACCOUNT_LABEL_RESOLVED="$(resolve_account_label)"

API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"

# Per-notification routing state, set by main(); defaults keep --test on the shared topic.
REPO_KEY=""; REPO_NAME=""; SEND_TOPIC=""

# Opt-in diagnostics: set TELEGRAM_DEBUG=1 to append a trace of each hook firing.
TELEGRAM_DEBUG_LOG="${TELEGRAM_DEBUG_LOG:-$TELEGRAM_NOTIFY_HOME/debug.log}"
dbg() { [ "${TELEGRAM_DEBUG:-0}" = "1" ] && printf '%s [pid %s] | %s\n' "$(date -u +%FT%T.%3NZ)" "$$" "$*" >> "$TELEGRAM_DEBUG_LOG" 2>/dev/null; return 0; }

die() { echo "telegram-notify: $*" >&2; exit 1; }

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Fold newlines/runs of whitespace into single spaces and trim. Models emit
# stray line breaks and leading blanks that read poorly in a notification.
normalize_ws() { tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ +//; s/ +$//'; }

format_duration() {
  local s=${1:-0}
  if   (( s < 60 ));   then printf '%ds' "$s"
  elif (( s < 3600 )); then printf '%dm %ds' $((s / 60)) $((s % 60))
  else                      printf '%dh %dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

# Absolute git repo root of a directory, or empty if not inside a work tree.
git_repo_root() {
  local d="$1"
  [ -n "$d" ] && [ -d "$d" ] || return 0
  git -C "$d" rev-parse --show-toplevel 2>/dev/null
}

# Canonicalize a git remote URL so ssh and https forms of the same repo collapse
# to one key: drop protocol, userinfo, and trailing .git; turn the scp-style
# "host:path" colon into a slash; lowercase. e.g. git@github.com:me/app.git and
# https://github.com/me/app.git both become github.com/me/app.
normalize_remote() {
  printf '%s' "$1" \
    | sed -E 's#\.git/?$##; s#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]+@##; s#:#/#' \
    | tr 'A-Z' 'a-z'
}

# Cross-machine project identity for a repo root: prints "KEY\tNAME".
# KEY is the normalized remote URL (so the same project on any machine maps to
# one topic), or the repo's directory name when no remote is configured — never
# the full path, which differs per machine. NAME (topic title) is the basename.
project_identity() {
  local repo="$1" name url first
  name=$(basename "$repo")
  url=$(git -C "$repo" config --get remote.origin.url 2>/dev/null)
  if [ -z "$url" ]; then
    first=$(git -C "$repo" remote 2>/dev/null | head -1)
    [ -n "$first" ] && url=$(git -C "$repo" config --get "remote.$first.url" 2>/dev/null)
  fi
  if [ -n "$url" ]; then
    printf '%s\t%s' "$(normalize_remote "$url")" "$name"
  else
    printf '%s\t%s' "$name" "$name"
  fi
}

# Create a forum topic; echo its message_thread_id, or empty on any failure
# (e.g. the bot lacks admin/Manage-Topics rights — the caller then falls back).
create_forum_topic() {
  local name="$1" resp
  resp=$(curl -sS --max-time 15 \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "name=${name}" \
    "${API}/createForumTopic" 2>/dev/null) || return 0
  jq -r 'if .ok then (.result.message_thread_id | tostring) else empty end' <<<"$resp" 2>/dev/null
}

# Get-or-create the topic id for a repo (key=$1, name=$2). Serialized with flock
# so concurrent sessions can't create duplicate topics for the same repo. Echoes
# a topic id, or empty to mean "fall back to the shared topic".
resolve_repo_topic() {
  mkdir -p "$(dirname "$TELEGRAM_TOPIC_MAP")" 2>/dev/null
  (
    flock -w 10 9 2>/dev/null
    [ -s "$TELEGRAM_TOPIC_MAP" ] || echo '{}' > "$TELEGRAM_TOPIC_MAP"
    id=$(jq -r --arg k "$1" '.[$k] // empty' "$TELEGRAM_TOPIC_MAP" 2>/dev/null)
    if [ -z "$id" ]; then
      id=$(create_forum_topic "$2")
      if [ -n "$id" ]; then
        tmp="${TELEGRAM_TOPIC_MAP}.tmp.$$"
        jq --arg k "$1" --argjson v "$id" '.[$k] = $v' "$TELEGRAM_TOPIC_MAP" > "$tmp" 2>/dev/null && mv "$tmp" "$TELEGRAM_TOPIC_MAP"
      fi
    fi
    printf '%s' "$id"
  ) 9>>"${TELEGRAM_TOPIC_MAP}.lock"
}

# Forget a repo's topic mapping (used when its topic was deleted in Telegram).
map_remove() {
  ( flock -w 10 9 2>/dev/null
    [ -s "$TELEGRAM_TOPIC_MAP" ] || exit 0
    tmp="${TELEGRAM_TOPIC_MAP}.tmp.$$"
    jq --arg k "$1" 'del(.[$k])' "$TELEGRAM_TOPIC_MAP" > "$tmp" 2>/dev/null && mv "$tmp" "$TELEGRAM_TOPIC_MAP"
  ) 9>>"${TELEGRAM_TOPIC_MAP}.lock"
}

send() {
  local text="$1" topic="${SEND_TOPIC:-$TELEGRAM_TOPIC_ID}"
  local -a args=(
    --silent --show-error --max-time 15
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}"
    --data-urlencode "text@-"
    --data-urlencode "parse_mode=HTML"
    --data-urlencode "link_preview_options={\"is_disabled\":true}"
  )
  # A "topic" in a forum-enabled group is addressed by its thread id.
  [ -n "$topic" ] && args+=(--data-urlencode "message_thread_id=${topic}")
  # Feed the (possibly multi-byte) text via stdin, not an argv value: Git Bash
  # re-encodes command-line arguments to the legacy Windows code page when it
  # spawns native curl.exe, mangling UTF-8 (emoji become "?", "·" becomes a lone
  # 0xB7 that Telegram rejects as "not encoded in UTF-8"). stdin bytes are safe.
  printf '%s' "$text" | curl "${args[@]}" "${API}/sendMessage"
}

# Assemble header + status + body into the final message and send it. The body
# is clamped BEFORE escaping so a cut can never split an HTML entity; the
# header's <b> tags are intentional markup and stay literal. If a per-project
# topic was deleted in Telegram, forget it, recreate, and retry once.
send_message() {
  local header="$1" status="$2" body="$3" text resp
  body=$(clamp "$body" "$TELEGRAM_MAX_CHARS")
  text=$(printf '%s\n%s\n\n%s' "$header" "$status" "$(printf '%s' "$body" | html_escape)")
  resp=$(send "$text")
  if [ -n "$REPO_KEY" ] && grep -q "message thread not found" <<<"$resp"; then
    map_remove "$REPO_KEY"
    SEND_TOPIC=$(resolve_repo_topic "$REPO_KEY" "$REPO_NAME")
    resp=$(send "$text")
  fi
  dbg "   send: ok=$(jq -r '.ok // "?"' <<<"$resp" 2>/dev/null) desc=$(jq -r '.description // ""' <<<"$resp" 2>/dev/null) topic=${SEND_TOPIC:-shared}"
  printf '%s' "$resp"
}

# Last assistant message that actually contains text: the final one is often a
# tool call with no text block, so plain `last` returns empty.
last_assistant_text() {
  local transcript="$1"
  [ -r "$transcript" ] || return 0
  tail -n 400 "$transcript" 2>/dev/null | jq -Rsr '
    split("\n")
    | map(select(length > 0) | fromjson?)
    | map(select(.type == "assistant")
          | .message.content // []
          | map(select(.type == "text") | .text)
          | join("\n"))
    | map(select(. != null and . != ""))
    | last // ""
  ' 2>/dev/null
}

# The final assistant message of the CURRENT turn. The async Stop hook can run
# before Claude Code flushes that message to the transcript, so a naive "last
# assistant text" returns the PREVIOUS turn's message (an off-by-one). The
# turn's final message is the last record with stop_reason=="end_turn" whose
# timestamp is >= this turn's start (recorded at UserPromptSubmit). Poll until
# it appears, then fall back to whatever text exists so a notification is never
# dropped. turn_start of 0 disables the freshness check (no start recorded).
current_turn_final_text() {
  local transcript="$1" turn_start="${2:-0}" i text
  [ -r "$transcript" ] || return 0
  [[ "$turn_start" =~ ^[0-9]+$ ]] || turn_start=0
  for ((i = 0; i < 17; i++)); do
    text=$(tail -n 400 "$transcript" 2>/dev/null | jq -Rsr --argjson start "$turn_start" '
      split("\n") | map(select(length > 0) | fromjson?)
      | map(select(.type == "assistant" and (.message.stop_reason == "end_turn"))
            | { t: (((.timestamp // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601?) // 0),
                txt: (.message.content // [] | map(select(.type == "text") | .text) | join("\n")) })
      | map(select(.txt != "" and .t >= $start))
      | last // {} | .txt // ""' 2>/dev/null)
    [ -n "$text" ] && { dbg "   current_turn_final_text: found fresh end_turn on iter=$i (start=$turn_start)"; printf '%s' "$text"; return 0; }
    sleep 0.3
  done
  # Flush never arrived (pathological): best-effort last assistant text.
  dbg "   current_turn_final_text: TIMED OUT after ${i} iters (start=$turn_start) → fallback last_assistant_text"
  last_assistant_text "$transcript"
}

# A turn that ends on a question is waiting on the user, not finished. Checked
# against the untruncated text, since truncation would eat the trailing "?".
ends_with_question() {
  local last
  last=$(printf '%s' "$1" | grep -vE '^[[:space:]]*$' | tail -n 1)
  [[ "$last" =~ \?[[:space:]\*\_\`\"\)]*$ ]]
}

# Final safety clip on the assembled message so a send never trips Telegram's
# 4096-char hard limit. With 512-token summaries this effectively never fires.
clamp() {
  local text="$1" limit="$2"
  if (( ${#text} > limit )); then
    printf '%s… (truncated)' "${text:0:$limit}"
  else
    printf '%s' "$text"
  fi
}

# Classify a finished turn and summarize it, via the OpenAI-compatible gateway.
# Emits a compact JSON object {"kind","summary"} where kind is work | reply |
# question, so the caller can label it correctly and never frame an explanation
# as work performed. On any failure — gateway down, timeout, unparseable reply —
# echoes nothing so the caller falls back to a heuristic.
llm_classify() {
  local text="$1" sys body reply
  [ -n "$text" ] || return 0
  # Summaries are opt-in: no gateway configured means fall back to lead text.
  [ -n "$TELEGRAM_LLM_URL" ] || return 0
  sys='You write a phone notification about what a coding assistant just did or said. Read its final message and reply with ONLY a JSON object: {"kind":"...","summary":"..."}. kind is "work" if the assistant performed actions (edited or wrote code, ran commands, fixed or built something, completed a task); "question" if it is asking the user to choose or decide something; "reply" if it answered a question, explained a concept, or discussed something WITHOUT performing actions. summary: 1-3 plain sentences, no markdown, no lead-ins like "The assistant". For "reply", summarize what was explained or answered and NEVER describe an explanation as an action performed (do not say it generated, created, or built something it only described). For "question", state what is asked and the options. Describe any commands or code in words, not verbatim. Use only facts in the message; never invent.'

  body=$(jq -n --arg s "$sys" --arg m "$text" --arg model "$TELEGRAM_LLM_MODEL" \
    --argjson mt "$TELEGRAM_LLM_MAX_TOKENS" \
    '{stream:false, model:$model, temperature:0.2, max_tokens:$mt,
      messages:[{role:"system",content:$s},{role:"user",content:$m}]}' 2>/dev/null) || return 0

  local -a auth=()
  [ -n "$TELEGRAM_LLM_API_KEY" ] && auth=(-H "Authorization: Bearer ${TELEGRAM_LLM_API_KEY}")

  reply=$(curl -sS --max-time "$TELEGRAM_LLM_TIMEOUT" \
    -H 'Content-Type: application/json' "${auth[@]}" \
    -d "$body" "${TELEGRAM_LLM_URL%/}/chat/completions" 2>/dev/null) || return 0

  # The model may wrap the JSON in ``` fences or add prose; extract and validate.
  printf '%s' "$reply" | jq -r '.choices[0].message.content // empty' 2>/dev/null \
    | jq -Rs '(fromjson? // (capture("(?<j>\\{[\\s\\S]*\\})").j | fromjson?)) // empty
              | if type=="object" and (.kind|type)=="string" and (.summary|type)=="string"
                then {kind, summary} else empty end' 2>/dev/null
}

# The pending action behind a permission/input Notification, as a compact JSON
# object: {sidechain, tool, n, target, question, options}. The Notification
# payload carries no tool detail, so this reads the transcript for the tool the
# user is actually being asked about.
#
# "Pending" means UNRESOLVED: a tool_use with no matching tool_result yet — one
# Claude is blocked on. This matters because the tool_use write can lag the
# notification (the same flush race the Stop handler guards against): taking the
# plain last tool_use would, in that window, report the previous already-run tool
# instead (e.g. an old "git commit" Bash shown while the screen is really on an
# AskUserQuestion). So we skip any tool_use that already has a result and poll
# until the genuinely pending one appears. "▸ Tool: target" plus " (+N more)"
# when several tools are pending at once; `sidechain` marks a subagent-issued
# call; AskUserQuestion fills question/options instead of a run target.
pending_action() {
  local transcript="$1" i out tries="${TELEGRAM_PENDING_TRIES:-17}"
  [ -r "$transcript" ] || return 0
  for ((i = 0; i < tries; i++)); do
    out=$(tail -n 400 "$transcript" 2>/dev/null | jq -Rsr '
      # .message.content is usually an array of blocks, but a user turn can carry
      # a bare string (e.g. slash-command output); normalize before iterating.
      def content_blocks: (.message.content // []) | if type == "array" then . else [] end;
      ( split("\n") | map(select(length > 0) | fromjson?) ) as $rows
      | ( [ $rows[] | select(.type == "user")
            | content_blocks[] | select(.type == "tool_result") | .tool_use_id ] ) as $resolved
      | ( [ $rows[] | select(.type == "assistant") | . as $msg
            | ( content_blocks
                | map(select(.type == "tool_use")
                      | select((.id) as $id | ($resolved | index($id)) == null)) ) as $pending
            | select(($pending | length) > 0)
            | { sc: ($msg.isSidechain == true), tools: $pending } ] | last ) as $hit
      | if $hit == null then empty else
          $hit.tools as $tools
          | $tools[0] as $t | ($t.input // {}) as $in
          | (if   $t.name == "Bash" then ($in.command // "")
             elif $t.name == "WebFetch" then ($in.url // "")
             elif ($t.name | test("Edit|Write|Read|NotebookEdit")) then ($in.file_path // $in.notebook_path // "")
             elif ($t.name | test("Glob|Grep")) then ($in.pattern // "")
             else "" end) as $raw
          | ($raw | gsub("\\s+"; " ")) as $flat
          | { sidechain: $hit.sc, tool: $t.name, n: ($tools | length),
              target: (if ($flat | length) > 150 then $flat[0:150] + "…" else $flat end),
              question: (if $t.name == "AskUserQuestion" then ($in.questions[0].question // "") else "" end),
              options: (if $t.name == "AskUserQuestion" then [ ($in.questions[0].options // [])[].label ] else [] end) }
          | @json
        end' 2>/dev/null)
    [ -n "$out" ] && { printf '%s' "$out"; return 0; }
    sleep 0.3
  done
}

discover() {
  [ -n "$TELEGRAM_BOT_TOKEN" ] || die "TELEGRAM_BOT_TOKEN is not set in $CONFIG_FILE"
  local me
  me=$(curl -sS --max-time 15 "${API}/getMe")
  if [ "$(jq -r '.ok' <<<"$me")" != "true" ]; then
    die "getMe failed: $(jq -r '.description // "unknown error"' <<<"$me")"
  fi
  echo "Bot: @$(jq -r '.result.username' <<<"$me")"
  echo
  echo "Chats visible in recent updates:"
  curl -sS --max-time 15 "${API}/getUpdates" | jq -r '
    [ .result[]
      | (.message // .channel_post // .edited_message // empty)
      | { chat_id: .chat.id,
          title: (.chat.title // .chat.username // .chat.first_name // "?"),
          type: .chat.type,
          topic_id: (.message_thread_id // null),
          topic_name: (.reply_to_message.forum_topic_created.name // null) }
    ] | unique | .[]
    | "  TELEGRAM_CHAT_ID=\(.chat_id)"
      + (if .topic_id then "  TELEGRAM_TOPIC_ID=\(.topic_id)" else "" end)
      + "   # \(.type): \(.title)"
      + (if .topic_name then " / topic: \(.topic_name)" else "" end)
  '
  echo
  echo "Nothing listed? Post a message starting with / (e.g. /start) in the exact"
  echo "topic you want, then rerun. Bot privacy mode hides ordinary group messages."
}

main() {
  local payload event cwd project session
  payload=$(cat)

  # Never let a notification failure disturb the session.
  exec 1>/dev/null 2>&1

  [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] || exit 0

  event=$(jq -r '.hook_event_name // ""' <<<"$payload" 2>/dev/null)
  session=$(jq -r '.session_id // "unknown"' <<<"$payload" 2>/dev/null)
  cwd=$(jq -r '.cwd // ""' <<<"$payload" 2>/dev/null)
  project=$(basename "${cwd:-$PWD}")

  dbg "── EVENT=$event session=${session:0:8} pid=$$"

  # Route to a per-project topic when enabled and the cwd is a git repo; a
  # non-repo, a create failure, or a deleted topic all fall back to the shared
  # topic (SEND_TOPIC left empty → send() uses TELEGRAM_TOPIC_ID).
  if [ "$TELEGRAM_TOPIC_MODE" = "per-project" ] && [ "$event" != "UserPromptSubmit" ]; then
    local repo_root
    repo_root=$(git_repo_root "$cwd")
    if [ -n "$repo_root" ]; then
      IFS=$'\t' read -r REPO_KEY REPO_NAME <<<"$(project_identity "$repo_root")"
      project="$REPO_NAME"
      SEND_TOPIC=$(resolve_repo_topic "$REPO_KEY" "$REPO_NAME")
    fi
  fi
  dbg "   route: mode=$TELEGRAM_TOPIC_MODE repo=${REPO_KEY:-none} topic=${SEND_TOPIC:-shared(${TELEGRAM_TOPIC_ID:-none})}"

  mkdir -p "$STATE_DIR"
  local start_file="$STATE_DIR/${session}.start"

  local header
  header=$(printf '📁 <b>%s</b> · 💻 %s' \
    "$(printf '%s' "$project" | html_escape)" \
    "$(printf '%s' "$TELEGRAM_MACHINE_NAME" | html_escape)")
  [ -n "$TELEGRAM_ACCOUNT_LABEL_RESOLVED" ] && \
    header="$header · 👤 $(printf '%s' "$TELEGRAM_ACCOUNT_LABEL_RESOLVED" | html_escape)"

  case "$event" in
    UserPromptSubmit)
      date +%s > "$start_file"
      ;;

    Notification)
      local ntype transcript status body action tool sidechain q opts n target
      ntype=$(jq -r '.notification_type // ""' <<<"$payload" 2>/dev/null)
      transcript=$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)
      if [ "$ntype" = "permission_prompt" ]; then
        action=$(pending_action "$transcript")
        tool=$(jq -r '.tool // ""' <<<"$action" 2>/dev/null)
        sidechain=$(jq -r '.sidechain // false' <<<"$action" 2>/dev/null)
        if [ "$tool" = "AskUserQuestion" ]; then
          # A question is waiting, not a tool to approve — present it as one.
          status="❓ Needs your input"
          q=$(jq -r '.question // ""' <<<"$action" 2>/dev/null)
          opts=$(jq -r '(.options // []) | join(" / ")' <<<"$action" 2>/dev/null)
          body="$q"
          [ -n "$opts" ] && body="$q"$'\n\n'"Options: $opts"
        elif [ -n "$tool" ]; then
          status="🔐 Needs permission"
          n=$(jq -r '.n // 1' <<<"$action" 2>/dev/null)
          target=$(jq -r '.target // ""' <<<"$action" 2>/dev/null)
          body="▸ $tool"
          [ -n "$target" ] && body="▸ $tool: $target"
          [ "${n:-1}" -gt 1 ] 2>/dev/null && body="$body (+$((n - 1)) more)"
        else
          status="🔐 Needs permission"
          body=$(jq -r '.message // "Claude is waiting for your approval."' <<<"$payload" 2>/dev/null)
        fi
        # Mark subagent-issued prompts so they are distinct from the main session.
        [ "$sidechain" = "true" ] && header="$header ⤷ <i>subagent</i>"
      else
        status="🔔 Needs you"
        body=$(jq -r '.message // "Claude is waiting for you."' <<<"$payload" 2>/dev/null)
      fi
      send_message "$header" "$status" "$body"
      ;;

    Stop)
      local transcript full kind status body duration="" turn_start="" now
      transcript=$(jq -r '.transcript_path // ""' <<<"$payload" 2>/dev/null)

      if [ -r "$start_file" ]; then
        turn_start=$(cat "$start_file")
        [[ "$turn_start" =~ ^[0-9]+$ ]] || turn_start=""
        rm -f "$start_file"
      fi

      # Primary source: the last_assistant_message field Claude Code puts in the
      # Stop payload. It is the authoritative in-memory final message, immune to
      # the transcript flush race and independent of turn_start. Fall back to
      # the transcript only if the field is absent (older Claude Code).
      full=$(jq -r '
        (.last_assistant_message // empty) as $m
        | if   ($m | type) == "string" then $m
          elif ($m | type) == "array"  then ($m | map(select((.type // "") == "text") | .text) | join("\n"))
          elif ($m | type) == "object" then
            ( ($m.content // $m.text // $m.message // "")
              | if   type == "array"  then (map(select((.type // "") == "text") | .text) | join("\n"))
                elif type == "string" then .
                else "" end )
          else "" end' <<<"$payload" 2>/dev/null)

      dbg "   Stop: turn_start=${turn_start:-none} lam_type=$(jq -r '.last_assistant_message | type' <<<"$payload" 2>/dev/null) lam_len=${#full}"
      dbg "   lam[0:70]=$(printf '%s' "$full" | head -c 70 | tr '\n' ' ')"

      if [ -z "$full" ]; then
        full=$(current_turn_final_text "$transcript" "${turn_start:-0}")
        dbg "   fell back to transcript; full[0:70]=$(printf '%s' "$full" | head -c 70 | tr '\n' ' ')"
      fi

      # Classify + summarize in one gateway call. kind drives the label so a
      # conversational turn reads "Replied", not a fabricated "Done".
      local classified
      classified=$(llm_classify "$full")
      if [ -n "$classified" ]; then
        kind=$(jq -r '.kind // "work"' <<<"$classified" 2>/dev/null)
        body=$(jq -r '.summary // ""' <<<"$classified" 2>/dev/null | normalize_ws)
      else
        # Gateway down / unparseable: heuristic label + the message's own lead.
        if ends_with_question "$full"; then kind=question; else kind=work; fi
        if [ -n "$full" ]; then body=$(printf '%s' "$full" | normalize_ws)
        else body="(no text in final response)"; fi
      fi

      case "$kind" in
        question) status="❓ Waiting on you" ;;
        reply)    status="💬 Replied" ;;
        *)        status="✅ Done" ;;
      esac

      if [ -n "$turn_start" ]; then
        now=$(date +%s)
        (( now >= turn_start )) && duration=$(format_duration $((now - turn_start)))
      fi
      [ -n "$duration" ] && status="$status · $duration"

      send_message "$header" "$status" "$body"
      ;;
  esac
  exit 0
}

# Open the config file in the user's editor. Honors $VISUAL/$EDITOR when set;
# otherwise falls back to a per-platform GUI default launched non-blocking so it
# never hangs a non-interactive caller (Notepad via `start`, macOS `open -t`,
# Linux `xdg-open`, with a terminal editor as the last resort where no GUI is up).
open_editor() {
  local f="$1"
  if [ -n "${VISUAL:-}" ]; then "$VISUAL" "$f"; return; fi
  if [ -n "${EDITOR:-}" ]; then "$EDITOR" "$f"; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      cmd //c start "" notepad "$(cygpath -w "$f" 2>/dev/null || printf '%s' "$f")" ;;
    Darwin) open -t "$f" ;;
    *)
      if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        xdg-open "$f"
      elif command -v nano >/dev/null 2>&1; then nano "$f"
      else vi "$f"; fi ;;
  esac
}

# Only dispatch when executed directly; when sourced (e.g. by tests) just define
# the functions above and return, so callers can exercise them in isolation.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    --discover) discover ;;
    --edit|--config)
      if [ ! -f "$CONFIG_FILE" ]; then
        mkdir -p "$(dirname "$CONFIG_FILE")" 2>/dev/null || true
        : > "$CONFIG_FILE" && chmod 600 "$CONFIG_FILE" 2>/dev/null || true
      fi
      echo "Opening $CONFIG_FILE in your editor…"
      open_editor "$CONFIG_FILE"
      ;;
    --test)
      [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ] \
        || die "Set TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID in $CONFIG_FILE first"
      sample='Fixed the failing checkout flow: applyDiscount in cart.ts mutated the shared cart, so a second coupon stacked on stale state. It now returns a new cart, three call sites were updated, and a regression test was added. All 42 tests pass.'
      if [ -z "$TELEGRAM_LLM_URL" ]; then
        echo "LLM summaries disabled (TELEGRAM_LLM_URL empty) — sending with the message's own lead text."
        body=$(printf '%s' "$sample" | normalize_ws)
      else
        classified=$(llm_classify "$sample")
        if [ -n "$classified" ]; then
          echo "LLM gateway OK ($TELEGRAM_LLM_MODEL): kind=$(jq -r .kind <<<"$classified"), summary=$(jq -r .summary <<<"$classified")"
          body=$(jq -r '.summary' <<<"$classified" | normalize_ws)
        else
          echo "LLM gateway unreachable at $TELEGRAM_LLM_URL — sending with fallback text."
          body=$(printf '%s' "$sample" | normalize_ws)
        fi
      fi
      test_header=$(printf '📁 <b>test-project</b> · 💻 %s' "$(printf '%s' "$TELEGRAM_MACHINE_NAME" | html_escape)")
      [ -n "$TELEGRAM_ACCOUNT_LABEL_RESOLVED" ] && \
        test_header="$test_header · 👤 $(printf '%s' "$TELEGRAM_ACCOUNT_LABEL_RESOLVED" | html_escape)"
      resp=$(send_message "$test_header" "✅ Done · 2m 14s" "$body")
      if [ "$(jq -r '.ok' <<<"$resp")" = "true" ]; then
        echo "Sent. Check your Telegram destination."
      else
        die "Telegram rejected it: $(jq -r '.description // "unknown"' <<<"$resp")"
      fi
      ;;
    "") main ;;
    *) die "unknown option: $1 (use --discover, --test, --edit, or pipe hook JSON on stdin)" ;;
  esac
fi
