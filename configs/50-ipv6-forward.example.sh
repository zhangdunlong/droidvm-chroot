#!/system/bin/sh
# ============================================================
# IPv6 直连 + Caddy HTTPS 入口自启
# 放置于 /data/adb/service.d/50-ipv6-forward.sh (chmod 755)
#
# 背景（Android 的两处 IPv6 限制）：
#   1) accept_ra 默认 0 → 收不到运营商的路由通告，拿不到公网 IPv6
#   2) 策略路由存在 "100: from all unreachable" → 所有 IPv6 被判不可达
#
# 端口实测（不同运营商差异很大，务必自己复测）：
#   80 / 443 / 8080 入站通常可用
#   注意：出站 443 可能被拦，那只影响 Caddy 申请证书，
#         与「入站 443 是否可用」是两件事，切勿混为一谈
#
# 用法：把下面的 <...> 占位符替换成实际值
# ============================================================

LOG=/data/local/tmp/ipv6-boot.log
exec >> "$LOG" 2>&1
echo "[$(date)] ipv6 boot script start"

# ---- 1) 等网络就绪（最多 5 分钟）----
i=0
while [ $i -lt 60 ]; do
  if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then
    echo "[$(date)] network ready after $((i*5))s"
    break
  fi
  sleep 5
  i=$((i+1))
done

# ---- 2) 开启接受路由通告 ----
echo 1 > /proc/sys/net/ipv6/conf/wlan0/accept_ra 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/default/accept_ra 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/wlan0/autoconf 2>/dev/null

# ---- 3) 重启 WiFi 触发一次 RA（地址才会下发）----
svc wifi disable 2>/dev/null
sleep 3
svc wifi enable 2>/dev/null

i=0
while [ $i -lt 30 ]; do
  if ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1; then break; fi
  sleep 4
  i=$((i+1))
done
echo "[$(date)] wifi reconnected"

# ---- 4) 补策略路由，绕过 Android 的 unreachable 规则 ----
if ! ip -6 rule 2>/dev/null | grep -qE "^50:[[:space:]]"; then
  ip -6 rule add priority 50 lookup wlan0 2>/dev/null
  echo "[$(date)] ipv6 rule added"
fi

# ---- 5) 等公网 IPv6 地址 ----
i=0
V6=""
while [ $i -lt 24 ]; do
  V6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" \
        | grep -oE "inet6 [0-9a-f:]+" | awk '{print $2}' | grep -v "^fe80" | head -1)
  [ -n "$V6" ] && break
  sleep 5
  i=$((i+1))
done
echo "[$(date)] ipv6 = ${V6:-未获取}"

# ---- 6) 启动 Caddy ----
R=/data/local/droidvm/rootfs
ENVF=/data/adb/caddy.env      # 内含 CF_API_TOKEN / HTTPS_PROXY，权限 600
pkill -f "caddy run" 2>/dev/null
sleep 1
CF_API_TOKEN=""; HTTPS_PROXY=""; HTTP_PROXY=""; NO_PROXY=""
[ -f "$ENVF" ] && . "$ENVF"
chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
  XDG_DATA_HOME=/var/lib/caddy XDG_CONFIG_HOME=/etc/caddy \
  CF_API_TOKEN="$CF_API_TOKEN" \
  HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="$HTTP_PROXY" NO_PROXY="$NO_PROXY" \
  /bin/sh -c 'setsid nohup /usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >> /var/log/caddy/caddy.out 2>&1 < /dev/null &'
echo "[$(date)] caddy started"

sleep 5
netstat -tln 2>/dev/null | grep ":443 " | head -1

# ---- 7) 启动常驻守护（每 60 秒自愈 rule / Caddy，并写 IPv6 地址文件）----
GUARD=/data/adb/ipv6-guard.sh
if [ -f "$GUARD" ]; then
  pgrep -f "ipv6-guard.sh" >/dev/null 2>&1 || {
    setsid nohup "$GUARD" >/dev/null 2>&1 &
    echo "[$(date)] ipv6-guard started"
  }
fi

echo "[$(date)] done"
