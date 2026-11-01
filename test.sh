#!/data/data/com.termux/files/usr/bin/bash
# test.sh — 用 fake ssh 端到端驱动 codex-supervisor 状态机 (不碰真实远端)。
# 用法: ./test.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR="$DIR/codex-supervisor.sh"
STATEDIR="$(mktemp -d)"
export CODEX_SUPERVISOR_STATE_DIR="$STATEDIR"
export CODEX_SUPERVISOR_NOTIFY="$DIR/notify.sh"

# ---- fake ssh: 按 FAKE_MODE 返回模拟 tmux 输出, 静默处理 send-keys ----
FAKEBIN="$(mktemp -d)"
cat > "$FAKEBIN/ssh" <<'FAKESSH'
#!/data/data/com.termux/files/usr/bin/bash
cmd="$*"
if [[ "$cmd" == *"capture-pane"* ]]; then
  case "${FAKE_MODE:-low}" in
    low)    cat <<'EOF'
  5h limit:            [██████████████████░░] 89% left
                       (resets 8:55 PM)
  Weekly limit:        [░░░░░░░░░░░░░░░░░░░░] 0% left
                       (resets 5:20 PM on 4 Nov)


› Ask Codex to do anything
EOF
      ;;
    busy)   cat <<'EOF'
  5h limit:            [██████████████████░░] 89% left
  Weekly limit:        [████████████████████░] 95% left
  Working (reason) · esc to interrupt


› Ask Codex to do anything
EOF
      ;;
    ok)     cat <<'EOF'
  5h limit:            [██████████████████░░] 89% left
  Weekly limit:        [████████████████████░] 95% left


› Ask Codex to do anything
EOF
      ;;
  esac
  exit 0
fi
exit 0
FAKESSH
chmod +x "$FAKEBIN/ssh"
export PATH="$FAKEBIN:$PATH"

pass=0; fail=0
check() { # $1 desc, $2 expected, $3 actual
  if [[ "$3" == *"$2"* ]]; then echo "  PASS: $1"; pass=$((pass+1)); else echo "  FAIL: $1 (want *$2*, got: $3)"; fail=$((fail+1)); fi
}

echo "== 场景1: 低限额 + 空闲 => LOW_LIMIT, 暂停, 通知 =="
export FAKE_MODE=low
r=$(bash "$SUPERVISOR" --once); check "判定 LOW_LIMIT" "LOW_LIMIT" "$r"
check "状态 paused=1" "paused=1" "$(cat "$STATEDIR/codex-supervisor.state")"
check "last_state=LOW_LIMIT" "LOW_LIMIT" "$(cat "$STATEDIR/codex-supervisor.state")"

echo "== 场景2: 再次低限额 => 去重 (不再通知) =="
FAKE_MODE=low bash "$SUPERVISOR" --once >/dev/null
check "日志含去重跳过" "通知去重跳过" "$(tail -3 "$STATEDIR/codex-supervisor.log")"

echo "== 场景3: 限额恢复 + 空闲 => RESTORED + 同一轮恢复推进 =="
export FAKE_MODE=ok
r=$(bash "$SUPERVISOR" --once)
check "恢复后立即推进 CONTINUE_SENT" "CONTINUE_SENT" "$r"
check "状态 paused=0" "paused=0" "$(cat "$STATEDIR/codex-supervisor.state")"
check "last_state=RESTORED" "last_state=RESTORED" "$(cat "$STATEDIR/codex-supervisor.state")"
check "日志含恢复通知" "已恢复" "$(tail -3 "$STATEDIR/codex-supervisor.log")"

echo "== 场景4: 限额充足 + 忙碌 => STILL_WORKING =="
export FAKE_MODE=busy
r=$(bash "$SUPERVISOR" --once); check "判定 STILL_WORKING" "STILL_WORKING" "$r"

echo
echo "结果: $pass 通过, $fail 失败"
rm -rf "$STATEDIR" "$FAKEBIN"
[[ $fail -eq 0 ]]
