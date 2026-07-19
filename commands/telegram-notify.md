---
description: Set up, test, or inspect Telegram notifications for Claude Code
argument-hint: "[setup|edit|test|discover|status]"
allowed-tools: Bash, Read, Edit
---

You manage the **telegram-notify** plugin's configuration. The engine script is at
`${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh` and all user config/state lives in
`~/.telegram-notify/` (shared across every Claude account on this machine).

Interpret `$ARGUMENTS` as the subcommand (default to `status` if empty):

## `setup`
1. Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh" --version >/dev/null 2>&1 || true` — actually just run the script once with no input to trigger first-run seeding: `printf '' | bash "${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh"`. This creates `~/.telegram-notify/telegram.env` (with an empty token) if it doesn't exist yet.
2. Read `~/.telegram-notify/telegram.env` and report which required fields are still empty (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`).
3. Tell the user to paste their bot token from @BotFather. When they provide it, set it with an Edit to that file (never echo the token back). Prerequisites: `bash`, `curl`, and `jq` must be on PATH — on Windows these come from Git for Windows plus a `jq` install.
4. If they don't know their chat id, run the `discover` flow below.
5. Finish by running the `test` flow.

## `edit` (also `config`)
Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh" --edit`, creating the file first if needed. It opens `~/.telegram-notify/telegram.env` in `$VISUAL`/`$EDITOR` if set, else a GUI editor launched non-blocking (Notepad on Windows, `open -t` on macOS, `xdg-open` on Linux with a display), so the command returns immediately. On a **headless / non-interactive host** (no GUI and no TTY, e.g. this command running with no terminal) it does NOT launch a blocking terminal editor — it prints the config file path instead. In that case, relay the printed path so the user can open the file directly (or have them set `$EDITOR`/`$VISUAL`). Tell the user which fields to fill in (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) and remind them the plugin re-reads the file on the next hook firing — no restart needed.

## `test`
Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh" --test` and report the result verbatim (it says whether the LLM summary gateway is disabled/reachable and whether the message sent).

## `discover`
Run `bash "${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh" --discover` and show the chat/topic ids it prints. Remind the user that bot privacy mode hides ordinary group messages, so they should post a message starting with `/` in the target topic first, then rerun.

## `status`
Read `~/.telegram-notify/telegram.env` (if present) and report, without revealing the token:
- whether the config file exists and the token is set (yes/no)
- the destination (`TELEGRAM_CHAT_ID`, `TELEGRAM_TOPIC_ID`, `TELEGRAM_TOPIC_MODE`)
- whether LLM summaries are on (`TELEGRAM_LLM_URL` non-empty) or off
- the detected account label rule (from `CLAUDE_CONFIG_DIR`) and machine name
Then remind the user that each Claude account must enable the plugin separately, and all accounts share this one config file.
