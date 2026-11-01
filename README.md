# pi-codex-supervisor

把 Codex 会话监督整合为一个**自动化工作流**，替代原先需要手动/分离运行的
`codex_watch.sh` + `limit_watch.sh` + `notify.sh` 三个单点工具。

**独立、自包含项目**：通知层（`notify.sh`）已内置，不依赖上级目录或外部应用；
调度仅用 **Termux**（`termux-job-scheduler` + `Termux:Boot`），
不依赖任何外部调度系统。

## 它解决什么

| 问题 | 原方案 | 本方案 |
|------|--------|--------|
| 推进任务 (空闲时自动 continue) | codex_watch.sh 需外部周期驱动 | 常驻 daemon 每 5 分钟自动检查 |
| 低限额暂停 + 通知 | codex_watch.sh (去重在 /tmp) | 状态机 + 持久化去重 |
| 限额恢复检测 | limit_watch.sh 需手动跑 | 同一守护自动检测并恢复 |
| 恢复通知 + 恢复推进 | 依赖外部重建 | 同一轮自动恢复推进 |
| 开机恢复 | 无 | profile.d 启动恢复 (自动重启) |

## 状态机

```
ACTIVE ──(限额将尽)──▶ LOW_LIMIT ──(限额恢复)──▶ RESTORED ──▶ ACTIVE
  │                                                     │
  └──────── 空闲且限额足时自动发 continue ◀──────────────┘
```

- **LOW_LIMIT**：`weekly <= 5%` 或 `5h < 20%` 时暂停推进并通知（同一限额组合只通知一次）。
- **RESTORED**：暂停后限额恢复，通知并**在同一轮自动恢复推进**（无需外部重建）。
- 状态、去重键、PID 持久化在 `~/.local/state/codex-supervisor.*`。

## 用法

```bash
# 单次检查 (适合手动调试 / 外部 cron)
./codex-supervisor.sh --once

# 常驻守护 (默认)
./codex-supervisor.sh --daemon --interval 300

# 只打印决策, 不实际发送指令/通知 (调试用)
./codex-supervisor.sh --once --dry-run
```

参数：`--host` `--win` `--interval` `--weekly-max` `--h5-min` `--notify`。

## 安装 (Termux 调度 + 应用启动恢复)

```bash
./setup.sh            # 默认 300s 间隔
./setup.sh 600        # 指定 600s 间隔
```

- 通过 **`termux-job-scheduler --job-id 2`** 注册守护启动（Termux 定时任务）。
- **应用启动恢复**：安装 `~/.termux/boot/codex-supervisor.sh`，由
  **`$PREFIX/etc/profile.d/90-run-boot.sh`**（Termux 内置基础设施）在应用每次启动时
  自动运行——检查 pidfile 存活、幂等。**无需 Termux:Boot 应用**。

## 测试

```bash
./test.sh    # 用 fake ssh 端到端驱动状态机, 不碰真实远端
```

## 日志与状态

| 文件 | 用途 |
|------|------|
| `~/.local/state/codex-supervisor.log` | 运行日志 (时间戳) |
| `~/.local/state/codex-supervisor.state` | 状态机 + 通知去重键 |
| `~/.local/state/codex-supervisor.pid` | 守护 PID (boot hook 探测存活) |

## 依赖

- 远端 `workspace` 主机可 SSH，且有 tmux 会话 `local:0`（Codex 界面）。
- 通知走内置 `notify.sh`（飞书 webhook + 加签），可用 `--notify` 覆盖。
- **飞书凭据不内置于源码**：来自环境变量 `FEISHU_WEBHOOK_URL` / `FEISHU_SECRET`，
  或配置文件 `~/.config/feishu-notify.conf`（`chmod 600`，未入库）。
- 无需 python；依赖 `ssh` `curl` `openssl` `termux-job-scheduler`。
