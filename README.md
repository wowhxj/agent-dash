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

New DSH sessions default to `auto` permissions; resumed sessions keep their existing preset.
Customize `agent-dash-dsh-permission`, or set it to nil to keep the Host default.
If the reply or interaction channel disconnects, the UI reports disconnected and retries automatically, restoring recent history, live run state and unanswered Host questions without resending prompts.

### Chat buffer

User turns are highlighted; the bottom `You>` composer stays editable while history is read-only. The latest prompt is pinned above the conversation. Tools and thinking-only messages are grouped under `Process · N steps` per user turn. Only the active Process group expands automatically, showing compact step summaries; individual thinking and tool details stay folded until manually opened. When the backend confirms the entire run has ended, the group folds and the final answer stays visible. `RET`/`TAB` still toggles groups or individual details; manual choices persist during streaming. A single final message does not prematurely fold an ongoing run.

All five backends share the same layout: statistics on the top left, provider/model and thinking level on the top right; the bottom mode line uses a compact activity indicator such as `Pi thinking |`, shared by all backends. Its `|/-\` animation runs only while active; idle/disconnected chats have no animation. Queues (`[S1 F2]`) and pending requests (`?1`) appear only when present; detailed phases and action hints are available on hover. Narrow windows drop lower-priority metrics first. The composer uses the same theme-derived background and no-underline face as emacs-pi. Pi reports cached context usage, session token totals, cache-read ratio and estimated cost (not a bill), refreshed on attachment and when it settles. DSH restores context, turns/steps, decoding speed, token totals and cache ratio from Host projections, with live control-stream updates; its right side also shows the agent preset and permission mode. DSH billing buckets are summed once, and no cost is invented. Unavailable backend statistics are omitted. Display redraws never issue RPC or model calls. The activity tooltip distinguishes phases such as `waiting for model` and `responding` without adding verbose text to the mode line. `M-x agent-dash-refresh-chat` rebuilds an open chat's presentation without restarting the agent or discarding its draft.

Unsent text-and-image messages use a unified local queue; backend-native queues remain separate and read-only.

| Key | Action |
|---|---|
| `RET` / `C-c C-c` | Send; while the agent runs, queue as a follow-up (`RET` answers pending dialogs first) |
| `S-RET` | Newline |
| `C-c C-s` | Stage steering; apply the selected entry with `x` in the queue |
| `C-c q` | View and manage the current session's multimodal queue |
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

### Completion reminders

Adaptive reminders are enabled by default: the selected chat stays quiet while Emacs has focus; other chats report in the echo area; when Emacs is unfocused, reminders use desktop notifications. Desktop delivery first loads built-in `notifications`, then prefers the user's `notify-send` wrapper, including deferred `use-package notifications :commands notify-send :config ...` setup. On macOS, keep your personal wrapper that sends through `terminal-notifier`; other platforms can alias `notify-send` to `notifications-notify`. Agent-dash neither redefines the user function nor calls AppleScript itself. Without `notify-send`, it falls back to built-in `notifications-notify`, which needs a working D-Bus notification service; macOS users should configure the wrapper.

Install macOS `terminal-notifier` with `brew install terminal-notifier` and ensure it is visible in Emacs's `exec-path`. Options such as `-group Emacs` and `-activate org.gnu.Emacs` are controlled by your wrapper. Synchronous errors or a nil return fall back to the echo area. An asynchronous wrapper returning a process only confirms startup; subsequent process exit status is not monitored. OS permissions and Do Not Disturb may still suppress notifications; the delivery API cannot confirm that they were seen.

Reminders contain only the agent, project directory name, short session ID and `Run ended` / `Run failed`, never conversation text. A run ending does not claim the entire task succeeded. History replay, reconnect snapshots, explicit cancellation and disconnection do not generate completion reminders. Automatic follow-ups are coalesced until the queue settles. Active minibuffer input defers echo-area reminders, but does not block desktop delivery after switching away from Emacs. Only chats attached in this Emacs are monitored; closing a chat or exiting Emacs stops its reminders.

The global mode line uses standard `global-mode-string` to show compact counts such as `?1 ✓2`: `?1`, highlighted with `warning`, means one chat awaits permission, a choice or an answer; `✓2` means two chats have unread run completions. Counts are per chat, not per question or run. Zero counts disappear; nothing is shown when both are zero. Click a count to visit that category; repeated request clicks cycle through waiting chats. Selecting a chat while Emacs has focus acknowledges its unread completion, but requests remain until answered, cancelled or withdrawn. Transient notification delivery does not acknowledge a completion. Fully custom mode lines must include `global-mode-string` to display these counts.

Set `(setq agent-dash-notify nil)` to disable transient reminders and global counts without changing the per-chat activity indicator. Unknown terminal focus is treated conservatively as still inside Emacs.

### Multimodal queues

While running, `RET` / `C-c C-c` stages one follow-up containing the entire text-and-image message. Follow-ups dispatch one at a time after the whole run settles, not after an intermediate final message. `C-c C-s` stages steering without injecting it. Open the queue with `C-c q`:

| Queue key | Action |
|---|---|
| `RET` | Read a message and retained images, or a backend-native message summary |
| `e` / `a` | Edit an unsent message / compose a new one |
| `d` | Delete an unsent local message |
| `n` / `p` | Next / previous message, skipping group headings |
| `M-n` / `M-p` | Move down / up, crossing Steer/Follow at the boundary (`M-↓↑` also works) |
| `f` / `s` | Stage a follow/steer conversion and pause automatic delivery |
| `x` | Apply exactly one selected steering message to the running task |
| `SPC` / `P` / `r` | Toggle automatic delivery / pause / continue follow-ups |
| `?` | Open the transient menu; navigation/reordering stays open, `h` shows full notes |
| `c` | Copy a failed/unknown payload into a NEW paused draft, never retry it |
| `D` | Confirm forgetting a read-only receipt; never retract a delivery |
| `o` | Show the owner chat; explicitly reconnect before continuing a detached queue |

The compact view groups **Steer before Follow** and hides sent receipts. Only nonzero image counts and exceptional states appear beside messages; common shortcuts stay visible in the header/footer, with full instructions under `?`. Moving the last steer down puts it first in Follow; moving the first follow up appends it to Steer. Crossing groups stages a conversion and pauses delivery, never injecting anything automatically.

Editors are isolated from the live draft. `C-c C-c` saves text and images atomically; `C-c C-q` cancels. Image paste, file attachment, removal and preview reuse the chat bindings. An edited head entry holds later follow-ups behind it. Handed-off entries are immediately read-only; both acknowledgement and whole-run completion are required before the next local handoff. Errors, disconnects and manual cancellation pause delivery without retrying. Pi/Codex/DSH retain native steering semantics; Claude still interrupts then submits new input, and Hermes rejects steering.

Queues are **memory-only and lost on Emacs exit**. Closing a chat retains and pauses its queue; use `M-x agent-dash-queue` from a non-chat buffer to find it. Defaults: 100 retained entries and 64 MiB of image base64 per session. Successful deliveries retain lightweight text/image-count receipts; their images remain in chat history. Failed/unknown payloads retain all images. Native queues are never cleared or rewritten; cross-client submission ordering is not guaranteed.

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

Entering the hub, pressing `g`, or enabling `l` reads history in isolated batch Emacs children, rather than scanning files/databases or waiting for history-list RPCs on the GUI thread. Cached rows remain usable while loading. Concurrent requests for one backend share a reader; the summary scheduler reuses recent successful or in-flight scans. Result bursts share a redraw. Summary preparation and full-text search also read dialogue in children. Readers do not load user init files or enable summary mode; configuration travels over private stdin, not temporary config files. This trades extra processes and memory for UI responsiveness. `agent-dash-history-timeout` defaults to 120 seconds; failed or timed-out readers retain old data, and `!` shows errors and read durations. Live filtering is not continuous polling; rows update when readers complete.

History discovery includes Pi's flat, project and nested JSONL layouts, Codex's latest native state index (including archived/subagent/metadata-only threads), DSH's empty sessions, and Hermes CLI history from its native index. Empty, internal and archived sessions count as loaded and are then filtered by the hub. Codex and Hermes index reads require `sqlite3` and use `-readonly`. If the macOS CLI cannot open a WAL database, the reader uses an available `python3` standard-library connection with `mode=ro`; this can initialize missing WAL/SHM sidecars without changing database contents and still reads committed WAL frames. Python3 is needed only for this compatibility path; `immutable` is never used to bypass live WAL. Codex falls back to a paginated, all-source app-server listing when no index exists. Native database contents are not modified. Use `!` for per-source read warnings.

`M-x agent-dash-hub` creates or selects the current frame's dedicated `agent-dash` tab and reuses the hub buffer and window without changing file tabs' window layouts. Chats, details, search, queues and image previews reuse their visible window or split an existing window in the same frame, preserving other agents instead of replacing them or opening another frame. If no split fits, enlarge the frame or close unneeded windows. Quitting a chat with `C-c C-q` or `/quit` also closes its split; cancelling quit preserves it. The last window never deletes the frame and shows the existing hub when available. Press `q` in the hub to return to the most recently used other tab without closing the workspace or its sessions. Buffers remain globally shared in Emacs; manually displaying them in other tabs is not restricted. The hub lists every saved session, grouped by project. Columns: agent, `●` live, date (`*` = source time, not a message time), short ID, project, summary (falls back to the first prompt), latest prompt, summary status.

The dedicated tab reflows into a balanced grid when windows are added or removed (including native split/close commands), or the frame is resized. On a typical landscape frame, two windows sit side by side, three use equal columns, and four form a 2×2 grid; larger counts and portrait frames adapt to available space. Reflow preserves buffers, scroll positions and focus. Focus changes and manual split resizing do not trigger reflow; manual sizes last until the next window addition/removal or frame resize. Layouts containing dedicated, side or atomic windows are left alone, as are layouts too small for a feasible grid.

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
| `!` / `?` / `q` | Diagnostics / command menu / return to the previous tab |

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
