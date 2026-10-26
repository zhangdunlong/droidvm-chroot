#!/system/bin/sh
# ============================================================
# DroidVM Chroot 卸载脚本
#
# 默认只停服务，保留 /data/local/droidvm（rootfs 与服务数据）。
# 如需连数据一起删：
#   su -c 'sh <module>/bin/mgmt.sh purge'   后卸载模块
# ============================================================

LOG=/data/local/tmp/droidvm-boot.log
echo "=========== [$(date)] uninstall ===========" >> "$LOG"

# 停服务（只杀本项目启动的进程，不碰系统组件）
pkill -f "[c]addy run" 2>/dev/null
pkill -f "[c]loudflared --config" 2>/dev/null
pkill -f "[d]vm-dashboard\.py" 2>/dev/null
pkill -f "[d]roidvm-guard\.sh" 2>/dev/null

# chroot 内业务进程：按监听端口找 PID 再杀，避免误伤同名进程
for port in 3065 5700 36592; do
  pids=$(netstat -tlnp 2>/dev/null | awk -v p=":$port " '$0 ~ p {print $0}' | grep -oE "pid=[0-9]+" | cut -d= -f2)
  for p in $pids; do kill "$p" 2>/dev/null; done
done

echo "[$(date)] 服务已停止" >> "$LOG"

if [ -d /data/local/droidvm ]; then
  echo "[=] 数据保留在 /data/local/droidvm（rootfs 约 4-5G）"
  echo "[=] 彻底删除: rm -rf /data/local/droidvm"
  echo "[=] 旧 service.d 脚本备份在 /data/local/droidvm/legacy-service-d"
fi

echo "[+] 卸载完成" >> "$LOG"
