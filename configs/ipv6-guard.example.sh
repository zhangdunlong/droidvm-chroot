#!/system/bin/sh
# ============================================================
# IPv6 守护进程（Android 层，每 60 秒自愈）
# 放置于 /data/adb/ipv6-guard.sh (chmod 755)
#
# 职责：
#   1) 保持 accept_ra=1（否则重启后拿不到公网 IPv6）
#   2) 保持 IPv6 策略路由 priority 50 → wlan0
#   3) 保持 Caddy 运行（443 HTTPS 入口 + 证书自动续期）
#   4) 检测 IPv6 地址变化，写入文件供 DDNS 定时任务读取
#
# 日志：/data/local/tmp/ipv6-guard.log
# 输出：/data/local/droidvm/rootfs/tmp/ipv6-current.txt（chroot 内即 /tmp/）
# ============================================================

LOG=/data/local/tmp/ipv6-guard.log
OUT=/data/local/droidvm/rootfs/tmp/ipv6-current.txt
R=/data/local/droidvm/rootfs
ENVF=/data/adb/caddy.env
LAST=""

echo "[$(date)] guard started" >> "$LOG"

while true; do
  # ---- 1) accept_ra ----
  RA=$(cat /proc/sys/net/ipv6/conf/wlan0/accept_ra 2>/dev/null)
  if [ "$RA" != "1" ]; then
    echo 1 > /proc/sys/net/ipv6/conf/wlan0/accept_ra 2>/dev/null
    echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra 2>/dev/null
    echo "[$(date)] accept_ra fixed" >> "$LOG"
  fi

  # ---- 2) 策略路由 ----
  if ! ip -6 rule 2>/dev/null | grep -qE "^50:[[:space:]]"; then
    ip -6 rule add priority 50 lookup wlan0 2>/dev/null
    echo "[$(date)] ip6 rule re-added" >> "$LOG"
  fi

  # ---- 3) Caddy 保活 ----
  if ! pgrep -f "caddy run" >/dev/null 2>&1; then
    CF_API_TOKEN=""; HTTPS_PROXY=""; HTTP_PROXY=""; NO_PROXY=""
    [ -f "$ENVF" ] && . "$ENVF"
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
      XDG_DATA_HOME=/var/lib/caddy XDG_CONFIG_HOME=/etc/caddy \
      CF_API_TOKEN="$CF_API_TOKEN" \
      HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="$HTTP_PROXY" NO_PROXY="$NO_PROXY" \
      /bin/sh -c 'setsid nohup /usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >> /var/log/caddy/caddy.out 2>&1 < /dev/null &'
    echo "[$(date)] caddy restarted" >> "$LOG"
  fi

  # ---- 4) 检测 IPv6 地址变化 ----
  # 优先取 stable-privacy 地址（隐私扩展，重启后一般稳定），否则取任意全局地址
  V6=$(ip -6 addr show wlan0 2>/dev/null | grep "stable-privacy" \
        | grep -oE "inet6 [0-9a-f:]+" | awk '{print $2}' | head -1)
  if [ -z "$V6" ]; then
    V6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" \
          | grep -oE "inet6 [0-9a-f:]+" | awk '{print $2}' | grep -v "^fe80" | head -1)
  fi

  if [ -n "$V6" ] && [ "$V6" != "$LAST" ]; then
    echo "$V6" > "$OUT" 2>/dev/null
    date +%s > "${OUT%.txt}.ts" 2>/dev/null
    LAST="$V6"
    echo "[$(date)] ipv6 = $V6" >> "$LOG"
  fi

  sleep 60
done
