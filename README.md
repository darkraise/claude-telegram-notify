# telegram-notify — a Claude Code plugin

Push a Telegram message when a Claude Code session **finishes a turn**, **ends on a
question**, or **needs your attention** (a permission prompt or an agent asking for
input). Works on **Windows, Linux, and macOS**, is **multi-account aware**, and can
optionally summarize each turn with an OpenAI-compatible LLM.

```
📁 my-api · 💻 host · 👤 alt      📁 my-api · 💻 host        📁 my-api · 💻 host
✅ Done · 2m 14s                   ❓ Waiting on you           🔐 Needs permission

<turn summary / lead text>         <the question + options>    ▸ Bash: <command>
```

The header's first line is `📁 project · 💻 machine · 👤 account`, so a notification
tells you at a glance which project, on which host, under which account needs you.
(The account segment is hidden for your default account.)

## Requirements

The hook runs through **bash**, and the script uses `curl` and `jq`. All three must be
on `PATH`:

- **Linux/macOS:** `curl` and `jq` from your package manager (`apt install jq`,
  `brew install jq`, …). bash is already present.
- **Windows:** install **Git for Windows** (provides Git Bash + `curl`) and **jq**
  (`winget install jqlang.jq`). The plugin invokes `bash …`, which resolves to Git
  Bash's `bash.exe` as long as it's on `PATH`.

## Install

This repository is both a **marketplace** and the **plugin**. On any machine:

```
/plugin marketplace add https://github.com/darkraise/claude-telegram-notify
/plugin install telegram-notify@telegram-notify
```

Then configure and test:

```
/telegram-notify setup
```

That seeds `~/.telegram-notify/telegram.env`, walks you through pasting your bot token,
helps you find your chat id, and sends a test message. To change settings later, run
`/telegram-notify edit` to open that config file in your default editor. You can also
re-run `/telegram-notify test`, `/telegram-notify discover`, or `/telegram-notify
status` any time.

### Manual configuration (alternative to `/telegram-notify setup`)

The first hook firing creates `~/.telegram-notify/telegram.env` with an empty token
(so notifications stay silent until configured). Open it in your default editor with
`/telegram-notify edit` (or `bash scripts/telegram-notify.sh --edit`) and set at least:

```
TELEGRAM_BOT_TOKEN=123456789:AAE...      # from @BotFather
TELEGRAM_CHAT_ID=-1001234567890          # from: bash scripts/telegram-notify.sh --discover
```

Send a test:

```
bash scripts/telegram-notify.sh --test
```

## Where things live

Everything the plugin *writes* lives outside the plugin directory, in one per-user
home that all accounts share and that survives plugin updates:

```
~/.telegram-notify/
├── telegram.env      your token + settings (chmod 600)
├── topics.json       per-project topic map (per-project mode)
├── state/            per-session turn-start timestamps
└── debug.log         only when TELEGRAM_DEBUG=1
```

Override the whole location with `TELEGRAM_NOTIFY_HOME`, or point at a specific config
file with `TELEGRAM_NOTIFY_ENV`.

## Multiple Claude accounts

Each account (each `CLAUDE_CONFIG_DIR`) enables the plugin independently — run the
`/plugin install` line above once per account. Because a plugin registers its own hooks,
you never hand-edit `settings.json`, so there's no shared-file breakage between accounts.

All accounts share the single `~/.telegram-notify/telegram.env` (one token, one
destination). Messages are told apart by the **account label**, auto-derived from
`CLAUDE_CONFIG_DIR`:

- the **default** account (`~/.claude`, or no `CLAUDE_CONFIG_DIR`) shows **no label**
- `~/.claude-alt` shows `👤 alt`

To customize labels for accounts that share the one config file, set a map:

```
TELEGRAM_ACCOUNT_LABELS={".claude":"main",".claude-alt":"alt"}
```

`TELEGRAM_ACCOUNT_LABEL=<name>` forces one label everywhere (set it empty to hide the
segment). Don't put that in the shared file if you want per-account labels — use the map.

## The three hook events

| Event | Fires when | Message |
|-------|-----------|---------|
| `UserPromptSubmit` | You submit a prompt | silent — only starts the duration timer |
| `Notification` (`permission_prompt\|agent_needs_input`) | A prompt needs approval or an agent needs input | 🔐 / ❓ |
| `Stop` | Claude finishes a turn | ✅ Done, 💬 Replied, or ❓ Waiting on you if it ends on a question |

## Optional LLM turn summaries

Off by default. Set `TELEGRAM_LLM_URL` to an OpenAI-compatible base URL (and
`TELEGRAM_LLM_API_KEY` if it needs one) to have turn-end messages summarized into 1–2
sentences. If the gateway is unreachable, the notification still sends using the
message's own opening lines — nothing is lost, just less polished.

## Config reference (`~/.telegram-notify/telegram.env`)

| Variable | Default | Meaning |
|----------|---------|---------|
| `TELEGRAM_BOT_TOKEN` | — | Bot token from @BotFather (required). |
| `TELEGRAM_CHAT_ID` | — | Target chat id (negative for supergroups). |
| `TELEGRAM_TOPIC_ID` | *(empty)* | Forum topic id; empty posts to the main thread. |
| `TELEGRAM_TOPIC_MODE` | `shared` | `shared` or `per-project`. |
| `TELEGRAM_LLM_URL` | *(empty = off)* | OpenAI-compatible gateway base URL for summaries. |
| `TELEGRAM_LLM_MODEL` | `auto/best-fast` | Model used for summaries. |
| `TELEGRAM_LLM_API_KEY` | *(empty)* | Sent as `Authorization: Bearer` only if set. |
| `TELEGRAM_LLM_TIMEOUT` | `12` | Seconds before falling back to lead text. |
| `TELEGRAM_LLM_MAX_TOKENS` | `512` | Summary length ceiling. |
| `TELEGRAM_MAX_CHARS` | `3500` | Final-message safety clip, under Telegram's 4096. |
| `TELEGRAM_MACHINE_NAME` | *(hostname)* | `💻` label in the header. |
| `TELEGRAM_ACCOUNT_LABEL` | *(auto)* | `👤` label; forces a value everywhere, empty hides it. |
| `TELEGRAM_ACCOUNT_LABELS` | *(none)* | JSON map of config-dir basename → label. |
| `TELEGRAM_NOTIFY_HOME` | `~/.telegram-notify` | Where config/state live. |
| `TELEGRAM_NOTIFY_ENV` | *(unset)* | Explicit path to the config file. |
| `TELEGRAM_DEBUG` | `0` | `1` traces each hook firing to `debug.log`. |

## Notes and gotchas

- **UTF-8 on Windows.** The script sends the message body over stdin, not on the curl
  command line, because Git Bash re-encodes argv to the legacy code page and mangles
  emoji / `·`. If you hand-edit the send path, keep UTF-8 text off the curl argv.
- **Per-project mode** needs the bot to be a group admin with Manage Topics; otherwise
  it falls back to the shared topic. Non-git folders always use the shared topic.
- **Same bot on many machines is fine** — sending has no polling conflict. Only
  `--discover` (getUpdates) can conflict with another long-poller.
