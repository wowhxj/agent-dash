# agent-dash 设计

日期：2026-11-12；状态：第 2 步定稿，后续实现以本文件为合同。

## 1. 关键决策

| # | 决策 | 理由 |
|---|---|---|
| D1 | **通用 holder**：Pi、Claude、Codex、Hermes 以及 managed 模式的 DSH Host（`dsh web`）共用一个 `sh` + FIFO + 只追加日志的后台持有进程（`agent-dash-holder.el`） | 三者都是 stdio JSONL 协议。emacs-claude 已验证该模式能在 buffer / Emacs 退出后继续运行。它取代 emacs-pi 的 545 行 Node bridge，满足“尽量纯 Elisp” |
| D2 | DSH 客户端直连 Host（HTTP RPC + websocket）；Host 是 Desktop，或由 holder 托管的 `dsh web` | Host 本身就是常驻服务。launch URL 可以多次兑换 cookie（实测两次都返回 303），所以 Emacs 重启后读取 holder 日志里的 URL 即可重新登录，不需要旧版的 Node supervisor |
| D3 | 后端用 `cl-defgeneric`，按 `(eql BACKEND-SYMBOL)` 分派 | 已有 4 个以上实现，不是只有一个实现的抽象。UI 不写 `pcase backend` |
| D4 | 后端只产出**统一事件**（plist），UI 是事件的 reducer | 历史回放、实时流、重连共用同一条代码路径 |
| D5 | 时间线条目按 `:id` upsert | 同一消息出现多次（Pi 的 `message_end`/`turn_end`/`agent_end`，Claude 回放）也只显示一次 |

## 2. 数据

### 2.1 session（`cl-defstruct agent-dash-session`）

| 字段 | 含义 |
|---|---|
| `id` | 客户端本地 ID（uuid）。不等于后端 session-id，也不等于目录 |
| `backend` | 符号：`pi` / `claude` / `dsh` / `fake` … |
| `root` | 工作目录 |
| `buffer` | 聊天 buffer |
| `items` | 时间线：按插入顺序的条目列表（见 2.3），配 `index`（id → item） |
| `state` | `idle` / `running` / `dead` |
| `queue` | `(:steering LIST :follow-up LIST)` |
| `meta` | plist：`:model :thinking :title :usage :context :status`，由 `meta` 事件合并 |
| `requests` | 待回答的 `request` 事件 |
| `data` | 后端私有 plist（连接、进程、请求表等），UI 不读 |

### 2.2 统一事件

后端调用 `(agent-dash-emit SESSION EVENT)`；EVENT 是 plist，`:type` 必填。

| `:type` | 其他字段 | 语义 |
|---|---|---|
| `user` | `:id :text :images` | 用户消息（以后端回显为准，客户端不预插入） |
| `assistant` | `:id :text :thinking :final` | 助手消息。`:final nil` 时为流式快照（后端负责拼接 delta），`:final t` 为权威内容 |
| `tool` | `:id :name :args :output :status` | 工具卡片。`:status` 取 `running` / `success` / `error`；同 id 多次发送即更新 |
| `run` | `:state` | `running` / `idle`。只在后端确认“不会再自动继续”时发 `idle` |
| `queue` | `:steering :follow-up` | 完整快照（字符串列表） |
| `meta` | 任意 `meta` 键 | 合并进 `session-meta` |
| `notice` | `:text :level` | `info` / `warning` / `error`；中断、压缩、重试、扩展错误等 |
| `request` | `:id :kind :title :options :default :questions` | 需要用户回答：`kind` 取 `confirm` / `select` / `input` / `permission` / `questions`（`:questions` 是 `(:question :options :multi)` 列表；答案按问题顺序排列，单选为字符串，多选为字符串列表）。用 `agent-dash-backend-respond` 回答 |
| `request-done` | `:id` | 请求被后端取消或已在别处回答 |

ponytail：`assistant` 用整段快照而不是 delta。好处是 reducer 无状态，回放幂等；代价是每次刷新都要复制整条消息的文本。消息过长导致流式卡顿时，再加 `:append`。

### 2.3 时间线条目

`(:id ID :type user|assistant|tool|notice :start MARKER :end MARKER :folded BOOL . EVENT-FIELDS)`。
重渲染时只删除并重新插入该条目自己的 `start..end` 区域，输入区不动。

## 3. 后端接口

| 泛型 | 必须 | 说明 |
|---|---|---|
| `agent-dash-backend-start (backend session &optional resume-id)` | 是 | 新建，或恢复指定的历史会话 |
| `agent-dash-backend-send (backend session text images mode)` | 是 | `mode` 取 `prompt` / `follow-up` / `steer` |
| `agent-dash-backend-cancel (backend session)` | 是 | 停止当前任务，会话保留 |
| `agent-dash-backend-quit (backend session)` | 是 | 按 `:quit` 能力：`stop` 结束实例；`detach` 只断开 |
| `agent-dash-backend-detach (backend session)` | 是 | kill-buffer 时调用：只断开客户端 |
| `agent-dash-backend-respond (backend session request answer)` | 否 | 回答 `request` |
| `agent-dash-backend-models (backend session)` / `-set-model` | 否 | 模型列表与切换 |
| `agent-dash-backend-sessions (backend root)` | 否 | hub 用：历史会话列表 `(:id :title :root :time :running)` |
| `agent-dash-backend-transcript (backend id)` | 否 | hub 详情与 @ 引用：`((user . TEXT) (assistant . TEXT) …)` |
| `agent-dash-backend-capabilities (backend)` | 是 | plist：`:quit stop\|detach`、`:steer`、`:images`、`:models` |

## 4. 通用 holder（D1）

```
<agent-dash-directory>/instances/<backend>-<id>/
  in          FIFO；holder 以读写方式打开（exec 3<>），所以永远收不到 EOF
  outp        FIFO；子进程 stdout，由一个 cat 追加到 out.jsonl
  out.jsonl   只追加日志；子进程退出后追加 {"type":"agent_dash_exit","code":N}
  err         stderr
  pid / code  子进程 pid / 退出码
  root        工作目录
  sid         后端会话 ID（仅 Codex、Hermes：ID 由服务端生成，用于"恢复时先接回活实例"）
```

stdout 必须是管道而不是普通文件：Hermes ACP（Python asyncio）遇到普通文件会报 `Pipe transport is only for pipes, sockets and character devices` 并退出（2026-11-12 实测）。

- 启动：`nohup sh -c SCRIPT`，`call-process` 的 destination 设为 0，Emacs 不持有该进程。stdin 经 `cat` 中继（Claude 读 FIFO 超过约 64 KiB 后停止读取，这是 emacs-claude 已验证的现象）。
- 写：每个 session 一个常驻 `cat > in` 子进程，保证大消息不交错。
- 读：`tail -c +OFFSET -f out.jsonl`，按 LF 分帧，`json-parse-string`。
- 存活：`signal-process pid 0`。
- 停止：向 pid 发 TERM。
- 客户端独有的信息（Hermes 不回显的用户 prompt）用 `agent-dash-holder-log` 写入同一日志，回放时顺序不乱。
- JSON-RPC 后端（Codex、Hermes）的请求 ID 用 uuid，下一次启动的 Emacs 回放旧日志时，旧响应不会误匹配新请求。
- 接回策略：Pi 从日志末尾开始跟读，并用 `get_messages` 补历史；Claude、Codex、Hermes 从头回放整段日志（各自按 uuid、item id、日志顺序去重或定位）。

不承诺重启电脑后续跑；holder 丢失时显示 `dead`，并提供“从历史恢复”。

## 5. 协议映射表（验证第 2 步）

证据来源：
- Pi 1.5.0 官方文档：`node_modules/@earendil-works/pi-coding-agent/docs/{rpc,json,rpc-extension-ui}.md`。另实测 `pi --mode rpc --no-session` 的 `get_state` / `get_messages`，以及启动时的 `extension_ui_request`：1 条 `notify`、8 条 `setStatus`、13 条 `setWidget`。
- Claude Code 2.1.322：本机 emacs-claude holder 日志中出现的全部 `type/subtype`（只统计类型，未读内容）。
- DSH：`~/sandbox/emacs-dsh/emacs-dsh.el` 的事件 reducer（`emacs-dsh--event`、`--stream`、`--on-frame`）。

### 5.1 Pi（RPC，经 holder）

| Pi 记录 | 统一事件 |
|---|---|
| `message_start/end` role=user | `user` |
| `message_update` text_delta / thinking_delta | `assistant :final nil`（后端按 `contentIndex` 拼接） |
| `message_end` role=assistant | `assistant :final t`（权威） |
| `toolcall_end`、`tool_execution_start/update/end` | `tool`（按 `toolCallId` 更新） |
| `agent_start` | `run running` |
| `agent_settled` | `run idle`（**不是** `agent_end`） |
| `agent_end`、`turn_*` | 忽略（消息已由 `message_end` 给出） |
| `queue_update` | `queue` |
| `session_info_changed`、`thinking_level_changed`、`message_update.usage` | `meta` |
| `compaction_*`、`auto_retry_*`、`extension_error` | `notice` |
| `extension_ui_request` select/confirm/input/editor | `request`（editor 归入 `input`） |
| `extension_ui_request` notify | `notice` |
| `extension_ui_request` setStatus/setWidget/setTitle | `meta :status` / `meta :title` |
| `response`（`get_state`、`get_messages` 等） | 后端内部处理；`get_messages` 回放为 `user` / `assistant` / `tool` |

启动或接回时没有 session header：发 `get_state` 和 `get_messages`。

### 5.2 Claude Code（`claude -p` stream-json，经 holder）

| Claude 记录（日志实测类型） | 统一事件 |
|---|---|
| `user`（人写文本） | `user` |
| `user` 内含 `tool_result` | `tool`（按 `tool_use_id` 更新状态） |
| `stream_event` content_block_start/delta/stop（text、thinking、tool_use；input_json_delta、signature_delta） | `assistant :final nil`；tool_use 对应 `tool running` |
| `stream_event` message_start/delta/stop | 内部用，不产出事件 |
| 去重 | 每条记录带 `uuid`，与 `~/.claude/projects/<root>/<id>.jsonl` 中的一致（实测 262/262、37/37）。接回时先回放 transcript，再从头回放 holder 日志，已见过的 uuid 跳过；这样挂起的权限请求不会丢 |
| `assistant` | `assistant :final t` + `meta :usage` |
| `result` | `run idle`；`is_error` 时加 `notice error` |
| `system/init`、`system/status` | `meta :model`、`meta :status` |
| `system/commands_changed`、`control_response` 中 `init` 的响应 | 后端内部（补全数据） |
| `system/thinking_tokens`、`system/hook_*`、`rate_limit_event` | 忽略（`rate_limit_event` 可选转为 `notice`） |
| `command_lifecycle` | `queue` |
| `control_request` can_use_tool | `request :kind permission`（AskUserQuestion 为 `questions`） |
| `control_cancel_request` | `request-done` |

### 5.3 DSH（Host websocket `api/remote.mux`）

| DSH 记录 | 统一事件 |
|---|---|
| `user/message` | `user` |
| `assistant-stream` start/chunk/end | `assistant :final nil` |
| `assistant/message` | `assistant :final t`（reasoning 块进 `:thinking`） |
| `tool/call`、`tool/result` | `tool` |
| `turn/start` / `turn/end` | `run running` / `run idle`；`turn/end` 的 reason 不是 completed 时加 `notice` |
| `model/selection`、`request/header`、`session/title`、`agent-preset/selected`、`working-directory/change` | `meta` |
| `approval/request` | `request :kind permission` |
| `user-questions/request` | `request :kind questions` |
| projection `queue` / `tokenUsage` / `contextPressure` | `queue` / `meta` |
| `snapshot` | 按记录逐条回放成上面的事件 |

### 5.4 Codex（`codex app-server`，JSON-RPC 2.0，经 holder）

依据：`codex app-server generate-json-schema` 生成的 schema（codex-cli 0.167.1），并实测 initialize、thread/list、thread/read、model/list。

| Codex 记录 | 统一事件 |
|---|---|
| `thread/start`、`thread/resume` 的响应 `result.thread` | 记录 sid；`turns[].items[]` 回放 |
| `turn/started` / `turn/completed` | `run running` / `run idle`；`turn.error` 产生 `notice` |
| `item/started`、`item/completed`：userMessage / agentMessage / reasoning | `user` / `assistant` / 只含 `:thinking` 的 `assistant` |
| 同上：commandExecution / fileChange / mcpToolCall | `tool` |
| `item/agentMessage/delta`、`item/reasoning/*Delta`、`item/commandExecution/outputDelta` | 按 itemId 拼接后发出 |
| 服务端请求 `item/commandExecution/requestApproval`、`item/fileChange/requestApproval` | `request :kind permission` → 应答 `{decision: accept\|decline}` |
| 服务端请求 `item/tool/requestUserInput` | `request :kind questions` |
| 其他服务端请求 | 应答 JSON-RPC 错误 -32601 |
| `serverRequest/resolved` | `request-done` |

### 5.5 Hermes（`hermes acp`，Agent Client Protocol，经 holder）

依据：实测 initialize（hermes-agent 0.23.1：loadSession、list、resume）与 session/list。

| ACP 记录 | 统一事件 |
|---|---|
| `session/new` 响应 `sessionId` | 记录 sid |
| `agent_dash_user`（客户端写入日志） | `user` + `run running` |
| `session/update` user/agent_message/agent_thought chunk | `user` / `assistant`（按日志顺序编号） |
| `session/update` tool_call / tool_call_update | `tool` |
| `session/prompt` 响应 `stopReason` | `run idle`；不是 end_turn 时加 `notice` |
| `session/request_permission` | `request :kind permission` → 选 allow_once / reject_once |

限制：ACP 的 `session/list` 只列出经 ACP 创建的会话，Hermes CLI 的会话不在其中。

### 5.6 结论

五个后端的全部记录都有对应的统一事件，或被明确忽略，没有映射不了的条目。和 HANDOFF 4.3 的草案相比有三处改动：
1. `text-delta` / `message-final` 合并成 `assistant` 一种事件，用 `:final` 区分流式快照和权威内容。
2. 新增 `request` / `request-done`（Claude 权限请求、Pi 扩展对话框、DSH 审批）。
3. `status` / `usage` 合并进 `meta`；`thinking` 作为 `assistant` 的 `:thinking` 字段。

## 6. 界面（以 emacs-pi DESIGN §7、§9、§11 为蓝本）

- 历史区只读，底部是输入区。`RET` / `C-c C-c` 发送（运行中发送即 follow-up），`S-RET` 换行，`C-c C-s` steer，`C-c C-k` 停止，`C-c C-q` 退出（按 `:quit` 语义），`M-p` / `M-n` 浏览输入历史，`C-c C-i` 聚焦输入框，`C-c C-b` 切换聊天，`C-c C-r` 恢复历史会话，`TAB` 在过程行上折叠/展开。
- 工具和 thinking 默认折叠成一行。
- mode-line 显示：`后端:项目 · idle/running · 队列计数 · 模型`。
- 草稿与历史分开存放：后台输出不能修改输入区。

## 7. hub

`agent-dash-hub` 只调用后端接口里的 `sessions` / `transcript`，不写任何按后端分支的代码。单个来源出错时，错误显示在 header-line，其他来源照常列出。@session 引用通过 UI 的 `agent-dash-prompt-filter-functions` 在发送前展开；UI 在显示 user 消息时截掉 `agent-dash-reference-boundary` 之后附加的上下文。

## 8. 不做（本版）

TRAMP、Windows、分支树 UI、fork / clone、队列逐条编辑（mode-line 只显示队列计数）、会话删除、图片附件与智能粘贴（接口已留 `images` 参数）、gptel 摘要、DSH 模型切换。
