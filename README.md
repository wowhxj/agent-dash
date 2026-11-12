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
| `C-c @` | Insert an @session reference; sending attaches that conversation |
| `@path` + `TAB` | Complete a file path |
| `M-p` / `M-n` | Browse sent prompts |
| `TAB` / `RET` on a tool or thinking line | Fold / unfold |
| `M-x agent-dash-select-model` | Switch model |

### Hub

`RET` opens a session (or switches to its live chat), `N` new, `/` filter, `d` details, `g` refresh, `?` menu.

## Development

```sh
make check    # byte-compile (warnings are errors) + ERT + elisp-lint
make indent   # reindent the way the lint expects
```

Tests run offline with stand-in agents in `test/bin/`. They read no real sessions and call no models. Lint uses packages installed under `ELPA` (default `~/.emacs.d.default/elpa`); override it with `make lint ELPA=...`.
