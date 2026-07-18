# Design — telegram-notify plugin

Date: 2026-07-18

## Goal

Repackage a working Claude Code → Telegram notification hook script as an installable
plugin that works on Windows, Linux, and macOS and supports multiple Claude accounts.

## Decisions

| Question | Decision |
|----------|----------|
| Distribution | Single git repo that is both marketplace and plugin (`source: "./"`), like the caveman plugin. Install with `/plugin marketplace add` + `/plugin install`. |
| Config & state location | `~/.telegram-notify/` — one per-user home shared by all accounts, outside the plugin dir so it survives updates. Overridable via `TELEGRAM_NOTIFY_HOME`. |
| LLM summaries | Off by default (`TELEGRAM_LLM_URL` empty). Opt in per machine. Avoids a dead-gateway timeout every turn on hosts that can't reach a given LLM endpoint. |
| Multi-account labels | Auto-derived from `CLAUDE_CONFIG_DIR`; default account shows no label, `~/.claude-alt` shows `alt`. Customizable via `TELEGRAM_ACCOUNT_LABELS` map. |

## Architecture

- **`hooks/hooks.json`** registers three events (`UserPromptSubmit`, `Notification`
  matching `permission_prompt|agent_needs_input`, `Stop`), each running
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/telegram-notify.sh"` async. The `bash …` prefix
  is the portable invocation (Git Bash on Windows, native bash elsewhere), matching the
  official security-guidance plugin.
- **`scripts/telegram-notify.sh`** is the engine. It reads the hook JSON on stdin and
  dispatches on `hook_event_name`; `--test` and `--discover` are maintenance modes.
  Config/state paths anchor to `~/.telegram-notify/`. First run seeds a commented
  `telegram.env` with an **empty** token so hooks stay silent until configured.
- **`commands/telegram-notify.md`** is a `/telegram-notify setup|test|discover|status`
  slash command for configuration UX.
- **`.claude-plugin/{plugin.json,marketplace.json}`** are the manifests.

## Account detection (verified)

The alt account's `projects/` is a junction onto the main account's, so `transcript_path`
cannot distinguish accounts. `CLAUDE_CONFIG_DIR` **is** exported to hook processes, so the
label derives from its basename: `.claude` (or unset) → none; `.claude-alt` → `alt`.

## Path portability

Home resolves from `$HOME`; on Windows Git Bash that is `/c/Users/<you>`. Falls back to
`$USERPROFILE` (via `cygpath -u` when available) if `$HOME` is unset. `hostname` provides
the machine label on all three OSes, with `$COMPUTERNAME` as a Windows fallback.

## Preserved behavior

Machine-name header, per-project auto-created topics with a file-locked topic map,
turn duration, question/reply/done classification, and the Windows UTF-8-via-stdin curl
fix all carry over unchanged.

## Migration from the pre-plugin install

The earlier hand-wired setup put hooks directly in each account's `settings.json` and kept
`telegram-notify.sh` + `telegram.env` under `~/.claude`. When adopting the plugin:

1. Copy the token into `~/.telegram-notify/telegram.env`.
2. After installing the plugin in an account, remove that account's hand-wired Telegram
   hooks from `settings.json` (else it double-notifies).
3. Delete the old `~/.claude/telegram-notify.sh` and `~/.claude/telegram.env`.

## Verification

- JSON validity of all manifests/hooks; `bash -n` on the script.
- Real `--test` send on Windows/Git Bash (machine + account label visible).
- Simulated `Stop` hook by piping a synthetic payload to the script.
- Linux/macOS: correctness by structural inspection only (not run in this environment).
