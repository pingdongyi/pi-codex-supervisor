#!/data/data/com.termux/files/usr/bin/bash
# setup.sh — 将 codex-supervisor 注册为 termux-job-scheduler 定期任务 (非常驻守护)。
#
# 每次 job 触发运行 codex-supervisor.sh --once (单次检查), 检查后退出, 等下个周期。
# 应用启动恢复: 由 $PREFIX/etc/profile.d/90-run-boot.sh 运行 ~/.termux/boot/codex-supervisor.sh,
# 后者幂等地重新注册 job (不启动任何常驻进程)。
#
# 用法: ./setup.sh [--interval 3600]   (间隔秒, 最小 900s = 15min)
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$DIR/codex-supervisor.sh"
START="$DIR/start.sh"
INTERVAL="${1:-3600}"
MIN_MS=900000          # termux-job-scheduler 最小周期 15min (Android N 起)
JOB_ID=2
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BOOT_RUNNER="$PREFIX/etc/profile.d/90-run-boot.sh"

[[ -x "$SUPERVISOR" ]] || chmod +x "$SUPERVISOR"

PERIOD_MS=$((INTERVAL * 1000))
if [ "$PERIOD_MS" -lt "$MIN_MS" ]; then
  echo "[warn] interval ${INTERVAL}s 小于最小周期 15min; 使用 900000ms"
  PERIOD_MS=$MIN_MS
fi

# start.sh: 单次检查 (由 termux-job-scheduler 定期触发, 检查后退出)
cat > "$START" <<START
#!/data/data/com.termux/files/usr/bin/bash
exec "$SUPERVISOR" --once
START
chmod +x "$START"

# 注册周期性 job (幂等覆盖同 job-id)
termux-job-scheduler --job-id "$JOB_ID" --cancel >/dev/null 2>&1 || true
termux-job-scheduler --job-id "$JOB_ID" --period-ms "$PERIOD_MS" --persisted true \
  --network any --battery-not-low false --script "$START" >/dev/null 2>&1 \
  && echo "[ok] 已注册定期任务 job #$JOB_ID (每 $((PERIOD_MS/1000))s 跑一次 --once)" \
  || echo "[warn] termux-job-scheduler 注册失败"

# 应用启动恢复: 确保 job #2 已注册 (幂等, 无常驻进程)
BOOT_DIR="$HOME/.termux/boot"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/codex-supervisor.sh" <<BOOT
#!/data/data/com.termux/files/usr/bin/bash
# Ensure codex-supervisor periodic job is registered. Invoked by $BOOT_RUNNER.
set -uo pipefail
termux-job-scheduler --job-id $JOB_ID --period-ms $PERIOD_MS --persisted true \
  --network any --battery-not-low false --script "$START" >/dev/null 2>&1 || true
BOOT
chmod +x "$BOOT_DIR/codex-supervisor.sh"
echo "[ok] 已安装应用启动恢复 (重新注册 job #$JOB_ID): $BOOT_DIR/codex-supervisor.sh"

[ -f "$BOOT_RUNNER" ] && echo "[ok] 恢复将由 $BOOT_RUNNER 在应用启动时触发" || echo "[warn] 未找到 $BOOT_RUNNER"

echo
echo "=== 当前状态 ==="
termux-job-scheduler --pending 2>&1 | head -10
