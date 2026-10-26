#!/system/bin/sh
# ============================================================
# 监控面板自启（端口 8765）
# 放置于 /data/adb/service.d/95-dashboard.sh (chmod 755)
#
# 与 99-chroot-services.sh 相互独立：
#   面板只读 /proc /sys，不依赖其他服务，单独拉起更稳。
# ============================================================
(
  until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do sleep 10; done
  sleep 40

  R=/data/local/droidvm/rootfs
  LOG=/data/local/tmp/chroot-services.log
  echo "=========== [$(date)] dashboard autostart ===========" >> "$LOG"

  # chroot 基础挂载（幂等兜底，99 号脚本也会做）
  for d in proc sys dev dev/pts; do
    mountpoint -q "$R/$d" 2>/dev/null || mount --bind "/$d" "$R/$d" 2>/dev/null
  done

  if ! netstat -tln 2>/dev/null | grep -q ":8765 "; then
    chroot "$R" /usr/bin/env -i \
      PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
      HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
      /bin/sh -c 'cd /opt/dashboard && setsid nohup python3 dvm-dashboard.py >> /opt/dashboard/dash.log 2>&1 < /dev/null &'
    echo "[$(date)] dashboard started" >> "$LOG"
  else
    echo "[$(date)] dashboard already running" >> "$LOG"
  fi
) &
