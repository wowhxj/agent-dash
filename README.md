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

Alternatively, add a checkout to `load-path` and `(require 'agent-dash)`. Keep the repository root’s `agent-dash-*.mjs` and `*.py` helpers alongside the Elisp files for Pi commands, session conversion and portable backups.

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

## Back up and restore sessions across computers

In the Hub on the old computer, press `M` to select all sessions matching the current filters, including sessions inside folded groups. Press `B s` to export the selected Codex, Pi, DSH and Hermes sessions to one ZIP. Use `m` to select individual sessions. On the new computer, press `B i` and choose the ZIP. Existing project directories are used automatically. For each missing directory, press `c` to create it at its original path or `m` to choose an existing local directory.

The preview identifies each session by backend and session ID. Sessions in different backends may share the same ID. New sessions are imported automatically and identical sessions are skipped. The Hub asks for confirmation before replacing an existing session in the same backend. The report shows the results and where to find rollback files. Use `B i` with a reported rollback archive to recover an overwritten session. Move project code, login credentials and external files merely referenced by history separately.

**Pi.** Parent sessions needed by a branch are included in the package. Import updates the project directory and parent-session paths in the native headers. Messages, tool records and branches remain available under their original session IDs.

**DSH.** Start DSH once on the new machine to initialize the standard data root (`DSH_HOME`, normally `~/.dsh`). For a custom location, set `agent-dash-hub-dsh-backup-directory` in Emacs. Quit DSH Desktop or `dsh web` on the destination before importing from Emacs. After import, restart DSH and press `g` in the Hub. The archive includes native session events and referenced attachments. Configure the required plugins and models separately. Project files, background jobs and reminders are outside the session backup.

**Hermes.** Use the Hermes data directory configured by `agent-dash-hermes-directory` (defaults to `HERMES_HOME` or `~/.hermes`). Start Hermes once on the new machine to initialize its native database. The backup preserves session IDs, messages, system prompts and model usage. It includes related branches, creation receipts needed for native resume, and any per-session JSONL recovery files. Close clients using the destination session before overwriting it. The two databases need compatible table layouts.

If the selection includes Claude sessions, the Hub shows how many and lets you cancel or proceed with the supported sessions.

**Codex.** Initialize the native index on the destination machine by starting Codex once. Close other Codex processes using that data directory before confirming the import. Existing Codex-only ZIPs are still accepted by `B i`.

To recover readable sessions that were overwritten, import the rollback ZIP shown in the report with `B i`. The snapshot directory also holds a full copy of the destination SQLite index and should be kept private. An interrupted import with an unfinished snapshot blocks subsequent imports. Close Codex and compare the snapshot with current data before recovery to preserve later sessions. Tested with Codex CLI 0.170.0 and `state_5.sqlite`. Compressed histories require `zstd`. Open-file checks require `lsof`.

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
