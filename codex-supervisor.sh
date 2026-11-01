#!/data/data/com.termux/files/usr/bin/bash
# codex-supervisor.sh — 将 Codex 会话监督整合为一个自动化工作流。
#
# 整合原先三个单点工具:
#   codex_watch.sh  (忙碌检测 + 空闲时发 continue 推进 + 低限额暂停)
#   limit_watch.sh  (限额恢复检测 + 恢复通知)
#   notify.sh       (飞书通知, 去重)
#
# 状态机 (每轮循环):
#   ACTIVE   正常推进任务 (空闲且限额充足时自动发 continue)
#   LOW_LIMIT 限额将尽, 暂停推进, 通知 (去重)
#   RESTORED 限额已恢复, 通知 (去重), 恢复推进
#
# 用法:
#   codex-supervisor.sh --once                单次检查 (适合外部 cron/调度)
#   codex-supervisor.sh --daemon [--interval 300]  常驻守护循环 (默认模式)
#   codex-supervisor.sh --dry-run             只打印决策, 不发送任何指令/通知
#
# 可选参数:
#   --host HOST       ssh 主机别名 (默认 workspace)
#   --win WIN         目标 tmux 窗口 (默认 local:0)
#   --interval SEC    守护循环间隔 (默认 300)
#   --weekly-max N    weekly<=N 触发告警 (默认 5)
#   --h5-min M        h5<M    触发告警 (默认 20)
#   --notify PATH     通知脚本路径 (自动探测 notify.sh)
#
# 依赖: ssh, tmux (远端), curl, openssl (经 notify.sh)。均已在环境验证。

set -uo pipefail

# ---------------------------------------------------------------------------
# 默认配置 (可通过环境变量/参数覆盖)
# ---------------------------------------------------------------------------
HOST="${CODEX_SUPERVISOR_HOST:-workspace}"
WIN="${CODEX_SUPERVISOR_WIN:-local:0}"
INTERVAL="${CODEX_SUPERVISOR_INTERVAL:-300}"
WEEKLY_MAX="${CODEX_SUPERVISOR_WEEKLY_MAX:-5}"
H5_MIN="${CODEX_SUPERVISOR_H5_MIN:-20}"
SCROLL="${CODEX_SUPERVISOR_SCROLL:--200}"
RETRY=3
DAEMON=0
DRYRUN=0

STATE_DIR="${CODEX_SUPERVISOR_STATE_DIR:-$HOME/.local/state}"
STATE_FILE="$STATE_DIR/codex-supervisor.state"
LOG_FILE="$STATE_DIR/codex-supervisor.log"
PID_FILE="$STATE_DIR/codex-supervisor.pid"
mkdir -p "$STATE_DIR"

# 自动探测 notify.sh (先参数, 再环境, 再常见相对路径)
NOTIFY_SCRIPT=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once) DAEMON=0; shift ;;
    --daemon) DAEMON=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --host) HOST="$2"; shift 2 ;;
    --win) WIN="$2"; shift 2 ;;
    --interval) INTERVAL="$2"; shift 2 ;;
    --weekly-max) WEEKLY_MAX="$2"; shift 2 ;;
    --h5-min) H5_MIN="$2"; shift 2 ;;
    --notify) NOTIFY_SCRIPT="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[[ -z "$NOTIFY_SCRIPT" ]] && NOTIFY_SCRIPT="${CODEX_SUPERVISOR_NOTIFY:-}"
[[ -z "$NOTIFY_SCRIPT" ]] && [[ -x "$SCRIPT_DIR/notify.sh" ]] && NOTIFY_SCRIPT="$SCRIPT_DIR/notify.sh"
[[ -z "$NOTIFY_SCRIPT" ]] && [[ -x "$SCRIPT_DIR/../notify.sh" ]] && NOTIFY_SCRIPT="$SCRIPT_DIR/../notify.sh"
[[ -z "$NOTIFY_SCRIPT" ]] && [[ -x /workspace/notify.sh ]] && NOTIFY_SCRIPT=/workspace/notify.sh

# ---------------------------------------------------------------------------
# 工具函数
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }

# 取远端输出: 有输出才算成功 (capture-pane 需要重试)
ssh_cap() {
  local i out
  i=1
  while [[ $i -le $RETRY ]]; do
    if out=$(timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$1" 2>/dev/null); then
      if [[ -n "$out" ]]; then printf '%s\n' "$out"; return 0; fi
    fi
    i=$((i+1)); [[ $i -le $RETRY ]] && sleep 2
  done
  return 1
}

# 只执行, 看退出码 (send-keys 无输出, 不能靠输出重试)
ssh_run() {
  timeout 30 ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "$1" >/dev/null 2>&1
}

# 读/写状态文件 (key=value, 简单持久化)
state_get() { grep "^$1=" "$STATE_FILE" 2>/dev/null | head -1 | cut -d= -f2-; }
state_set() {
  local key="$1" val="$2"
  [[ $DRYRUN -eq 1 ]] && return 0   # dry-run 完全只读
  if grep -q "^$key=" "$STATE_FILE" 2>/dev/null; then
    sed -i "s|^$key=.*|$key=$val|" "$STATE_FILE"
  else
    printf '%s=%s\n' "$key" "$val" >> "$STATE_FILE"
  fi
}

# 通知 (去重: 同一去重键只发一次, 除非 --dry-run)
notify_once() {
  local dedup_key="$1" title="$2" msg="$3" last
  last="$(state_get last_notify)"
  if [[ "$last" == "$dedup_key" ]]; then
    log "通知去重跳过: $dedup_key"
    return 0
  fi
  log "通知: $title | $msg"
  if [[ $DRYRUN -eq 0 ]] && [[ -n "$NOTIFY_SCRIPT" ]] && [[ -x "$NOTIFY_SCRIPT" ]]; then
    "$NOTIFY_SCRIPT" "$title" "$msg" >/dev/null 2>&1 || log "通知发送失败: $dedup_key"
  fi
  state_set last_notify "$dedup_key"
}

# ---------------------------------------------------------------------------
# 单轮检查: 抓状态 → 状态机 → 动作
# ---------------------------------------------------------------------------
run_cycle() {
  local out weekly h5 working low_flag paused state
  local line content placeholder='Ask Codex to do anything'

  out="$(ssh_cap "tmux capture-pane -t '$WIN' -p -S $SCROLL")" || {
    log "SSH_ERROR: 无法连接 $HOST/$WIN (重试${RETRY}次失败)"
    echo "SSH_ERROR"; return 0
  }

  # 1) 提取限额。实际界面: "Weekly limit: [░░░] 0% left" (百分比在进度条后,
  #    大小写敏感); 兼容旧格式 "weekly limit: only 5%". 取该行第一个百分比。
  weekly="$(printf '%s\n' "$out" | grep -iE 'weekly limit' | grep -oE '[0-9]+%' | head -1 | tr -d '%')"
  h5="$(printf '%s\n' "$out" | grep -iE '5h limit' | grep -oE '[0-9]+%' | head -1 | tr -d '%')"

  # 2) 忙碌检测
  working=0
  printf '%s\n' "$out" | grep -qE 'Working \(|Waiting for background|esc to interrupt' && working=1

  # 3) 限额判定
  # 限额完全无法提取 (Codex 界面不在/解析失败): 不误判恢复, 不推进
  if [ -z "$weekly" ] && [ -z "$h5" ]; then
    state_set last_state UNKNOWN
    echo "LIMIT_UNKNOWN: 无法提取限额 (weekly/h5 为空, Codex 会话可能不可用)"
    return 0
  fi
  low_flag=0
  [[ -n "$weekly" ]] && [[ "$weekly" -le "$WEEKLY_MAX" ]] && low_flag=1
  [[ -n "$h5" ]] && [[ "$h5" -lt "$H5_MIN" ]] && low_flag=1
  paused="$(state_get paused)"; [[ -z "$paused" ]] && paused=0

  # -------------------------------------------------------------------
  # 低限额分支
  # -------------------------------------------------------------------
  if [[ $low_flag -eq 1 ]]; then
    state_set paused 1
    local dk="low:weekly=${weekly:-?}h5=${h5:-?}"
    notify_once "$dk" "⚠️ Codex 限额将尽" "周限额 ${weekly:-?}% / 5h ${h5:-?}%。任务已暂停推进。"
    state_set last_state LOW_LIMIT
    if [[ $working -eq 1 ]]; then
      echo "LOW_LIMIT_STILL_WORKING (weekly=${weekly:-?}% 5h=${h5:-?}%)"
    else
      echo "LOW_LIMIT (weekly=${weekly:-?}% 5h=${h5:-?}%)"
    fi
    return 0
  fi

  # -------------------------------------------------------------------
  # 限额充足分支
  # -------------------------------------------------------------------
  if [[ "$paused" == "1" ]]; then
    local rdk="restored:weekly=${weekly:-?}h5=${h5:-?}"
    notify_once "$rdk" "✅ Codex 限额已恢复" "周限额 ${weekly:-?}% / 5h ${h5:-?}%，已恢复自动推进。"
    state_set paused 0
    state_set last_state RESTORED
  else
    state_set last_state ACTIVE
  fi

  # 忙碌时不推进
  if [[ $working -eq 1 ]]; then
    echo "STILL_WORKING (weekly=${weekly:-?}% 5h=${h5:-?}%)"
    return 0
  fi

  # 4) 只看输入区 (画面最后 8 行)
  local bottom line content
  bottom="$(printf '%s\n' "$out" | tail -8)"
  line="$(printf '%s\n' "$bottom" | grep -E '^ *›' | tail -1)"
  if [[ -z "$line" ]]; then
    echo "UNKNOWN_STATE: 未找到输入框"
    return 0
  fi
  content="$(printf '%s\n' "$line" | sed 's/^ *› *//; s/ *$//')"

  # 输入框已有未提交的 continue -> 只发回车
  if [[ "$content" == "continue" ]]; then
    [[ $DRYRUN -eq 0 ]] && ssh_run "tmux send-keys -t '$WIN' C-m"
    echo "SUBMIT_EXISTING_CONTINUE"
    return 0
  fi

  # 输入框为空/占位符 -> 发 continue 再单独回车
  if [[ "$content" == "$placeholder" ]] || [[ -z "$content" ]]; then
    if [[ $DRYRUN -eq 0 ]]; then
      ssh_run "tmux send-keys -t '$WIN' 'continue'"
      sleep 1
      ssh_run "tmux send-keys -t '$WIN' C-m"
    fi
    echo "CONTINUE_SENT"
    return 0
  fi

  echo "UNKNOWN_STATE: 输入框有未识别内容 [${content}]"
}

# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------
# 守护模式下记录 PID, 供 boot hook 用 kill -0 检测存活
if [[ $DAEMON -eq 1 ]]; then
  echo "$$" > "$PID_FILE"
  log "daemon 启动 (host=$HOST win=$WIN interval=${INTERVAL}s)"
fi

if [[ $DAEMON -eq 0 ]]; then
  run_cycle
else
  while true; do
    run_cycle
    sleep "$INTERVAL"
  done
fi
