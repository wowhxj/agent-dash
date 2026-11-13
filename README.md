# agent-dash

English | [简体中文](README.zh-CN.md)

Chat with coding agents natively in Emacs, and browse every agent's sessions in one place. One package, all backends built in:

| Backend | How it runs | `C-c C-q` |
|---|---|---|
| Pi | `pi --mode rpc` in a detached holder | Stops the agent after confirmation |
| Claude Code | `claude -p` stream-json in a detached holder | Stops the agent after confirmation |
| Codex | `codex app-server` in a detached holder | Stops the agent after confirmation |
| Hermes | `hermes acp` in a detached holder | Stops the agent after confirmation |
| DSH | Local DSH Host (Desktop bridge, or `dsh web` in a detached holder) | Only closes the chat |

Killing a chat buffer or quitting Emacs never stops an agent. Opening the session again reattaches to the same running instance. Design notes (Chinese): [docs/DESIGN.md](docs/DESIGN.md).

## Installation

Requires Emacs 29.1+, `markdown-mode`, `websocket`, `transient`, and the CLIs of the agents you use. Verified on macOS. Windows is not supported (FIFOs and POSIX processes).

```elisp
(use-package agent-dash
  :vc (:url "https://github.com/wowhxj/agent-dash" :rev :newest)
  :commands (agent-dash agent-dash-hub))
```

## Usage

- `M-x agent-dash`: pick an agent and a directory, then start a new session.
- `M-x agent-dash-hub`: list the sessions of every agent.

### Chat buffer

User turns are highlighted; the bottom `You>` composer stays editable while history is read-only. The latest prompt is pinned above the conversation. Tools and thinking-only messages are grouped under `Process · N steps` per user turn; `RET`/`TAB` on the heading expands the group, then on a tool/thinking line expands its details. Final answers remain visible.

All five backends share the same layout: statistics on the top left, provider/model and thinking level on the top right; the bottom mode line uses a compact activity indicator such as `Pi thinking |`, shared by all backends. Its `|/-\` animation runs only while active; idle/disconnected chats have no animation. Queues (`[S1 F2]`) and pending requests (`?1`) appear only when present; detailed phases and action hints are available on hover. Narrow windows drop lower-priority metrics first. The composer uses the same theme-derived background and no-underline face as emacs-pi. Pi reports cached context usage, session token totals, cache-read ratio and estimated cost (not a bill), refreshed on attachment and when it settles. DSH restores context, turns/steps, decoding speed, token totals and cache ratio from Host projections, with live control-stream updates; its right side also shows the agent preset and permission mode. DSH billing buckets are summed once, and no cost is invented. Unavailable backend statistics are omitted. Display redraws never issue RPC or model calls. The activity tooltip distinguishes phases such as `waiting for model` and `responding` without adding verbose text to the mode line. `M-x agent-dash-refresh-chat` rebuilds an open chat's presentation without restarting the agent or discarding its draft.

This is not yet full interaction parity with emacs-pi/emacs-claude: clipboard image UI and queue editing remain unimplemented.

| Key | Action |
|---|---|
| `RET` / `C-c C-c` | Send; while the agent runs, queue as a follow-up |
| `S-RET` | Newline |
| `C-c C-s` | Steer the running task |
| `C-c C-k` | Stop the current task |
| `C-c C-q` | Quit (see the table above) |
| `C-c C-a` | Answer permission requests and questions (mode line shows `?N`) |
| `C-c C-r` | Resume a saved session |
| `C-c C-b` | Switch to another chat |
| `C-c @` | Pick a cross-agent session reference |
| `/`, `@`, `@session`, `@dash` + `TAB` | Minibuffer completion (Vertico/Orderless) |
| `C-u TAB` | Refresh the backend command catalog |
| `i` outside the composer / `C-c C-i` anywhere | Focus the composer (inside it, `i` types normally) |
| `M-p` / `M-n` | Browse sent prompts |
| `TAB` / `RET` on a tool or thinking line | Fold / unfold |
| `M-x agent-dash-select-model` | Switch model |

### Input completion

- `/` + `TAB`: shared client commands (`/help`, `/new`, `/resume`, `/dash`, `/stop`, `/quit`, plus `/model` where supported) and the backend's advertised commands/skills. Select a command, then `RET` to execute it. Client commands take no arguments and open their picker when applicable.
- `@` + `TAB`: project files, or a session-reference picker. Paths containing spaces are quoted.
- `@session` + `TAB`: saved sessions of the current agent, across projects.
- `@dash` + `TAB`: sessions of all agents from the shared Hub inventory. Match agent, project, summary, latest prompt or id; selected references attach the saved conversation when sent.

Pickers use `completing-read`: existing Vertico is respected and optional Orderless is enabled locally without changing global settings. `C-g` preserves the draft; background output cannot shift the replacement region. Completion reads catalogs, not models. Pi commands use `get_commands` (and RPC for `/compact`); Claude uses its initialization catalog; DSH uses Host commands and registered skills; Hermes uses ACP-advertised commands. Codex currently offers the shared client commands, not an emulation of its CLI-only slash menu. DSH Host command results are displayed; registered skills are submitted as prompts.

### Hub

History discovery includes Pi's flat, project and nested JSONL layouts, Codex's latest native state index (including archived/subagent/metadata-only threads), DSH's empty sessions, and Hermes CLI history from its native index. Empty, internal and archived sessions count as loaded and are then filtered by the hub. Codex and Hermes index reads require `sqlite3` and use `-readonly`; Codex falls back to a paginated, all-source app-server listing when no index exists. Native stores are not modified. Use `!` for per-source read warnings.

`M-x agent-dash-hub` fills the frame with every saved session, grouped by project. Columns: agent, `●` live, date (`*` = source time, not a message time), short ID, project, summary (falls back to the first prompt), latest prompt, summary status.

| Key | Action |
|---|---|
| `RET` | Open, or switch to the session's live chat |
| `N` | New session: pick `C`/`x`/`p`/`d`/`m` (Claude/Codex/pi/dsh/Hermes), then a directory |
| `i` | Details: metadata and the whole conversation |
| `n` / `p`, `TAB` | Move; fold a group |
| `j` | Jump to a session by any of its text |
| `f` | View menu: project, agent, live only, hidden sessions, grouping |
| `a` / `P` / `l` / `t` / `c` | Agent filter / project filter / live only / newest first vs. groups / reset |
| `s` | Semantic search and Q&A over summaries or full text (gptel) |
| `r` / `R` | Summarize this session again / retry failed summaries |
| `d` / `u` / `x` | Mark / unmark / delete marked sessions (Claude, Pi) |
| `D` | Relocate a moved project directory |
| `w` / `W` | Copy ID / project |
| `!` / `?` / `q` | Diagnostics / command menu / restore the window layout |

### Summaries and existing ashub data

Summaries start by default when `agent-dash` loads. gptel is optional, but generating summaries and semantic search require its configured default backend/model. To disable automatic startup, set this **before** loading the package (for `use-package`, put it in `:init`):

```elisp
(setq agent-dash-summary-enable nil)
```

To stop an already running scheduler, evaluate `(agent-dash-summary-mode -1)`; setting the startup option alone does not stop it.

On startup, if `ashub-summary` is loaded and a `*ashub*` buffer exists, summaries are copied from its session inventory without model calls. You can also run `M-x agent-dash-summary-import-ashub` later. Existing agent-dash summaries are never overwritten. Entries current in ashub adopt the session timestamp when listed here; stale entries retain their text and are queued for an update.

Closed sessions unchanged for 300 seconds become eligible. New summary jobs are normally spaced at least 60 seconds apart; long conversations require multiple segment and final-summary calls, so this is **not** a model-call or cost cap. Only user/assistant dialogue is sent (not tool output); it may still contain private data. Only summaries and scheduling metadata are persisted, not full transcripts. Running both ashub and agent-dash summary modes can duplicate model work and charges; stop whichever scheduler you do not need explicitly.

DSH first/latest prompts come from the local Host projection cache (`turnOutline` version 2), not `session/list`. Missing or unsupported cache rows yield no prompts; cached text may lag or be truncated by the Host. Details (`i`) show assistant-left/user-right bubbles, per-message copy buttons, collapsible metadata (`m`), and original-dialogue copy (`C-c C-w`). `g` reflows the cached dialogue; reopen details to fetch it again. The `N`/`f`/`a`/`?` transient menus follow ashub's interaction style.

## Development

```sh
make check    # byte-compile (warnings are errors) + ERT + elisp-lint
make indent   # reindent the way the lint expects
```

Tests run offline with stand-in agents in `test/bin/`. They read no real sessions and call no models. Lint uses packages installed under `ELPA` (default `~/.emacs.d.default/elpa`); override it with `make lint ELPA=...`.
