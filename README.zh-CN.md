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

也可以将仓库加入 `load-path` 后执行 `(require 'agent-dash)`。请将仓库根目录中的 `agent-dash-*.mjs` 脚本与 Elisp 文件放在一起，以使用 Pi 原生命令和本地会话转换。

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
| `u` | 清除当前行的选择及待删除标记，光标留在原处 |
| `m` / `M` / `U` | 切换当前会话的选择并下移 / 全选当前筛选结果 / 清空选择 |
| `i` | 查看对话；在详情页内，`m` 切换元数据，`C-c C-w` 复制对话 |
| `s` | 通过 gptel 进行语义搜索 |
| `r` / `R` | 生成或更新选中会话摘要 / 重试失败摘要 |
| `d` / `u` / `x` | 标记 / 取消标记 / 执行历史删除，仅支持 Pi 和 Claude |
| `!` / `?` / `q` | 诊断 / 帮助 / 返回 |

例如，按 `a C` 筛选 Claude Code，按 `q` 回到列表，再按 `M`。`v s` 把所选会话转到 Pi，`v d` 将所选会话导入当前 DSH，`v e` 仅导出 ZIP。要删除时，先按 `d` 标记，再按 `x` 确认所有待删除项。`M` 包含折叠组中符合筛选条件的已加载会话。切换筛选后，仅保留仍符合条件的选择。

空会话、子代理、归档及其他不摘要会话默认隐藏，按 `f h` 可显示。删除历史不会停止正在运行的 Agent。项目目录移动或缺失时，可用 `D` 选择替代目录，不会改写历史对话。

## 把 Claude Code 或 Codex 历史带到 Pi 或 DSH

打开 Hub，将光标放在一条 Claude Code 或 Codex 会话上，按 `v s` 转换所选会话（未多选时转换光标所在的一条），`v p` 转换当前项目已加载的 Claude 和 Codex 会话，`v b` 按来源后端批量转换。转换器用 Node.js 在本机读取 Claude 项目中的 JSONL 或 Codex rollout，无需登录来源账号。转换后 Hub 以 Pi 会话显示这段历史，按 `RET` 即可继续。原始记录集中保存在 `agent-dash-directory` 下的 `conversion-archives/`。通过 Hub 把 Claude 会话迁到 Pi 时，程序会校验归档和 Pi 会话，然后移除 Claude 项目目录里的源 JSONL。迁出前使用 `lsof` 检查写入进程；检测到写入或无法完成检查时，保留源文件并在报告中注明原因。若要在 Claude 中恢复，把归档复制回原项目的会话目录，并以原 Claude 会话 ID 加 `.jsonl` 命名。Codex 转换和 DSH 导出均保留源文件。续聊使用你为 Pi 配置的模型。

相同来源内容和目标项目重复转换会复用已有 Pi 会话，包括已经追加的新消息。来源内容更新后再转换，会产生单独的快照。批量报告默认每条会话占一行，显示迁移结果、失败原因和影响续聊的提示。在一行上按 `TAB` 或 `RET` 展开或收起完整 ID、目标文件、归档位置和原始诊断。Claude 转换沿最后一条对话的父记录链恢复当前上下文；压缩前历史和其他分支中未出现在这条链上的记录，仍可在原件归档中查看。Codex 有可读的压缩检查点时，从检查点恢复上下文并追加后续记录。遇到无法可靠还原的回滚，报告会给出归档路径。源文件中已经缺失的内容无法重建。归档含完整的源记录，可能包含工具输出、命令和私密内容；换机时请连同原件归档和 Pi 会话一起备份。

如果只剩一份原始文件，或者 Codex 索引已经丢失，也能从检出的仓库直接运行转换器。下列参数依次为来源、源文件绝对路径、文件内记录的会话 ID、新机上的项目目录、Pi 会话目录和原件归档目录。下面的命令保留输入文件。从 Claude 原生项目目录迁出时，可在第一条命令末尾加 `--migrate-claude`。DSH 导出使用相同参数，第五项用于检查目录隔离。

```sh
node agent-dash-convert.mjs claude "$SOURCE_JSONL" "$SESSION_ID" "$PROJECT" "$PI_SESSIONS" "$ARCHIVES"
node agent-dash-dsh-export.mjs codex "$ROLLOUT" "$SESSION_ID" "$PROJECT" "$PI_SESSIONS" "$ARCHIVES"
```

要在 DSH 续聊，需要本机有 `python3` 来生成 ZIP。在 DSH 的「插件 → 更多 → 实验性插件」启用 **DeepSeek chat import**，然后在 Hub 按 `v d`。导入器在源项目对应的 DSH 工作区创建会话，回读历史并核对来源，成功后报告原生 DSH 会话 ID。Claude 原件在校验后迁出，Codex 原件保留。需要把 ZIP 带到另一台机器时，按 `v e`，再使用目标 DSH 的上传按钮手动导入。历史工具调用及结果以带来源标记的文本进入对话；原件归档保留原生记录。手动上传同一份 ZIP 会生成重复的 DSH 会话。

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
| `agent-dash-dsh-permission` | 新会话默认使用完全权限 `"danger-full-access"`。设为 `nil` 可沿用 Host 默认值。 |
| `agent-dash-notify` | 开关后台任务结束提醒 |

Emacs 获得焦点时通过消息提醒后台任务结束，否则发送桌面通知。桌面通知优先使用已配置的 `notify-send` 封装，否则使用内置通知；失败后回退到 Emacs 消息。mode-line 标记可跳转到待回答请求和未读完成会话。DSH 断开后不会继续发送 Emacs 通知。

暂不支持：TRAMP、Windows、分支/fork 界面。

贡献者可用 `make check` 执行离线测试、严格编译和 lint，用 `make indent` 格式化 Elisp。架构说明见 [docs/DESIGN.md](docs/DESIGN.md)。
