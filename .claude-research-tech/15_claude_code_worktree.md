# Claude Code Worktree 工作模式调研

> 调研日期：2026-04-14
> 目标：理解 Claude Code 的 worktree 隔离工作模式，评估在 WhisperUtil 开发中的应用场景

---

## Part 1: 概念与原理

### 什么是 Worktree 模式

Worktree 模式是 Claude Code 的内置隔离机制。启用后，Claude Code 会自动创建一个 git worktree——一个独立的工作目录，拥有自己的分支，但共享同一个 `.git` 历史和远程连接。这意味着多个 Claude 会话可以同时编辑文件而不会冲突。

该功能在 Claude Code v2.1.49（2026-02-19）中作为原生 CLI 支持引入。

### 与 Git Worktree 的关系

Claude Code 的 worktree 功能直接构建在 `git worktree` 之上。关键映射：

| 项目 | 值 |
|------|-----|
| Worktree 目录 | `<repo>/.claude/worktrees/<name>/` |
| 分支名 | `worktree-<name>` |
| 基础分支 | `origin/HEAD` 指向的远程默认分支 |

如果远程默认分支变更，需要重新同步：

```bash
# 自动检测远程默认分支
git remote set-head origin -a

# 手动指定
git remote set-head origin your-branch-name
```

---

## Part 2: 使用方式

### CLI 启动（主要方式）

```bash
# 命名 worktree
claude --worktree feature-auth
# 或简写
claude -w feature-auth

# 自动生成随机名称
claude --worktree
claude -w
```

### 搭配 tmux 使用

```bash
# 在独立 tmux session 中启动
claude --worktree feature-auth --tmux

# 使用传统 tmux（而非 iTerm2 原生面板）
claude --worktree feature-auth --tmux=classic
```

### 会话中途进入 Worktree

在对话中告诉 Claude "work in a worktree" 或 "start a worktree"，Claude 会内部调用 `EnterWorktree` 工具。`EnterWorktree` 也接受 `path` 参数来切换到已存在的 worktree。

### 多会话并行（典型工作流）

```bash
# Terminal 1 — 开发新功能
claude -w feature-auth

# Terminal 2 — 修复 bug
claude -w bugfix-123

# Terminal 3 — 实验性改动
claude -w experiment-router
```

每个会话拥有独立的文件、分支和 Claude 上下文，互不干扰。

---

## Part 3: 子代理（Subagent）的 Worktree 隔离

子代理（Agent 工具）也可以使用 worktree 隔离，有两种方式：

### 临时指定

在 prompt 中告诉 Claude "use worktrees for your agents"。

### 自定义 Agent 前置声明

```yaml
---
name: refactor-agent
isolation: worktree
---
```

每个子代理自动获得独立 worktree。子代理完成后若无更改，worktree 自动清理。

---

## Part 4: Worktree 清理机制

### 会话退出时

| 情况 | 行为 |
|------|------|
| 无任何更改 | Worktree 和分支自动删除 |
| 有更改或提交 | Claude 询问用户是保留还是删除 |

### ExitWorktree 工具（会话中途）

| 参数 | 说明 |
|------|------|
| `action: "keep"` | 保留 worktree 和分支在磁盘上 |
| `action: "remove"` | 删除 worktree 目录和分支 |
| `discard_changes: true` | 删除含未提交文件或未合并提交的 worktree 时必须指定 |

### 自动清理

孤立的子代理 worktree 在启动时自动清理，条件：

- 超过 `cleanupPeriodDays`（默认 30 天）
- 无未提交更改
- 无未跟踪文件
- 无未推送的提交

**注意：** 用户通过 `--worktree` 创建的 worktree 不会被自动清理。

### 手动清理

```bash
git worktree list        # 查看所有 worktree
git worktree prune       # 清理失效引用
git worktree remove <path>  # 删除指定 worktree
```

---

## Part 5: `.worktreeinclude` 配置

Git worktree 是全新 checkout，不包含 gitignored 的文件（如 `.env`）。要自动复制这些文件到新 worktree，在项目根目录创建 `.worktreeinclude`：

```text
.env
.env.local
config/secrets.json
```

规则：

- 使用 `.gitignore` 语法
- 只有同时匹配 pattern **且** 被 gitignore 的文件才会被复制
- 已跟踪的文件不会被重复复制
- 适用于 `--worktree`、子代理 worktree 和桌面端并行会话

**注意：** 如果配置了 `WorktreeCreate` hook，`.worktreeinclude` 不会被处理（hook 完全替代默认行为）。

---

## Part 6: 大型仓库优化

两个设置可优化大仓库中的 worktree 性能：

```json
{
  "worktree": {
    "symlinkDirectories": ["node_modules", ".cache"],
    "sparsePaths": ["src/", "packages/my-service/"]
  }
}
```

### symlinkDirectories

将主仓库中的目录通过符号链接引入 worktree，而非复制。适合 `node_modules` 等大型依赖目录，节省磁盘空间。

**已知问题：** 写入符号链接的文件可能将符号链接替换为普通文件（GitHub issue #40857）。

### sparsePaths

使用 git sparse-checkout（cone mode）只检出指定目录。未列出路径的文件不会写入磁盘。

---

## Part 7: Hooks 扩展

### WorktreeCreate Hook

用于自定义 worktree 创建逻辑（如非 git VCS 或额外初始化步骤）。

Hook 接收的 stdin JSON：

```json
{
  "session_id": "abc123",
  "cwd": "/Users/my-project",
  "hook_event_name": "WorktreeCreate",
  "base_branch": "main",
  "worktree_path": "/Users/my-project/.claude/worktrees/task-001"
}
```

**必须在 stdout 输出 worktree 路径。** 非零退出码 = 创建失败。

示例 hook 脚本：

```bash
#!/bin/bash
BASE_BRANCH=$(jq -r '.base_branch' < /dev/stdin)
WORKTREE_PATH=$(jq -r '.worktree_path' < /dev/stdin)
git worktree add "$WORKTREE_PATH" "$BASE_BRANCH" || exit 1
echo "$WORKTREE_PATH"
exit 0
```

### WorktreeRemove Hook

信息性 hook，不能阻止删除。用于清理副作用（归档、通知、日志）。

配置示例：

```json
{
  "hooks": {
    "WorktreeCreate": [{
      "hooks": [{
        "type": "command",
        "command": "bash \"$CLAUDE_PROJECT_DIR\"/.claude/hooks/worktree-setup.sh",
        "timeout": 30
      }]
    }],
    "WorktreeRemove": [{
      "hooks": [{
        "type": "command",
        "command": "bash -c 'jq -r .worktree_path | xargs rm -rf'"
      }]
    }]
  }
}
```

---

## Part 8: 对比分析

### Worktree 模式 vs 普通模式

| 方面 | 普通模式 | Worktree 模式 |
|------|---------|--------------|
| 文件系统 | 共享工作目录 | 每个会话独立 checkout |
| 分支 | 单一分支，手动切换 | 自动创建分支 |
| 并行安全性 | 有文件冲突风险 | 无冲突 |
| 磁盘占用 | 最小 | 每个 worktree 一份 checkout |
| 启动开销 | 无 | worktree 创建时间 |
| 清理 | 无需清理 | 自动清理或手动确认 |
| 依赖 | 已安装 | 可能需要重新安装 |
| gitignored 文件 | 已存在 | 需要 `.worktreeinclude` 配置 |

---

## Part 9: 使用场景决策矩阵

| 场景 | 使用 Worktree? | 理由 |
|------|:-----------:|------|
| 单文件快速修复 | 否 | 开销不值得 |
| 功能开发 + 同时修 bug | 是 | 需要分支隔离 |
| 多代理并行工作 | 是 | 防止文件冲突 |
| 大规模代码迁移（50+ 文件） | 是 | 可分批派发代理 |
| 探索性/一次性实验 | 是 | 无更改时自动清理 |
| 代码审查（只读） | 否 | 无文件修改需求 |

---

## Part 10: 已知问题与注意事项

| 问题 | 说明 |
|------|------|
| 依赖需重新安装 | 每个 worktree 是全新 checkout，`npm install` 等需重跑（可用 `symlinkDirectories` 缓解） |
| gitignored 文件缺失 | `.env` 等不会自动出现，需配置 `.worktreeinclude` |
| 磁盘占用 | 每个 worktree 是完整 checkout（可用 `sparsePaths` 缓解） |
| 基础分支不可逐次配置 | 始终使用 `origin/HEAD`，需通过 `git remote set-head` 或 hook 覆盖 |
| `.claude/` 子目录可能不被复制 | skills、agents、docs 等在某些版本中未复制到 worktree（GitHub issue #28041） |
| 不能嵌套 worktree | 已在 worktree 中时不能再进入另一个 |
| `cleanupPeriodDays: 0` | 可能导致所有 transcript 持久化被禁用，而非仅清理（GitHub issue #23710） |

---

## Part 11: 推荐的项目配置

### .gitignore 添加

```
.claude/worktrees/
```

防止 worktree 内容在主仓库中显示为未跟踪文件。

### 对于 WhisperUtil 项目

WhisperUtil 是 Swift/Xcode 项目，worktree 的主要考量：

1. **构建产物**：每个 worktree 需要独立构建，但 Xcode 的 DerivedData 默认在 `~/Library/Developer/Xcode/DerivedData/`，天然隔离
2. **无 `.env` 依赖**：API Key 存储在 macOS Keychain，不受 worktree 影响
3. **适用场景**：并行开发多个功能、实验性改动、多代理同时工作

---

## Part 12: 社区工具

| 工具 | 说明 |
|------|------|
| muxtree | 将 git worktree 与 tmux session 配对 |
| claude-tmux | 集中式 TUI，管理多个 Claude Code 实例 + worktree/PR 支持 |
| workmux | 将 worktree 与 tmux window 管理耦合 |

---

## 参考资料

- [Claude Code 官方文档 - Common Workflows (worktree 部分)](https://code.claude.com/docs/en/common-workflows)
- [Claude Code Hooks 参考 (WorktreeCreate/WorktreeRemove)](https://code.claude.com/docs/en/hooks)
- [Boris Cherny 发布线程（Anthropic 工程师）](https://www.threads.com/@boris_cherny/post/DVAAnexgRUj/)
- [Claude Code Worktrees 指南 (claudefast)](https://claudefa.st/blog/guide/development/worktree-guide)
- [MindStudio - Claude Code Git Worktree 模式](https://www.mindstudio.ai/blog/what-is-claude-code-git-worktree-pattern-parallel-feature-branches)
- [扩展 Worktree 实现数据库隔离](https://www.damiangalarza.com/posts/2026-03-10-extending-claude-code-worktrees-for-true-database-isolation/)
- [GitHub - claude-worktree-hooks](https://github.com/tfriedel/claude-worktree-hooks)
