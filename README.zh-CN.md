# agent-dash

[English](README.md) | 简体中文

在 Emacs 中直接与编码 Agent 对话，并在一处浏览所有 Agent 的会话。单一包，内置全部后端：

| 后端 | 运行方式 | `C-c C-q` |
|---|---|---|
| Pi | `pi --mode rpc`，后台 holder | 确认后结束实例 |
| Claude Code | `claude -p` stream-json，后台 holder | 确认后结束实例 |
| Codex | `codex app-server`，后台 holder | 确认后结束实例 |
| Hermes | `hermes acp`，后台 holder | 确认后结束实例 |
| DSH | 本机 DSH Host（Desktop bridge，或后台 holder 托管的 `dsh web`） | 只关闭界面 |

关闭聊天 buffer 或退出 Emacs 都不会停止 Agent；再次打开该会话时会重新接上同一个运行中的实例。设计说明见 [docs/DESIGN.md](docs/DESIGN.md)。

## 安装

依赖：Emacs 29.1+、`markdown-mode`、`websocket`、`transient`，以及要使用的那几个 Agent CLI。已在 macOS 上验证，Windows 不支持（依赖 FIFO 和 POSIX 进程）。

```elisp
(use-package agent-dash
  :vc (:url "https://github.com/wowhxj/agent-dash" :rev :newest)
  :commands (agent-dash agent-dash-hub))
```

## 使用

- `M-x agent-dash`：选择 Agent 和目录，新建会话。
- `M-x agent-dash-hub`：列出所有 Agent 的会话。

### 聊天 buffer

用户回合高亮，底部 `You>` 输入区可编辑，历史区只读；顶部置顶最近一条用户消息。工具和纯 thinking 消息按用户回合收进 `Process · N steps`：处理中自动展开当前分组及步骤细节，后端确认整轮结束后再折叠，最终答复保持可见。仍可用 `RET`/`TAB` 手动切换整组或单步，流式更新不覆盖手动选择；不会因为收到单条 final 消息就提前折叠仍在运行的任务。

五个后端共用布局：顶部左侧显示统计，右侧显示 provider/模型和思考等级；底部 mode-line 统一精简为如 `Pi thinking |` 的活动指示器，不重复模型信息。`|/-\` 动效仅在运行时启用，空闲/断开时停止；队列（`[S1 F2]`）和待处理请求（`?1`）只在有内容时显示。详细阶段和操作提示放在悬停提示中。窗口变窄时先隐藏低优先级统计。输入区沿用 emacs-pi 的主题背景，并明确禁用下划线。Pi 显示缓存的上下文占用、会话总 token、缓存读取比例及预估费用（不是账单），在连接后及任务结束时刷新。DSH 从 Host 投影恢复上下文、轮次/步数、解码速度、总 token 和缓存比例，并通过 control 流持续更新；右侧另显示 Agent 预设和权限模式。DSH 的计费桶只各计一次，不虚构费用。其他后端没有的数据不显示。界面重绘不调用 RPC 或模型。活动指示器的悬停提示用 `waiting for model`、`responding` 区分具体阶段，不在底部堆叠长文本。可用 `M-x agent-dash-refresh-chat` 重建已有聊天的显示，不重启 Agent，也不丢弃草稿。

目前尚未完整复刻 emacs-pi/emacs-claude 的全部交互：剪贴板图片界面和队列编辑仍未实现。

| 键 | 作用 |
|---|---|
| `RET` / `C-c C-c` | 发送；运行中排队为 follow-up（`RET` 优先回答待处理提问） |
| `S-RET` | 换行 |
| `C-c C-s` | steer（引导正在运行的任务） |
| `C-c C-k` | 停止当前任务 |
| `C-c C-q` | 退出（语义见上表） |
| `C-c C-a` | 手动打开待处理的权限请求或提问（默认也会自动弹出） |
| `C-c C-r` | 恢复历史会话 |
| `C-c C-b` | 切换到其他聊天 |
| `C-c @` | 打开跨 Agent 会话引用选择器 |
| `/`、`@`、`@session`、`@dash` + `TAB` | 在 minibuffer 中筛选补全（Vertico/Orderless） |
| `C-u TAB` | 刷新后端命令目录 |
| 非输入区按 `i` / 任意位置 `C-c C-i` | 回到输入区末尾（输入区内 `i` 仍正常输入） |
| `M-p` / `M-n` | 浏览已发送的输入 |
| `TAB` / `RET`（在工具或 thinking 行上） | 折叠 / 展开 |
| `M-x agent-dash-select-model` | 切换模型 |

### 选择与确认

当前选中的聊天收到提问时，会自动在 minibuffer 中交互，不在进程过滤器内阻塞。后台聊天保留可见的问题卡片和 `?N` 提示，切回后再弹出；已有 minibuffer 操作不会被抢占，草稿也不会丢。设置 `(setq agent-dash-auto-answer nil)` 可改为只通过 `RET` 或 `C-c C-a` 手动回答。

- **单选**：补全选择；自由输入问题可填写自定义文本。
- **多选**：原生多选问题使用逗号分隔补全；Pi 的 `ask_user` RPC 降级交互会逐次展示勾选项，选 **Done** 完成，选 **Other** 自定义输入。批量问题和可选补充说明也会依次弹出。
- **取消**：在交互中按 `C-g`，向后端返回取消，绝不视为授权。Pi 收到明确取消，Claude 拒绝工具调用，Codex/DSH 返回空问题答案，Hermes 取消权限请求。
- 确认正文、输入提示和编辑器预填文本会保留；minibuffer 中可用 `C-q C-j` 插入换行。Pi 请求超时或撤回会清理待处理状态，不发送过期答案。

### 输入补全

- `/` + `TAB`：共用客户端命令（`/help`、`/new`、`/resume`、`/dash`、`/stop`、`/quit`，支持时还有 `/model`）加后端实际公布的命令/skill。选中后按 `RET` 执行；客户端命令不接收参数，需要选择时打开对应 picker。
- `@` + `TAB`：补全项目文件，或转到会话引用选择器；含空格的路径会加引号。
- `@session` + `TAB`：当前 Agent 的历史会话，跨项目。
- `@dash` + `TAB`：Hub 中全部 Agent 的会话，可按 Agent、项目、摘要、末句和 ID 多词筛选。发送时沿用已有引用展开逻辑附上对话。

选择器统一走 `completing-read`，沿用当前 Vertico，安装了 Orderless 时仅在 picker 内启用，不修改全局设置。`C-g` 保留草稿；后台输出不会导致替换位置偏移。补全只读目录，不调用模型。Pi 合并本机内置目录与 `get_commands`（见下节）；Claude 读取初始化目录；DSH 读取 Host 命令与注册 skill；Hermes 使用 ACP 公布的命令。Codex 目前提供共用客户端命令，不冒充其 CLI 专有斜杠菜单。DSH Host 命令会展示执行结果，已验证注册的 skill 则作为 prompt 提交。

### Pi 原生命令

Pi 补全采用自身的内置命令（当前验证版本共 24 个）加 RPC 公布的扩展、提示模板与 skills，不混入额外客户端命令名；`/help`、`/dash`、`/stop` 仍可手动输入。`/model provider/model-id`、`/thinking`、`/compact`、`/name`、`/session`、`/copy` 和 HTML `/export` 使用原生 RPC。

`/login [provider-id]`、`/logout [provider-id]` 通过正在运行的 Pi runtime 处理，包含扩展注册的 provider。安装时须将 `agent-dash-pi-bridge.mjs` 与 Elisp 文件一并保留。可选择 provider 和认证方式；所有认证自由文本输入都走 `read-passwd` 遮罩，包括旧 OAuth 接口的 API-key 提示和地址字段。不要在 `/login` 后附加密钥；认证命令不进入输入历史或模型上下文。`C-g` 取消对话，失败不自动重试；授权链接仅显示，不自动打开浏览器或覆盖剪贴板。

**旧 Pi 后台进程需先 `/quit` 停止，再从 Hub 恢复以加载桥接；仅关闭聊天 buffer 会复用旧进程。** 不会自动重启正在执行的任务。桥接缺失、未知命令均明确拒绝，不回退到模型。`/settings`、`/tree`、`/fork`、`/clone`、`/trust`、`/share`、`/reload` 等终端 UI 专用命令会标记并提示限制，不把“目录一致”冒充“完整实现了终端界面”；`/hotkeys` 显示当前 Emacs 键位。

### 图片

五个后端均通过原生协议发送图片。`C-y` 或 macOS `s-v` 粘贴图片（文本仍正常粘贴），`C-c C-v` 仅粘贴图片，`C-c C-f` 选择本地文件。macOS 图片粘贴使用可选的 `pngpaste`，Linux 使用 `wl-paste` 或 `xclip`；选图不依赖剪贴板工具。

待发送缩略图显示在 `You>` 上方，不混入草稿文字。点击 `× remove` 或按 `C-c C-d` 移除附件，点击图片或按 `C-c C-o` 在 Emacs 查看原图。支持只发图片；执行 `/` 命令前需先移除附件。

按文件内容识别 PNG/JPEG/GIF/WebP，单图客户端上限 10 MiB、最多 10 张，另有总量限制；模型可能有更低限制。本地发送失败保留草稿，Pi/Codex/Hermes 可关联的请求拒绝可恢复没有更新提交时的空草稿；`C-c C-u` 可选择恢复失败或最近的含图草稿，不覆盖新输入，也不自动重发。模型报错前可能已经执行了部分操作，重试前请先确认。

恢复历史时显示用户和助手的图片块，工具图片在展开详情后显示。缺失、超限或无法解码的图片保留占位提示；不自动下载远程 URL，不可信本地图片路径需确认，不渲染 SVG，不将图片二进制混入文本会话引用或摘要。旧版本已打开的聊天可从 Hub 重新恢复，以重新解析此前忽略的图片。

### hub

历史扫描覆盖 Pi 根目录、项目目录和嵌套 JSONL；Codex 最新原生索引中的归档、子代理及仅剩元数据的线程；DSH 空会话；以及 Hermes 原生索引中的 CLI 历史。空会话、内部会话和归档会话先计入“已载入”，再由 Hub 过滤。Codex/Hermes 索引通过 `sqlite3 -readonly` 读取，需安装 `sqlite3`，不修改原生历史库。Codex 没有索引时回退到覆盖所有来源、归档状态并完整分页的 app-server 列表。`!` 可查看逐来源读取警告。

`M-x agent-dash-hub` 铺满当前 frame，按项目分组列出所有会话。列：Agent、`●` 运行中、日期（`*` 表示来源时间，不是消息时间）、短 ID、项目、摘要（未生成时显示首句）、用户末句、摘要状态。

| 键 | 作用 |
|---|---|
| `RET` | 打开；已有聊天时直接切过去 |
| `N` | 新建：按 `C`/`x`/`p`/`d`/`m` 选 Claude/Codex/pi/dsh/Hermes，再选目录 |
| `i` | 详情：元数据与完整对话 |
| `n` / `p`、`TAB` | 移动；折叠分组 |
| `j` | 按任意文本定位会话 |
| `f` | 视图菜单：项目、Agent、仅 live、显示隐藏、分组方式 |
| `a` / `P` / `l` / `t` / `c` | Agent 筛选 / 项目筛选 / 仅 live / 时间倒序与分组切换 / 恢复默认 |
| `s` | 语义搜索与问答（摘要或全文，经 gptel） |
| `r` / `R` | 重新生成本条摘要 / 重试失败摘要 |
| `d` / `u` / `x` | 标记 / 取消 / 执行删除（Claude、Pi） |
| `D` | 项目目录搬家后重定向 |
| `w` / `W` | 复制 ID / 项目路径 |
| `!` / `?` / `q` | 诊断 / 命令菜单 / 恢复窗口布局 |

### 摘要与已有 ashub 数据

加载 `agent-dash` 时默认启动摘要模式。gptel 是可选依赖，但生成摘要与语义搜索需要它配置好的默认后端/模型。要关闭自动启动，请在加载包**之前**设置（使用 `use-package` 时放在 `:init`）：

```elisp
(setq agent-dash-summary-enable nil)
```

要停止已经运行的调度器，执行 `(agent-dash-summary-mode -1)`；只修改启动选项不会停止现有调度器。

启动时若已加载 `ashub-summary` 且存在 `*ashub*` buffer，会从其会话清单复制已有摘要，**不调用模型重算**。稍后也可运行 `M-x agent-dash-summary-import-ashub`。不会覆盖 agent-dash 已有摘要；ashub 中仍有效的条目在本地列出会话时采用当前时间戳，已过期的条目保留原摘要并等待更新。

已关闭且内容稳定 300 秒的会话才进入摘要队列。新摘要任务通常至少间隔 60 秒，但长对话会分段请求并再次汇总，因此这**不是模型调用次数或费用上限**。发送内容为用户/助手对话（不含工具输出），其中仍可能含隐私；磁盘只保存摘要与调度元数据，不保存完整对话。若同时启用 ashub 与 agent-dash 的摘要模式，两套调度器可能重复调用模型、产生费用，请按需明确关闭其中一个。

DSH 首句和末句读取本地 Host 投影缓存（`turnOutline` 版本 2），不是 `session/list` 的原生字段。缓存缺失或版本不支持时没有首末句；缓存文本可能滞后或已被 Host 截断。详情（`i`）采用助手左、用户右的气泡，支持逐条复制、折叠元数据（`m`）和复制原始对话（`C-c C-w`）；`g` 仅重新排版缓存对话，重新打开详情才会重新获取。`N`/`f`/`a`/`?` transient 菜单按 ashub 的交互方式组织。

## 开发

```sh
make check    # 编译（警告视为错误）+ ERT 测试 + elisp-lint
make indent   # 按 lint 的要求重新缩进
```

测试全部离线运行，使用 `test/bin/` 下的替身程序，不读取真实会话，也不调用模型。lint 依赖 `~/.emacs.d.default/elpa` 中已安装的包，可用 `ELPA=...` 指定其他目录。
