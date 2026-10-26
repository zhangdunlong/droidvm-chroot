#!/system/bin/sh
# ============================================================
# 业务服务自启（chroot 原生，无 QEMU / 无 Docker）
# 放置于 /data/adb/service.d/99-chroot-services.sh (chmod 755)
# 由 Magisk late_start service 阶段执行
#
# 服务跑在 /data/local/droidvm/rootfs（Ubuntu 22.04 arm64）chroot 内，
# 直接使用 Android 网络栈，因此：
#   · 没有 QEMU 指令翻译开销
#   · 不需要 hostfwd 端口转发，服务监听端口 = 手机监听端口
# ============================================================
(
  # 等启动动画结束再动手，太早 mount --bind 会失败
  until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do sleep 10; done
  sleep 30

  R=/data/local/droidvm/rootfs
  LOG=/data/local/tmp/chroot-services.log
  echo "=========== [$(date)] chroot services autostart ===========" >> $LOG

  # 挂载 chroot 必需的文件系统（幂等）
  for d in proc sys dev dev/pts; do
    mountpoint -q "$R/$d" 2>/dev/null || mount --bind "/$d" "$R/$d" 2>/dev/null \
      || echo "warn: bind $d failed" >> $LOG
  done

  # ---- 1. AI API 网关 (3065) ----
  if ! netstat -tln 2>/dev/null | grep -q ":3065 "; then
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
      AGENT2API_ADMIN_USER=admin \
      AGENT2API_ADMIN_PASSWORD='<A2A_ADMIN_PASSWORD>' \
      AGENT2API_HOST=0.0.0.0 \
      AGENT2API_UI_DIR=/app/ui \
      AGENT2API_CAPTCHA_ENABLED=0 \
      /bin/sh -c 'cd /app && setsid nohup ./agent2api-server >> /app/a2a.log 2>&1 < /dev/null &'
    echo "[$(date)] agent2api started" >> $LOG
  fi

  # ---- 2. 青龙面板 (5700) ----
  if ! netstat -tln 2>/dev/null | grep -q ":5700 "; then
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
      QL_DIR=/ql QL_DATA_DIR=/ql/data QL_BRANCH=master QL_PORT=5700 QL_CONTAINER=true \
      ENABLE_WEB_PANEL=true ENABLE_HANGUP=true \
      /bin/sh -c 'cd /ql && setsid nohup /usr/local/bin/node /ql/static/build/app.js >> /ql/data/log/boot.log 2>&1 < /dev/null &'
    echo "[$(date)] qinglong started" >> $LOG
  fi

  # ---- 3. 智能音箱桥 (36592) ----
  # 凭据从文件读取，不要硬编码在这个脚本里
  if ! netstat -tln 2>/dev/null | grep -q ":36592 "; then
    S="$R/opt/mi-paiai/data/secrets"
    U=$(cat "$S/auth_username" 2>/dev/null | tr -d '\n')
    P=$(cat "$S/auth_password" 2>/dev/null | tr -d '\n')
    K=$(cat "$S/auth_secret"   2>/dev/null | tr -d '\n')
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/bin:/usr/bin:/bin HOME=/root NODE_ENV=production \
      MIPAIAI_CONFIG_DIR=/opt/mi-paiai/data/config PORT=36592 \
      AUTH_USERNAME="$U" AUTH_PASSWORD="$P" AUTH_SECRET="$K" \
      /bin/sh -c 'cd /opt/mi-paiai && setsid nohup /usr/local/bin/node apps/web/dist/index.js >> /opt/mi-paiai/mp.log 2>&1 < /dev/null &'
    echo "[$(date)] mi-paiai started" >> $LOG
  fi

  # ---- 4. Cloudflare Tunnel ----
  # 固定边缘 IP，绕过手机上代理软件的 fake-ip DNS
  if ! pgrep -f "cloudflared --config" >/dev/null 2>&1; then
    chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
      /bin/sh -c 'setsid nohup /etc/cloudflared/run-tunnel.sh >> /tmp/cf.log 2>&1 < /dev/null &'
    echo "[$(date)] cloudflared started" >> $LOG
  fi

  echo "=========== [$(date)] done ===========" >> $LOG
) &
