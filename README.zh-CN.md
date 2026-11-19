# agent-dash

[English](README.md) | 简体中文

在 Emacs 中与 **Pi、Claude Code、Codex、DeepSeek Harness（DSH）和 Hermes** 原生对话，并用统一的 Hub 浏览和恢复历史会话。所有后端均已内置，只需安装自己使用的 Agent CLI。

## 安装

需要 Emacs 29.1+、macOS 或 GNU/Linux，以及 `markdown-mode`、`websocket`、`transient`（0.7+）。请先安装并登录 Agent CLI，确保 Emacs 能通过 `exec-path` 找到它。浏览 Codex 和 Hermes 历史还需要 `sqlite3`。

使用支持 `:vc` 的 `use-package`：

```elisp
(use-package agent-dash
  :vc (:url "https://github.com/wowhxj/agent-dash")
  :commands (agent-dash agent-dash-hub)
  :init
  ;; 可选：关闭默认启用的后台摘要调度器。
  (setq agent-dash-summary-enable nil))
```

也可以将仓库加入 `load-path` 后执行 `(require 'agent-dash)`。请保留与 Elisp 文件同目录的 `agent-dash-pi-bridge.mjs`，Pi 原生命令需要它。

**后台摘要默认启用**，以上配置示例选择关闭。启用后会将历史用户/助手对话发送到已配置的 gptel 模型，可能产生费用，详见[摘要与隐私](#摘要与隐私)。

## 开始使用

- `M-x agent-dash`：选择 Agent 和工作目录。
- `M-x agent-dash-hub`：浏览各 Agent 的历史；`RET` 打开或恢复会话，`N` 新建。

聊天在后台运行，关闭 buffer 或退出 Emacs 后仍可继续。`C-c C-q` 会在确认后停止 Pi、Claude、Codex 或 Hermes；对 DSH 则只断开连接，Host 会话继续运行。连接丢失时，可从 Hub 重新打开会话。

## 聊天

| 按键 | 操作 |
|---|---|
| `RET` / `Shift-RET` | 发送 / 换行 |
| `TAB` | 输入区补全 `/` 命令和 `@` 会话引用；其他位置展开或折叠条目 |
| `M-p` / `M-n` | 上一条 / 下一条输入 |
| `C-c C-k` | 中断当前任务 |
| `C-c C-s` | 暂存引导消息，在队列中确认交付 |
| `C-c C-i` | 聚焦输入区 |
| `C-c C-f` / `C-c C-v` | 添加图片文件 / 剪贴板图片 |
| `C-c C-d` | 移除草稿图片 |
| `C-c C-o` | 打开附件或收到的图片 |
| `C-c q` | 打开队列编辑器 |
| `C-c C-a` | 回答待处理请求 |
| `C-c C-q` | 停止或断开 |

可用 `M-x agent-dash-select-model` 切换模型，需后端支持。`@` 引用会将历史用户/助手对话插入待发送消息。`/` 补全列出当前后端可用命令；Pi 还支持登录、登出、重载等原生命令，这些操作不会发送给模型。

任务运行中，普通发送进入本地 follow-up 队列。消息交付前可查看、排序、编辑或删除；交付后不能撤回。引导消息需在队列中明确确认交付；不支持 steer 的后端会转为 follow-up。**队列不会在 Emacs 重启后保留。**

图片支持 PNG、JPEG、GIF 和 WebP。选择文件不依赖剪贴板工具；粘贴图片需要 macOS 的 `pngpaste`，或 Linux 的 `wl-paste` / `xclip`。后端不支持图片时会明确拒绝，不会静默丢弃附件。

## 会话 Hub

【摘要】列优先显示 AI 摘要，没有摘要时显示首条用户消息；末条用户消息单独显示。会话有新活动后，按 `g` 刷新。

| 按键 | 操作 |
|---|---|
| `RET` / `N` | 打开会话 / 新建会话 |
| `j` | 搜索所有已载入会话，包括隐藏分组 |
| `n` / `p` | 下一个 / 上一个可见会话 |
| `C-c C-n` / `C-c C-p` | 下一个 / 上一个项目 |
| `C-c C-j` | 选择项目并跳到项目标题行 |
| `TAB` / `Shift-TAB` | 折叠当前 / 全部分组 |
| `f` / `a` / `P` | 视图筛选 / Agent 筛选 / 项目筛选 |
| `l` / `c` | 切换仅存活视图 / 重置筛选 |
| `i` | 查看对话；`m` 切换元数据，`C-c C-w` 复制对话 |
| `s` | 通过 gptel 进行语义搜索 |
| `r` / `R` | 生成或更新选中会话摘要 / 重试失败摘要 |
| `d` / `u` / `x` | 标记 / 取消标记 / 执行历史删除，仅支持 Pi 和 Claude |
| `!` / `?` / `q` | 诊断 / 帮助 / 返回 |

空会话、子代理、归档及其他不摘要会话默认隐藏，按 `f h` 可显示。删除历史不会停止正在运行的 Agent。项目目录移动或缺失时，可用 `D` 选择替代目录，不会改写历史对话。

## 摘要与隐私

摘要和语义搜索需要已配置的 [gptel](https://github.com/karthink/gptel)；聊天及普通 Hub 浏览不需要。

- 后台摘要处理已关闭且内容稳定 300 秒的会话。长对话可能需要多次模型调用，调度间隔**不是费用上限**。
- 即使不含工具输出，用户/助手对话仍可能包含隐私。语义搜索也会将本次搜索选择的摘要或对话发送给 gptel。
- 不希望自动摘要时，请在**加载包之前**设置 `(setq agent-dash-summary-enable nil)`。已启动的调度器需通过 `M-x agent-dash-summary-mode` 关闭。

## 常用设置

使用 `M-x customize-group RET agent-dash` 查看全部选项。

| 变量 | 用途 |
|---|---|
| `agent-dash-dsh-connection` | `auto`（默认）、`desktop` 或 `managed`；managed 模式启动 `dsh web` |
| `agent-dash-dsh-permission` | 新会话默认 `"auto"`；可设为 `"read-only"`，或 nil 沿用 Host 默认值 |
| `agent-dash-notify` | 开关后台任务结束提醒 |

Emacs 获得焦点时通过消息提醒后台任务结束，否则发送桌面通知。桌面通知优先使用已配置的 `notify-send` 封装，否则使用内置通知；失败后回退到 Emacs 消息。mode-line 标记可跳转到待回答请求和未读完成会话。DSH 断开后不会继续发送 Emacs 通知。

暂不支持：TRAMP、Windows、分支/fork 界面。

贡献者可用 `make check` 执行离线测试、严格编译和 lint，用 `make indent` 格式化 Elisp。架构说明见 [docs/DESIGN.md](docs/DESIGN.md)。
