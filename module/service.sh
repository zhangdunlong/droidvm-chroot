#!/system/bin/sh
# ============================================================
# DroidVM Chroot 开机自启（Magisk late_start service 阶段）
#
# 整个逻辑放进 ( ... ) & 后台子 shell —— MAGISK 的 service.sh 是
# 同步执行的，在这里 sleep 或等网络会阻塞同阶段其它模块。
# 本脚本自身应在毫秒级返回。
# ============================================================
(
  MODDIR=/data/adb/modules/DroidVM-Chroot
  LOG=/data/local/tmp/droidvm-boot.log

  # 等开机动画结束（比固定 sleep 可靠）
  i=0
  until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do
    sleep 10
    i=$((i+1))
    [ $i -gt 90 ] && break      # 兜底：最多 15 分钟
  done
  sleep 30

  # 已被手动启动过就跳过（避免和 mgmt.sh start 打架）
  if [ -f /data/local/droidvm/.boot-ok ]; then
    if [ $(( $(date +%s) - $(cat /data/local/droidvm/.boot-ok 2>/dev/null || echo 0) )) -lt 120 ]; then
      echo "[$(date)] 最近 120 秒内已启动过，跳过" >> "$LOG"
      exit 0
    fi
  fi

  sh "$MODDIR/scripts/boot.sh"
) &
