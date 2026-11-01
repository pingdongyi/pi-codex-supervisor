---
name: codex-supervisor
description: Install and manage the Codex session supervisor daemon (Codex 监督守护). Use when the user asks to install, start, stop, check the status of, or change the poll interval of the Codex auto-continue watchdog — 安装/启动/停止/查看 Codex 监督守护, 自动 continue, 限额监控, 或调整检查间隔.
compatibility: Requires SSH access to the `workspace` host (tmux session `local:0`), termux-job-scheduler, and openssl+curl (for the feishu notification layer).
---

# Codex Supervisor (Codex 监督守护)

A state-machine watchdog that supervises a Codex session over SSH. It
**auto-continues idle tasks** (sends `continue`), **pauses on low rate limits**
(`weekly <= 5%` or `5h < 20%`), **notifies on limit change/restore**, and
**recovers automatically** on limit reset — no manual `limit_watch.sh` needed.

Scripts live in the **package root** (run them from the package directory).

## When to use

Use this skill when the user asks to:
- install / start / stop / check the Codex supervisor
- 安装 / 启动 / 停止 / 查看 Codex 监督守护
- change the supervisor poll interval (调整检查间隔)
- know the current Codex rate-limit / limit state (限额状态)

## Prerequisites

- SSH access to the `workspace` host with a tmux session `local:0` (Codex UI).
- `termux-job-scheduler` for scheduling; app-start recovery via
  `~/.termux/boot/codex-supervisor.sh` (driven by `/usr/etc/profile.d/90-run-boot.sh`).
- Feishu notify credentials: `~/.config/feishu-notify.conf` (`chmod 600`) or env
  vars `FEISHU_WEBHOOK_URL` / `FEISHU_SECRET`.

## Install

Run the installer — it registers Termux job #2 and installs app-start recovery:

```bash
./setup.sh [interval_seconds]     # default 300s
```

## Commands

| Command | Purpose |
|---------|---------|
| `./codex-supervisor.sh --once` | Single check (add `--dry-run` to not send commands/notifications) |
| `./codex-supervisor.sh --daemon --interval 3600` | Run the daemon loop (1h) |
| `./setup.sh 3600` | Install/register daemon + app-start recovery |
| `./test.sh` | End-to-end state-machine tests (fake ssh, no real remote) |

## State machine

```
ACTIVE ──(限额将尽)──▶ LOW_LIMIT ──(限额恢复)──▶ RESTORED ──▶ ACTIVE
  │                                                     │
  └──────── 空闲且限额足时自动发 continue ◀──────────────┘
```

State/logs/PID in `~/.local/state/codex-supervisor.{state,log,pid}`. The daemon
auto-continues idle tasks and pauses/notifies on low limits.
