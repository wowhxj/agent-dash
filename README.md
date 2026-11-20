# agent-dash

English | [简体中文](README.zh-CN.md)

Native Emacs chats for **Pi, Claude Code, Codex, DeepSeek Harness (DSH) and Hermes**, with one Hub for browsing and resuming saved sessions. All backends are included; install only the agent CLIs you use.

## Install

Requires Emacs 29.1+, macOS or GNU/Linux, and `markdown-mode`, `websocket` and `transient` (0.7+). Install and authenticate your agent CLIs, and make sure Emacs can find them in `exec-path`. Codex and Hermes history browsing also requires `sqlite3`.

With a `use-package` version that supports `:vc`:

```elisp
(use-package agent-dash
  :vc (:url "https://github.com/wowhxj/agent-dash")
  :commands (agent-dash agent-dash-hub)
  :init
  ;; Optional: disable the default background summary scheduler.
  (setq agent-dash-summary-enable nil))
```

Alternatively, add a checkout to `load-path` and `(require 'agent-dash)`. Keep the repository’s `agent-dash-*.mjs` helpers alongside the Elisp files for Pi's native commands and local session conversion.

**Background summaries are enabled by default.** The example above opts out. If enabled, they send saved user/assistant dialogue to your configured gptel model and may incur charges; see [Summaries and privacy](#summaries-and-privacy).

## Start here

- `M-x agent-dash`: choose an agent and working directory.
- `M-x agent-dash-hub`: browse saved sessions across agents. Press `RET` to open or resume one, or `N` to create a session.

Chats run in the background and can survive closing their buffer or Emacs. `C-c C-q` asks before stopping Pi, Claude, Codex or Hermes; for DSH it only detaches, leaving the Host session running. If a connection is lost, reopen the session from the Hub.

## Chat

| Key | Action |
|---|---|
| `RET` / `Shift-RET` | Send / insert newline |
| `TAB` | Complete `/` commands and `@` session references in the composer; toggle items elsewhere |
| `M-p` / `M-n` | Previous / next input |
| `C-c C-k` | Interrupt the current run |
| `C-c C-s` | Stage a steering message; apply it from the queue |
| `C-c C-i` | Focus the composer |
| `C-c C-f` / `C-c C-v` | Attach image file / clipboard image |
| `C-c C-d` | Remove draft images |
| `C-c C-o` | Open an attached or received image |
| `C-c q` | Open the queue editor |
| `C-c C-a` | Answer a pending request |
| `C-c C-q` | Stop or detach |

Use `M-x agent-dash-select-model` to change models where supported. `@` references insert saved user/assistant dialogue into the outgoing message. `/` completion shows available backend commands; Pi also supports native login, logout and reload without sending those operations to the model.

During a run, normal sends enter the local follow-up queue. Queued drafts can be reviewed, reordered, edited or deleted before delivery; delivered messages cannot be withdrawn. Steering must be applied explicitly from the queue and falls back to follow-up when unsupported. **Queues are not persisted across Emacs restarts.**

Images support PNG, JPEG, GIF and WebP. File attachment works without a clipboard tool. Clipboard paste needs `pngpaste` on macOS, or `wl-paste` / `xclip` on Linux. A backend that does not support images rejects the attachment rather than silently dropping it.

## Session Hub

The summary column shows an AI summary when available, otherwise the first user message. The latest user message is shown separately. Press `g` to refresh after new activity.

| Key | Action |
|---|---|
| `RET` / `N` | Open session / create session |
| `j` | Search all loaded sessions, including hidden groups |
| `n` / `p` | Next / previous visible session |
| `C-c C-n` / `C-c C-p` | Next / previous project |
| `C-c C-j` | Choose a project and jump to its header |
| `TAB` / `Shift-TAB` | Fold current / all groups |
| `f` / `a` / `P` | View filters / agent filter / project filter |
| `l` / `c` | Toggle live-only view / reset filters |
| `u` | Clear selection and any pending deletion on the current row and keep point there |
| `m` / `M` / `U` | Toggle selection and advance / select all filtered sessions / clear selection |
| `i` | View dialogue. In the details buffer, `m` toggles metadata and `C-c C-w` copies dialogue |
| `s` | Semantic search using gptel |
| `r` / `R` | Generate or update selected summary / retry failed summaries |
| `d` / `u` / `x` | Mark / unmark / execute history deletion (Pi and Claude only) |
| `!` / `?` / `q` | Diagnostics / help / return |

For example, press `a C` to filter for Claude Code, `q` to return to the list, then `M`. Use `v s` to convert the selection to Pi or `v d` to import it into the connected DSH Host. Use `v e` for a ZIP only. For deletion, `d` stages the selection and `x` confirms all staged deletions. Select-all includes loaded sessions in folded groups that pass the filters. Changing filters retains only selections that still match.

Empty, subagent, archived and other non-summarized sessions are hidden by default; use `f h` to include them. Deleting history does not stop a running agent. For moved or missing project directories, use `D` to select a replacement; saved transcripts are not rewritten.

## Continue Claude Code or Codex history in Pi or DSH

In the Hub, place the cursor on a Claude Code or Codex session and press `v s` for the selection (or the session at point when the selection is empty), `v p` for loaded Claude and Codex sessions in the current project, or `v b` to convert all loaded sessions from one backend. The converter uses Node.js to read a local Claude project JSONL file or Codex rollout. It needs no source account or model request. The Hub shows the Pi session for the converted history. Press `RET` to continue with the model configured in Pi. Original transcripts are archived together under `conversion-archives/` in `agent-dash-directory`. When migrating Claude history to Pi from the Hub, the converter verifies the archive and the Pi session before removing the source JSONL from the Claude project directory. The converter uses `lsof` to check for writers. An active writer or an unavailable check leaves the source in place, and the report explains why. To restore it in Claude, copy the archive back into its original project session directory under the original Claude session ID with the `.jsonl` extension. Codex conversion and DSH export retain their source files.

Converting the same source contents for the same target project again reuses the Pi session, including any turns you have added. Changed source contents create a separate snapshot. The batch report shows one row per session with its outcome, any failure reason and relevant limitations for resuming. Press `TAB` or `RET` on a row to expand or collapse the full IDs, paths and original diagnostics. The Claude importer follows the parent chain of the last conversation leaf. Earlier history outside that chain, including pre-compaction records and other branches, remains in the source archive. For compacted Codex history it restores a readable replacement checkpoint and applies subsequent records. If a rollback cannot be reconstructed, the report gives the archive path. Content already absent from the source cannot be recovered. The archive contains the complete source record and can include commands, tool outputs and private text. When moving to a new computer, take both the source archive and the Pi sessions.

If only the source file survives, or the Codex index is missing, run the converter directly from the checkout. Supply the native session ID recorded in the file, the target project directory, the Pi session directory and the archive directory. Both commands below retain the source file. To migrate a transcript out of its native Claude project directory, append `--migrate-claude` to the first command.

```sh
node agent-dash-convert.mjs claude "$SOURCE_JSONL" "$SESSION_ID" "$PROJECT" "$PI_SESSIONS" "$ARCHIVES"
node agent-dash-dsh-export.mjs codex "$ROLLOUT" "$SESSION_ID" "$PROJECT" "$PI_SESSIONS" "$ARCHIVES"
```

DSH export also requires `python3` to build the ZIP. Enable **DeepSeek chat import** under Plugins → More → Experimental plugins in DSH. Press `v d` in the Hub to import into the DSH workspace for the source project. After verifying the imported history, the report shows the native DSH session ID. Claude sources are retired after verification. Codex sources are retained. For transfer to another machine, press `v e` and upload the resulting ZIP in the destination DSH. Historical tool calls and results appear as attributed text; the original archive keeps the native records. Uploading the same ZIP manually twice creates two sessions.

## Summaries and privacy

Summaries and semantic search require a configured [gptel](https://github.com/karthink/gptel). Chats and ordinary Hub browsing do not.

- Background summaries cover closed sessions after 300 seconds of inactivity. Long conversations may require multiple model calls; the scheduling interval is **not a spending cap**.
- User/assistant text may contain private data even though tool output is excluded. Semantic search also sends the summaries or dialogue selected for the search to gptel.
- To opt out, set `(setq agent-dash-summary-enable nil)` **before loading** the package. To stop an already-running scheduler, use `M-x agent-dash-summary-mode` to disable it.

## Useful settings

Use `M-x customize-group RET agent-dash` for all options.

| Variable | Purpose |
|---|---|
| `agent-dash-dsh-connection` | `auto` (default), `desktop` or `managed`; managed mode starts `dsh web` |
| `agent-dash-dsh-permission` | New sessions default to `"danger-full-access"`. Set to `nil` to use the Host default. |
| `agent-dash-notify` | Enable or disable background completion reminders |

Completion reminders use Emacs messages while Emacs is focused, and desktop notifications otherwise. Desktop delivery uses your `notify-send` wrapper if configured, or built-in notifications; failures fall back to Emacs messages. Mode-line badges link to pending requests and unread completions. Detached DSH sessions do not send Emacs notifications.

Not supported: TRAMP, Windows and branch/fork UI.

For contributors: `make check` runs offline tests, strict byte compilation and lint; `make indent` formats Elisp. Architecture notes are in [docs/DESIGN.md](docs/DESIGN.md).
