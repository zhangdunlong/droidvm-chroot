#!/system/bin/sh
# ============================================================
# DroidVM Chroot 启动总入口（由 service.sh 在启动动画结束后调用）
#
# 与 v1（QEMU/TCG）的区别：这里直接在 Android 内核上的 chroot 里
# 拉起进程，没有指令翻译层，也没有 Docker 与 hostfwd 端口转发。
#
# 顺序很重要：
#   1) 挂载 chroot 必需的文件系统
#   2) IPv6（协议栈 → accept_ra → 策略路由 → 等地址）
#   3) Caddy（443 HTTPS，依赖 IPv6 与 Cloudflare Token）
#   4) 业务服务（3065 / 5700 / 36592 / cloudflared）
#   5) 监控面板（8765）
#   6) IPv6 守护（常驻自愈）
# ============================================================

MODDIR=/data/adb/modules/DroidVM-Chroot
R=/data/local/droidvm/rootfs
LOG=/data/local/tmp/droidvm-boot.log
ENVF=/data/adb/droidvm.env        # 可选：CF_API_TOKEN / DASH_LINKS 等
MARK=/data/local/droidvm/.boot-ok

exec >> "$LOG" 2>&1
echo "=========== [$(date)] boot start ==========="

[ -d "$R/etc" ] || { echo "[!] rootfs 不存在：$R"; exit 1; }

# ---------- 1) 挂载 ----------
for d in proc sys dev dev/pts; do
  mountpoint -q "$R/$d" 2>/dev/null || mount --bind "/$d" "$R/$d" 2>/dev/null \
    || echo "[!] bind $d 失败"
done
echo "[+] mounts ready"

# ---------- 2) 等网络 ----------
i=0
while [ $i -lt 60 ]; do
  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && { echo "[+] network ready ($((i*5))s)"; break; }
  sleep 5; i=$((i+1))
done

# ---------- 3) IPv6 ----------
# 三个开关缺一不可：
#   disable_ipv6=0  否则连 fe80 都没有，accept_ra 设了也白设
#   accept_ra=1     否则收不到路由通告，拿不到公网前缀
#   ip -6 rule 50   否则被 Android 的 "100: from all unreachable" 拦掉
echo 0 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
echo 0 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null
echo 0 > /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/wlan0/accept_ra 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/default/accept_ra 2>/dev/null
echo 1 > /proc/sys/net/ipv6/conf/wlan0/autoconf 2>/dev/null

# 重启一次 WiFi 触发 RA（地址才会重新下发）
svc wifi disable 2>/dev/null
sleep 3
svc wifi enable 2>/dev/null
i=0
while [ $i -lt 30 ]; do
  ping -c 1 -W 2 223.5.5.5 >/dev/null 2>&1 && break
  sleep 4; i=$((i+1))
done
echo "[+] wifi reconnected"

# 注意：ip -6 rule 的输出是 "50:\tfrom all lookup wlan0"，不含 priority 字样
if ! ip -6 rule 2>/dev/null | grep -qE "^50:[[:space:]]"; then
  ip -6 rule add priority 50 lookup wlan0 2>/dev/null
  echo "[+] ipv6 rule added"
fi

i=0
V6=""
while [ $i -lt 24 ]; do
  V6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" \
        | grep -oE "inet6 [0-9a-f:]+" | awk '{print $2}' | grep -v "^fe80" | head -1)
  [ -n "$V6" ] && break
  sleep 5; i=$((i+1))
done
echo "[+] ipv6 = ${V6:-未获取}"

# ---------- 4) Caddy ----------
CF_API_TOKEN=""; HTTPS_PROXY=""; HTTP_PROXY=""; NO_PROXY=""
[ -f "$ENVF" ] && . "$ENVF"

pkill -f "[c]addy run" 2>/dev/null
sleep 1
if [ -x "$R/usr/local/bin/caddy" ]; then
  chroot "$R" /usr/bin/env -i \
    PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
    XDG_DATA_HOME=/var/lib/caddy XDG_CONFIG_HOME=/etc/caddy \
    CF_API_TOKEN="$CF_API_TOKEN" \
    HTTPS_PROXY="$HTTPS_PROXY" HTTP_PROXY="$HTTP_PROXY" NO_PROXY="$NO_PROXY" \
    /bin/sh -c 'setsid nohup /usr/local/bin/caddy run --config /etc/caddy/Caddyfile --adapter caddyfile >> /var/log/caddy/caddy.out 2>&1 < /dev/null &'
  echo "[+] caddy started"
fi

# ---------- 4.5) gost：IPv4 → IPv6 兼容转发 ----------
# 部分服务只监听 IPv4，旧域名（v6.example.com 走 :8080）需要它兜底
if [ -x "$R/usr/local/bin/gost" ] && ! netstat -tln 2>/dev/null | grep -q ":8080 "; then
  chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
    /bin/sh -c 'setsid nohup /usr/local/bin/gost -L=tcp://[::]:8080/127.0.0.1:3065 >> /tmp/gost.log 2>&1 < /dev/null &'
  echo "[+] gost 8080 启动"
fi

# ---------- 5) 业务服务 ----------
# 每项启动前先看端口，保证幂等（重复执行不会起第二份）
start_if_down() {
  port=$1; shift
  if netstat -tln 2>/dev/null | grep -q ":$port "; then
    echo "[=] $port 已在监听，跳过"
    return 0
  fi
  "$@"
  echo "[+] $port 启动"
}

# AI API 网关（凭据从 droidvm.env 读；缺失则跳过，避免用弱默认密码起服务）
if [ -z "$A2A_PASS" ]; then
  echo "[!] 未配置 A2A_PASS，跳过 agent2api（见 /data/adb/droidvm.env）"
elif ! netstat -tln 2>/dev/null | grep -q ":3065 "; then
  chroot "$R" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    AGENT2API_ADMIN_USER="${A2A_USER:-admin}" \
    AGENT2API_ADMIN_PASSWORD="$A2A_PASS" \
    AGENT2API_HOST=0.0.0.0 AGENT2API_UI_DIR=/app/ui AGENT2API_CAPTCHA_ENABLED=0 \
    /bin/sh -c 'cd /app && setsid nohup ./agent2api-server >> /app/a2a.log 2>&1 < /dev/null &'
  echo "[+] 3065 启动"
else
  echo "[=] 3065 已在监听，跳过"
fi

# 青龙面板
start_if_down 5700 chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
  QL_DIR=/ql QL_DATA_DIR=/ql/data QL_BRANCH=master QL_PORT=5700 QL_CONTAINER=true \
  ENABLE_WEB_PANEL=true ENABLE_HANGUP=true \
  /bin/sh -c 'cd /ql && setsid nohup /usr/local/bin/node /ql/static/build/app.js >> /ql/data/log/boot.log 2>&1 < /dev/null &'

# 智能音箱桥（凭据从文件读，不硬编码）
if ! netstat -tln 2>/dev/null | grep -q ":36592 "; then
  S="$R/opt/mi-paiai/data/secrets"
  if [ -d "$R/opt/mi-paiai" ]; then
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/bin:/usr/bin:/bin HOME=/root NODE_ENV=production \
      MIPAIAI_CONFIG_DIR=/opt/mi-paiai/data/config PORT=36592 \
      AUTH_USERNAME="$(cat "$S/auth_username" 2>/dev/null | tr -d '\n')" \
      AUTH_PASSWORD="$(cat "$S/auth_password" 2>/dev/null | tr -d '\n')" \
      AUTH_SECRET="$(cat "$S/auth_secret" 2>/dev/null | tr -d '\n')" \
      /bin/sh -c 'cd /opt/mi-paiai && setsid nohup /usr/local/bin/node apps/web/dist/index.js >> /opt/mi-paiai/mp.log 2>&1 < /dev/null &'
    echo "[+] 36592 启动"

    # node 进程起来只是 web 服务在监听，/api/status 仍是 stopped，
    # 必须显式 /api/start 才会连小米云并开始接收音箱消息。
    # 不调用的话：面板显示在线，但对着音箱说话毫无反应。
    if [ -f "$MODDIR/scripts/mp-autostart.py" ]; then
      cp "$MODDIR/scripts/mp-autostart.py" "$R/tmp/mp-autostart.py" 2>/dev/null
      sleep 6
      chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin \
        MP_USER="$(cat "$S/auth_username" 2>/dev/null)" \
        MP_PASS="$(cat "$S/auth_password" 2>/dev/null)" \
        python3 /tmp/mp-autostart.py 2>&1 | sed 's/^/    /'
    fi
  fi
fi

# Cloudflare Tunnel
if ! pgrep -f "cloudflared --config" >/dev/null 2>&1; then
  if [ -f "$R/etc/cloudflared/run-tunnel.sh" ]; then
    chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
      /bin/sh -c 'setsid nohup /etc/cloudflared/run-tunnel.sh >> /tmp/cf.log 2>&1 < /dev/null &'
    echo "[+] cloudflared 启动"
  fi
fi

# ---------- 6) 监控面板 ----------
if ! netstat -tln 2>/dev/null | grep -q ":8765 "; then
  if [ -f "$R/opt/dashboard/dvm-dashboard.py" ]; then
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
      DASH_DEVICE_NAME="${DASH_DEVICE_NAME:-Android Phone}" \
      DASH_LINKS="$DASH_LINKS" \
      /bin/sh -c 'cd /opt/dashboard && setsid nohup python3 dvm-dashboard.py >> /opt/dashboard/dash.log 2>&1 < /dev/null &'
    echo "[+] dashboard 启动"
  fi
fi

# ---------- 7) IPv6 守护 ----------
if [ -x /data/adb/ipv6-guard.sh ]; then
  pgrep -f "[i]pv6-guard\.sh" >/dev/null 2>&1 || {
    setsid nohup /data/adb/ipv6-guard.sh >/dev/null 2>&1 &
    echo "[+] guard 启动"
  }
fi

date +%s > "$MARK"
echo "=========== [$(date)] boot done ==========="
