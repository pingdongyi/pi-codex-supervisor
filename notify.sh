#!/usr/bin/env bash
# 纯 Bash 飞书通知脚本 (参考 feishu-notification MCP 的 send_notification)
#
# 用法: notify.sh "<title>" "<message>"
#   title   通知标题 (必填)
#   message 通知正文 (可选, 缺省用 title)
#
# 鉴权: 飞书自定义机器人 webhook + 加签 (HMAC-SHA256)
# 消息: interactive + 消息模板 (template_id)
#
# 凭据来源 (不内置于源码, 按优先级):
#   1. 环境变量  FEISHU_WEBHOOK_URL / FEISHU_SECRET / FEISHU_TEMPLATE_ID
#   2. 配置文件  ${FEISHU_CONFIG:-$HOME/.config/feishu-notify.conf}
#                内容为 shell 变量赋值, 如: FEISHU_WEBHOOK_URL=... / FEISHU_SECRET=...
#   3. 未提供凭据 -> 报错退出 (不发送)
#
# 依赖: openssl (签名), curl (发送)。均为 bash, 不依赖 python。

CONFIG="${FEISHU_CONFIG:-$HOME/.config/feishu-notify.conf}"
[ -r "$CONFIG" ] && . "$CONFIG"

WEBHOOK_URL="${FEISHU_WEBHOOK_URL:-}"
SECRET="${FEISHU_SECRET:-}"
TEMPLATE_ID="${FEISHU_TEMPLATE_ID:-AAqjrlHeq0oFv}"

if [ -z "$WEBHOOK_URL" ] || [ -z "$SECRET" ]; then
  echo "notify: 缺少飞书凭据 (FEISHU_WEBHOOK_URL / FEISHU_SECRET); 请设置环境变量或写入 $CONFIG" >&2
  exit 1
fi

title="${1:-通知}"
message="${2:-}"
[ -z "$message" ] && message="$title"

# JSON 字符串转义 (bash 参数展开, 输出到全局 JESC)
json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  JESC=$s
}

# 飞书加签: HMAC-SHA256(key=timestamp+"\n"+secret, msg=""), base64
ts=$(date +%s)
string_to_sign="${ts}"$'\n'"${SECRET}"
sign=$(printf '' | openssl dgst -sha256 -hmac "$string_to_sign" -binary | base64)

# 构造 card (template) 并整体转义为字符串字段
json_escape "$title";   title_esc=$JESC
json_escape "$message"; msg_esc=$JESC

card="{\"type\":\"template\",\"data\":{\"template_id\":\"$TEMPLATE_ID\",\"template_variable\":{\"TIME\":\"$(date +%H:%M)\",\"TITLE\":\"$title_esc\",\"MSG\":\"$msg_esc\"}}}"
json_escape "$card"; card_esc=$JESC

payload="{\"timestamp\":$ts,\"sign\":\"$sign\",\"msg_type\":\"interactive\",\"card\":\"$card_esc\"}"

# 发送
resp=$(curl -s -m 15 -X POST "$WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  -d "$payload")
echo "$resp"
