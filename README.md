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
| `RET` / `C-c C-c` | Send; while the agent runs, queue as a follow-up (`RET` answers pending dialogs first) |
| `S-RET` | Newline |
| `C-c C-s` | Steer the running task |
| `C-c C-k` | Stop the current task |
| `C-c C-q` | Quit (see the table above) |
| `C-c C-a` | Manually open pending permission requests and questions (also opened automatically) |
| `C-c C-r` | Resume a saved session |
| `C-c C-b` | Switch to another chat |
| `C-c @` | Pick a cross-agent session reference |
| `/`, `@`, `@session`, `@dash` + `TAB` | Minibuffer completion (Vertico/Orderless) |
| `C-u TAB` | Refresh the backend command catalog |
| `i` outside the composer / `C-c C-i` anywhere | Focus the composer (inside it, `i` types normally) |
| `M-p` / `M-n` | Browse sent prompts |
| `TAB` / `RET` on a tool or thinking line | Fold / unfold |
| `M-x agent-dash-select-model` | Switch model |

### Questions and confirmations

Requests in the selected chat open automatically in the minibuffer, outside process filters. Other chats keep a visible question card and `?N` indicator until selected; an existing minibuffer is never interrupted. Drafts stay intact. Set `agent-dash-auto-answer` to `nil` for manual-only interaction with `RET` or `C-c C-a`.

- Single choice uses completion; freeform prompts accept custom text.
- Native multi-choice questions use comma-separated completion. Pi’s `ask_user` RPC fallback presents repeated toggle choices; select **Done** to finish, or **Other** for custom input. Batched questions and optional comments continue as successive dialogs.
- `C-g` cancels the current request and tells the backend, never granting permission. Pi receives an explicit cancellation, Claude denies the tool call, Codex/DSH return no question answers, and Hermes cancels its permission request.
- Confirmation bodies and input hints remain visible; editor requests use their prefilled text (quoted newlines, `C-q C-j`, work in the minibuffer). Pi timeouts/withdrawals clear pending state; a late answer is not sent.

### Input completion

- `/` + `TAB`: shared client commands (`/help`, `/new`, `/resume`, `/dash`, `/stop`, `/quit`, plus `/model` where supported) and the backend's advertised commands/skills. Select a command, then `RET` to execute it. Client commands take no arguments and open their picker when applicable.
- `@` + `TAB`: project files, or a session-reference picker. Paths containing spaces are quoted.
- `@session` + `TAB`: saved sessions of the current agent, across projects.
- `@dash` + `TAB`: sessions of all agents from the shared Hub inventory. Match agent, project, summary, latest prompt or id; selected references attach the saved conversation when sent.

Pickers use `completing-read`: existing Vertico is respected and optional Orderless is enabled locally without changing global settings. `C-g` preserves the draft; background output cannot shift the replacement region. Completion reads catalogs, not models. Pi merges its installed native catalog with `get_commands` (see below); Claude uses its initialization catalog; DSH uses Host commands and registered skills; Hermes uses ACP-advertised commands. Codex currently offers the shared client commands, not an emulation of its CLI-only slash menu. DSH Host command results are displayed; registered skills are submitted as prompts.

### Pi native commands

Pi completion uses its own built-in commands (24 in the currently verified version), plus RPC-advertised extensions, prompt templates and skills. It does not add client-only names to this list; `/help`, `/dash` and `/stop` remain available as manual client aliases. `/model provider/model-id` and `/thinking` use native RPC, as do `/compact`, `/name`, `/session`, `/copy` and HTML `/export`.

`/login [provider-id]` and `/logout [provider-id]` use the running Pi runtime, including extension providers. Install/keep `agent-dash-pi-bridge.mjs` alongside the Elisp files. Login can select a provider and authentication method; all free-form authentication input is masked with `read-passwd` (including legacy OAuth API-key prompts and endpoint fields). Never put API keys after `/login`: authentication commands do not enter prompt history or model context. `C-g` cancels a dialog; errors do not automatically retry. Authorization URLs are displayed, not automatically opened, and the clipboard is not replaced.

**Existing Pi holders must be stopped with `/quit` and restored from the Hub to load the bridge; closing the chat buffer alone reuses the old process.** The client will not restart a running task for you. Missing bridges and unknown commands fail closed, never falling back to inference. TUI-only commands such as `/settings`, `/tree`, `/fork`, `/clone`, `/trust`, `/share` and `/reload` are shown with a terminal-UI annotation and explicitly refused; a matching catalog is not a claim that the full terminal UI is implemented. `/hotkeys` shows the current Emacs bindings.

### Images

All five backends support image attachments through their native protocols. Use `C-y` or macOS `s-v` to paste an image (ordinary text still yanks normally), `C-c C-v` for image-only paste, or `C-c C-f` to choose a local file. macOS image paste uses optional `pngpaste`; Linux uses `wl-paste` or `xclip`. No clipboard helper is needed for file attachment.

Pending thumbnails appear above `You>` without entering the draft text. Click `× remove` or use `C-c C-d` to remove an attachment; click an image or use `C-c C-o` to view it at full size in Emacs. Image-only prompts are allowed. Remove attachments before executing slash commands.

PNG, JPEG, GIF and WebP are recognized by content, with a 10 MiB per-image client limit and at most 10 attachments (providers may impose smaller limits). Synchronous write failures keep the draft. Correlated Pi/Codex/Hermes request rejections can restore an empty draft if no newer submission is active; `C-c C-u` chooses from failed/recent image drafts without overwriting newer input or automatically resending anything. A model-side error can occur after work has already started: check before retrying.

Saved user/assistant image blocks render on replay; tool images appear when their details are expanded. Unsupported, missing or oversized images retain an accessible placeholder. Remote image URLs are never downloaded automatically, untrusted local image paths require confirmation, SVG is not rendered, and image bytes are not added to textual session references or summaries. Reopen an older chat from the Hub to replay image blocks that an earlier client version had ignored.

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
