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
| `assistant` | `:id :text :thinking :final :images` | 助手消息。`:final nil` 时为流式快照（后端负责拼接 delta），`:final t` 为权威内容 |
| `tool` | `:id :name :args :output :status :images` | 工具卡片。`:status` 取 `running` / `success` / `error`；同 id 多次发送即更新 |
| `run` | `:state` | `running` / `idle`。只在后端确认“不会再自动继续”时发 `idle` |
| `queue` | `:steering :follow-up` | 完整快照（字符串列表） |
| `meta` | 任意 `meta` 键 | 合并进 `session-meta` |
| `notice` | `:text :level` | `info` / `warning` / `error`；中断、压缩、重试、扩展错误等 |
| `request` | `:id :kind :title :options :default :questions` | 需要用户回答：`kind` 取 `confirm` / `select` / `input` / `permission` / `questions`（`:questions` 是 `(:question :options :multi)` 列表；答案按问题顺序排列，单选为字符串，多选为字符串列表）。用 `agent-dash-backend-respond` 回答 |
| `request-done` | `:id :status` | 请求已回答或撤回；状态默认为 `answered`，取消/超时为 `cancelled`，重复完成事件幂等 |

ponytail：`assistant` 用整段快照而不是 delta。好处是 reducer 无状态，回放幂等；代价是每次刷新都要复制整条消息的文本。消息过长导致流式卡顿时，再加 `:append`。

### 2.3 时间线条目

`(:id ID :type user|assistant|tool|notice|request :start MARKER :end MARKER :folded BOOL . EVENT-FIELDS)`。
`request` 同时保留在待回答队列和时间线中，显示条目使用 `(request . ID)` 命名空间，避免与工具 ID 冲突；完成后更新原卡片状态，不折叠进 Process。确认正文 `:message`、输入提示 `:placeholder` 不当作默认答案。当前聊天通过一次性 timer 自动进入 minibuffer；已有 minibuffer 或其他 Agent 的交互尚未结束时延后，后台聊天不抢焦点。`C-g` 归一为 `:cancelled`，由各后端转换为取消/拒绝/空答案，不能当作同意；等待期间被撤回的请求不再回复。
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
| `agent-dash-backend-sessions (backend root)` | 否 | hub 用：会话 plist，字段 `:id :root :first :title :last :time :exact :running :file :empty`（见 core 中的文档串） |
| `agent-dash-backend-delete (backend session)` | 否 | 永久删除；能力 `:delete` 声明支持（Claude、Pi） |
| `agent-dash-backend-transcript (backend id)` | 否 | hub 详情与 @ 引用：`((user . TEXT) (assistant . TEXT) …)` |
| `agent-dash-backend-capabilities (backend)` | 是 | plist：`:quit stop\|detach`、`:steer`、`:images`、`:models` |
| `agent-dash-backend-commands (backend session)` | 否 | 后端实际公布的命令/skill，`((NAME . DESCRIPTION) …)` |
| `agent-dash-backend-command (backend session text mode)` | 否 | 默认沿正常发送协议执行；Pi 内置命令转 RPC/认证控制通道或明确拒绝，DSH 区分 Host 命令与注册 skill |

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
- Pi 启动参数区分新建与恢复：新建使用 `--session-id` 分配 ID；恢复必须先定位真实历史文件并使用 `--session <绝对路径>`，不能假设 CLI 按 ID 能在当前项目目录以外找到文件。缺失历史文件时报错，不静默新建空会话；仍存活的 holder 直接接回，不依赖尚未落盘的历史。
- 接回策略：Pi 从日志末尾开始跟读，并用 `get_entries` 的 `leafId` 沿父链补全当前分支的历史，包括压缩前消息，排除废弃分支和合成压缩摘要。`get_messages` 只是当前模型上下文，不等同于完整聊天历史；旧版 RPC 不支持完整条目时才回退，并显示上下文受限警告。Claude、Codex、Hermes 从头回放整段日志（各自按 uuid、item id、日志顺序去重或定位）。

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
| projection `contextPressure` / `sessionStats` / `tokenUsage` / `modelSelection` / `agentPreset` / `permissions` | 归一化进 `meta`，供共享状态栏读取 |
| `snapshot` | 按记录逐条回放成上面的事件 |

DSH 的 `session/follow` 快照提供初始投影；同一 websocket 同时订阅 `session/control`，处理 baseline、批量 changes 和旧版 key/value 替换帧，只应用当前 sid。按字段记录序号，忽略旧替换；未出现的键保留旧值，显式 null 清空。模型 selection 事件也经过同一缓存，避免后续统计更新覆盖新模型。

指标来自 Host，而不是数聊天消息猜测：上下文优先 `projectedTokens`，否则 `pressureTokens`；轮步取 `sessionStats.turns/steps`，速度为 `1000 * decodeTokens / decodeMs`（分母须大于 0）。总 token 为 `uncachedInputTokens + cacheReadTokens + cacheWriteTokens + outputTokens`，缓存比例为 `cacheReadTokens / (uncachedInputTokens + cacheReadTokens + cacheWriteTokens)`；计算所需桶缺失时不显示相应总量/比例，不把已有缓存桶再加进 input 总量，不推算费用。右侧从 `modelSelection.next` 读取 provider/model/reasoningEffort，另显示 agentPreset 和 permissions.currentValue。统计和右侧扩展字段仍由五后端共用的 UI 格式化。

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

历史列表和 transcript 优先通过 `sqlite3 -readonly` 读取原生 `state.db`，覆盖 Hermes CLI 会话；过滤被撤回消息、界面装饰和压缩交接，保留空会话元数据供 Hub 决定是否隐藏。无原生索引时回退 ACP；ACP `session/list` 本身只列出经 ACP 创建的会话。

### 5.6 结论

五个后端的全部记录都有对应的统一事件，或被明确忽略，没有映射不了的条目。和 HANDOFF 4.3 的草案相比有三处改动：
1. `text-delta` / `message-final` 合并成 `assistant` 一种事件，用 `:final` 区分流式快照和权威内容。
2. 新增 `request` / `request-done`（Claude 权限请求、Pi 扩展对话框、DSH 审批）。
3. `status` / `usage` 合并进 `meta`；`thinking` 作为 `assistant` 的 `:thinking` 字段。

## 6. 界面（以 emacs-pi DESIGN §7、§9、§11 为蓝本）

- 历史区只读，底部是输入区。`RET` / `C-c C-c` 发送（运行中发送即 follow-up），`S-RET` 换行，`C-c C-s` steer，`C-c C-k` 停止，`C-c C-q` 退出（按 `:quit` 语义），`M-p` / `M-n` 浏览输入历史，非输入区按 `i` 或任意位置 `C-c C-i` 聚焦输入框末尾（输入区内 `i` 保持普通字符输入与数字前缀行为），`C-c C-b` 切换聊天，`C-c C-r` 恢复历史会话，`TAB` 在过程行上折叠/展开。
- 五个后端共用同一套 UI 布局与交互，不按后端复制界面。用户回合的正文以 highlight face 全宽高亮，前导分隔空行不带高亮 face；底部 `You>` 通过 overlay 装饰输入区，不进入发送内容或历史。输入 face 与 emacs-pi 一致：继承 widget-field 背景、明确 `:underline nil`、`:extend t`，不硬编码主题颜色。输入 overlay 的 after-string 用 display-only stretch space 填充到窗口右边缘，保证空草稿和末行也铺满背景；填充不进入草稿、发送内容或历史。填充首字符必须带 `cursor t`，将光标锚定在提示符/草稿后，而非虚拟提示符开头或窗口右边缘。header-line 置顶最近一条用户消息。
- 工具、纯 thinking 消息与 Pi 带 toolCall 的中间消息按用户回合收进 `Process · N steps`。后端 running 时默认展开当前回合和步骤细节；整轮 idle/dead 后自动折叠，最终答复不隐藏，不能将单条 assistant final 当作整轮结束。`run` 事件没有时间线 item，也必须触发分组更新。标题 `RET`/`TAB` 控制整组，单步可手动折叠；流式更新和重绘保留手动选择，结束转换仍收起整组。用已结束标记区分历史与运行状态晚到的未完成快照，新 run 信号本身不重开已完成历史；同一用户回合的新过程活动可重新展开。有正文的最终消息，其 thinking 仍单独折叠。
- tab-line 左对齐显示已知统计，右边缘对齐显示 `(provider) 模型 · 思考等级`，并在后端提供时追加 Agent 预设、权限模式，对齐锚点与 emacs-pi 一致。窄窗口先去掉低优先级统计，再去掉 provider，必要时截断；完整信息保留在 help-echo。Pi 统计含 context、token、prompt/call 数、缓存读取比例和预估费用（非账单）；其他后端缺失的数据不虚构。实际 RPC `get_session_stats` 的 `contextUsage` 提供上下文；附着后和 `agent_settled` 时刷新，重绘不请求数据。
- 五后端共用精简 mode-line：`Pi thinking |` / `Claude idle` / `DSH waiting ?1` 等。活动指示器与 emacs-pi 一样放在普通 `mode-line-misc-info` 区，不占 `mode-line-process`、不重复模型信息。运行中每 150ms 轮换 `|/-\`，只重绘状态、不请求后端、不改草稿；空闲、断开、关闭 buffer 或切换 major mode 时清理 timer。非空队列显示 `[S1 F2]`、待处理请求显示 `?N`，具体阶段（如 `waiting for model` / `responding`）与操作键放在 tooltip。重复热载不会增加 indicator 或 timer；`agent-dash-refresh-chat` 可无损重建显示，保留连接、草稿和输入区光标位置。不宣称与旧客户端完全等价：队列编辑等仍待迁移。
- 草稿与历史分开存放：后台输出不能修改输入区。
- `agent-dash-images.el` 统一附件与缩略图，规范为 `(:data BASE64 :mime-type MIME :name NAME)`。输入区的待发送缩略图在 overlay before-string 中，不进入草稿/历史；删除、后台输出和重绘保持草稿与光标。本地签名/大小校验限定 PNG/JPEG/GIF/WebP，不执行 SVG、不自动下载远程图片。终端或无法解码时保留可操作占位文本，原图通过 Emacs image-mode 查看。
- 五后端分别编码为 Pi image/mimeType、Claude base64 source、Codex image data URL、DSH image/mediaType、Hermes ACP image/mimeType；Hermes 声明不支持时拒绝附件。DSH 历史附件在接收协议数据时经 Host session/attachment 读取并按会话缓存，重绘不做 RPC。恢复时归一化用户、助手和工具的图片块，纯图片消息也保留。
- 图片写入失败保留草稿；可关联的 Pi/Codex/Hermes 请求失败只恢复未被更新提交取代的空草稿，旧响应不能覆盖新输入；迟到的旧失败保留为独立可选草稿。保留失败/最近含图草稿供 C-c C-u 手动恢复，不自动重发；后续模型/工具错误不意味着此前未执行。含附件时拒绝 slash 命令，避免接口不支持附件却静默丢图。

### 6.1 输入补全

`agent-dash-input.el` 为五后端共用输入层：`TAB` 在 `/`、`@file`、`@session`、`@dash` 后调用标准 `completing-read`，保留 Vertico UI，在 picker 内可选启用 Orderless，不改全局 completion 配置。`@session` 限当前 Agent（跨项目），`@dash` 使用全 Agent Hub 清单，显示/匹配摘要、末句、项目、日期和完整 ID；同名会话不混淆。选中后生成已有 `agent-dash:` 引用格式，发送过滤器负责按原预算展开。目录读取不请求模型。替换范围用 marker 跟踪后台输出，取消或草稿被改动时不覆盖输入。

`/` 默认合并本地命令与后端真实目录，按名称去重，本地命令优先；Pi 例外，只显示原生目录；`C-u TAB` 刷新目录。客户端 `/help`、`/new`、`/resume`、`/dash`、`/stop`、`/quit`（及支持时的 `/model`）不发给模型，且不忽略多余参数。Pi 采用安装版内置目录（优先运行中桥接公布的清单）加 `get_commands`，不向其补全额外插入客户端别名；Claude 存 init.slash_commands（热载可从原 holder 日志恢复），DSH 用 commands/list + skills/list，Hermes 存 available_commands_update；Codex 未暴露 CLI 斜杠菜单，不虚构。DSH 只有已验证注册的 skill 会作为 prompt 提交，Host 命令走 commands/execute，失败保留草稿、成功显示返回文本。

Pi 内置命令不会使用 `prompt` 兜底：可映射的操作走原生 RPC，认证通过 `agent-dash-pi-bridge.mjs` 的私有控制通道处理，其余标记终端 UI 专用并拒绝。控制帧借用无人等待的 `extension_ui_response`，以随机操作 ID 关联；即使桥接不存在，stock RPC 也只忽略，不触发模型。结果通过带前缀的 `ctx.ui.notify` 返回，由客户端解包，避免 SDK 捕获扩展 stdout 或打断其他 RPC 输出。五秒内无接收确认时失败，不重发；收到确认后等待交互结果，退出清理状态。

认证桥接复用当前 Pi 注册表背后的 runtime（包括扩展 provider），不另建凭据存储。`ModelRegistry.runtime` 是版本敏感的内部访问，集中检查所需方法，不支持则安全失败。API-key/OAuth 的所有自由文本认证输入均转换为 secret 请求，Emacs 使用 `read-passwd`；旧 OAuth onPrompt 的普通文本也可能是密钥，不能依赖它的类型标签。输入值只经 UI 应答回传，不进入模型、聊天输入历史或结果通知；后续通知中的已输入值被替换。Native SDK 使用自己的锁和同步流程写凭据；仅在用户实际执行认证命令并完成交互后发生，不在目录查询或热载时登录。旧 holder 不会被自动停止或重建。

## 7. hub、摘要、搜索（复刻 ashub）

- `agent-dash-hub.el`：只调用后端接口（`sessions` / `transcript` / `delete`），没有按后端分支的代码。所有来源共用一份会话清单，逐个来源用定时器读取，header 显示扫描进度和失败的来源。分组、筛选、transient 菜单（`N` / `f` / `a` / `?`）、详情、删除标记、项目重定向（`agent-dash-hub-project-relocations`）、诊断，键位与 ashub 相同。
- `agent-dash-summary.el`：主入口按默认值为 t 的 `agent-dash-summary-enable` 启动 `agent-dash-summary-mode`。加载前设为 nil 可关闭自动启动（use-package 放在 `:init`）；运行时用 `(agent-dash-summary-mode -1)` 停止调度器。会话关闭并稳定 300 秒后才摘要，新任务通常至少间隔 60 秒，最新的会话优先。长对话会分段请求再汇总，该间隔不是单次模型调用或费用上限。内容指纹不变就不重复请求；失败后指数退避，401/403 或 gptel 缺失时整体暂停。gptel 为可选依赖，使用其默认后端/模型发送用户与助手对话（不含工具输出，但仍可能含隐私）。缓存文件为 `agent-dash-directory/summaries.eld`，只存摘要与调度元数据，不持久化完整 transcript。
- 摘要导入：启动时若已加载 `ashub-summary` 且存在 `*ashub*` buffer，读取该 Hub 的会话清单与摘要访问器，不逆解其磁盘缓存键、不调用模型。也可手动运行 `agent-dash-summary-import-ashub`。按 agent/id 匹配，仅填充本地尚无摘要的条目；源条目 checked-stamp 与 ashub 当前 stamp 一致时，首次注册本地会话采用其 stamp，否则保留原文并显示待更新。导入不会覆盖已有摘要；后续更新可能调用模型。两套摘要模式同时运行可能重复工作和计费，不自动停用旧 ashub 调度器。
- Hub 交互：`N` / `f` / `a` / `?` 使用 transient，新建与筛选组织方式对齐 ashub。详情为助手左、用户右的气泡，逐条带复制按钮；`m` 折叠元数据、`C-c C-w` 复制原始对话。详情缓存对话，`g` 只重新排版，重新打开才重新获取。
- `agent-dash-search.el`：分两轮。第一轮逐批抽取逐字证据，证据必须能在输入原文中找到，否则拒绝；第二轮只依据这些证据回答，引用必须覆盖全部来源编号。
- 各来源数据的限制：DSH 的 `session/list` 不提供首末句，后端从 bridge 文件同目录下 `storages/session_projcache/sessions/<id>.json` 的 `record.rows.turnOutline` 读取版本 2 的用户 prompt，过滤空白及非字符串值。缓存缺失或版本不支持时返回 nil；它是 Host 维护的投影，可能滞后或截断，不代表实时完整 transcript。Codex 优先读取最新数字版本的 `state_N.sqlite`，归档、内部及 rollout 丢失的元数据线程均保留；缺少 rollout 时不虚构末句。归档会话默认隐藏、不再排队摘要，但保留旧摘要，可切换摘要范围查看。没有索引时，app-server 显式列出全部来源及两种归档状态并处理 `nextCursor`，不使用默认交互来源过滤。Hermes 优先读取原生 SQLite 历史，ACP 仅为回退。Pi 递归发现所有 JSONL，以 header cwd 判定项目并用同一发现逻辑定位恢复文件；损坏文件逐个隔离，读取警告单独显示，不丢弃同源的有效会话。DSH 空会话保留 `:empty` 标记，不读取其 prompt 缓存，由共享摘要范围过滤。

## 8. 不做（本版）

TRAMP、Windows、分支树 UI、fork / clone、队列逐条编辑（mode-line 只显示队列计数）、DSH 模型切换。
