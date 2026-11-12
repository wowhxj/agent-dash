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

| 键 | 作用 |
|---|---|
| `RET` / `C-c C-c` | 发送；Agent 运行中发送则排队为 follow-up |
| `S-RET` | 换行 |
| `C-c C-s` | steer（引导正在运行的任务） |
| `C-c C-k` | 停止当前任务 |
| `C-c C-q` | 退出（语义见上表） |
| `C-c C-a` | 回答 Agent 的权限请求或提问（mode-line 显示 `?N`） |
| `C-c C-r` | 恢复历史会话 |
| `C-c C-b` | 切换到其他聊天 |
| `C-c @` | 插入 @session 引用；发送时附上被引用会话的对话内容 |
| `@路径` + `TAB` | 补全文件路径 |
| `M-p` / `M-n` | 浏览已发送的输入 |
| `TAB` / `RET`（在工具或 thinking 行上） | 折叠 / 展开 |
| `M-x agent-dash-select-model` | 切换模型 |

### hub

`RET` 打开（如已有聊天则直接切过去），`N` 新建，`/` 过滤，`d` 查看详情，`g` 刷新，`?` 打开菜单。

## 开发

```sh
make check    # 编译（警告视为错误）+ ERT 测试 + elisp-lint
make indent   # 按 lint 的要求重新缩进
```

测试全部离线运行，使用 `test/bin/` 下的替身程序，不读取真实会话，也不调用模型。lint 依赖 `~/.emacs.d.default/elpa` 中已安装的包，可用 `ELPA=...` 指定其他目录。
