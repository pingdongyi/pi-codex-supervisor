#!/data/data/com.termux/files/usr/bin/bash
# setup.sh — 一键安装 codex-supervisor: Termux 定时任务守护 + 应用启动恢复。
#
# 应用启动恢复机制:
#   依赖 $PREFIX/etc/profile.d/90-run-boot.sh (Termux 基础设施, 本环境已内置)。
#   它在 Termux 应用每次启动时(幂等, 带 marker) 遍历并后台运行 ~/.termux/boot/*.sh。
#   我们把恢复脚本放在 ~/.termux/boot/codex-supervisor.sh, 由 90-run-boot.sh 自动拉起。
#   无需 Termux:Boot 应用。
#
# 用法: ./setup.sh [--interval 300]
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$DIR/codex-supervisor.sh"
START="$DIR/start.sh"
INTERVAL="${1:-300}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BOOT_RUNNER="$PREFIX/etc/profile.d/90-run-boot.sh"

[[ -x "$SUPERVISOR" ]] || chmod +x "$SUPERVISOR"

# --- 启动包装脚本 (参数集中一处; termux-job-scheduler 只能调脚本不能传参) ---
cat > "$START" <<START
#!/data/data/com.termux/files/usr/bin/bash
exec "$SUPERVISOR" --daemon --interval "$INTERVAL"
START
chmod +x "$START"

# --- 注册 Termux 定时任务守护 (已有同名 job 先取消) ---
termux-job-scheduler --job-id 2 --cancel >/dev/null 2>&1 || true
termux-job-scheduler --job-id 2 --period-ms 0 --persisted true \
  --network none --battery-not-low false --script "$START" >/dev/null 2>&1 \
  && echo "[ok] 已注册 Termux 定时任务 job #2 -> $START" \
  || echo "[warn] termux-job-scheduler 注册失败"

# --- 应用启动恢复脚本 (由 $BOOT_RUNNER 在 Termux 应用启动时运行) ---
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/codex-supervisor.sh" <<BOOT
#!/data/data/com.termux/files/usr/bin/bash
# Auto-restart codex-supervisor daemon. Invoked by $BOOT_RUNNER
# (profile.d hook) on every Termux app start. Idempotent via pidfile.
set -uo pipefail
PID_FILE="\${CODEX_SUPERVISOR_STATE_DIR:-\$HOME/.local/state}/codex-supervisor.pid"
if [ -f "\$PID_FILE" ]; then
  OLD="\$(cat "\$PID_FILE" 2>/dev/null || true)"
  if [ -n "\$OLD" ] && kill -0 "\$OLD" 2>/dev/null; then
    exit 0 # 守护已在运行
  fi
fi
termux-job-scheduler --job-id 2 --period-ms 0 --persisted true \
  --network none --battery-not-low false --script "$START" >/dev/null 2>&1 || true
BOOT
chmod +x "$BOOT_DIR/codex-supervisor.sh"
echo "[ok] 已安装应用启动恢复: $BOOT_DIR/codex-supervisor.sh"

if [ -f "$BOOT_RUNNER" ]; then
  echo "[ok] 恢复将由 $BOOT_RUNNER 在 Termux 应用启动时自动触发"
else
  echo "[warn] 未找到 $BOOT_RUNNER; 应用启动恢复不可用 (请确认 Termux 环境)"
fi

echo
echo "=== 当前状态 ==="
termux-job-scheduler --pending 2>&1 | head -10
