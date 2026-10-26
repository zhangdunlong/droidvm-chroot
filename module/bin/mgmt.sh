#!/system/bin/sh
# ============================================================
# DroidVM Chroot 管理脚本
#
# 用法:
#   su -c 'sh /data/adb/modules/DroidVM-Chroot/bin/mgmt.sh <命令>'
#
# 命令:
#   start          启动全部服务（幂等，已在跑的会跳过）
#   stop           停止全部服务（只动本项目进程）
#   restart        stop + start
#   status         状态总览（端口/进程/IPv6/证书/隧道）
#   log [行数]     查看启动日志
#   dashboard      打印面板地址（含局域网与公网）
#   env            查看运行配置（隐去凭据值）
#   restore-legacy 把安装时移出的 service.d 脚本放回原位
#   purge          删除 /data/local/droidvm（危险，需二次确认）
# ============================================================

MODDIR=/data/adb/modules/DroidVM-Chroot
R=/data/local/droidvm/rootfs
DATADIR=/data/local/droidvm
ENVF=/data/adb/droidvm.env
LOG=/data/local/tmp/droidvm-boot.log

# 端口 → 服务名
PORTS="3065:agent2api 5700:青龙 36592:音箱桥 8765:监控面板 443:Caddy 7890:Clash"

port_up() { netstat -tln 2>/dev/null | grep -q ":$1 "; }

lan_ip() {
  ip route get 1.1.1.1 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1
}

do_start() {
  [ -d "$R/etc" ] || { echo "❌ 未找到 chroot 环境: $R"; exit 1; }
  echo "[*] 启动中，日志: $LOG"
  sh "$MODDIR/scripts/boot.sh"
  echo "[+] 完成。用 status 查看结果"
}

do_stop() {
  echo "[*] 停止服务…"
  pkill -f "[c]addy run" 2>/dev/null && echo "  - Caddy"
  pkill -f "[c]loudflared --config" 2>/dev/null && echo "  - cloudflared"
  pkill -f "[d]vm-dashboard\.py" 2>/dev/null && echo "  - 监控面板"
  pkill -f "[i]pv6-guard\.sh" 2>/dev/null && echo "  - IPv6 守护"

  # 业务进程按端口定位，避免误杀同名进程
  for port in 3065 5700 36592; do
    pids=$(ss -ltnp 2>/dev/null | grep ":$port " | grep -oE 'pid=[0-9]+' | cut -d= -f2)
    for p in $pids; do kill "$p" 2>/dev/null && echo "  - 端口 $port (PID $p)"; done
  done
  sleep 2
  echo "[+] 已停止"
}

do_status() {
  echo "=============================================="
  echo " DroidVM Chroot · 状态"
  echo "=============================================="

  echo
  echo "── 端口 ──"
  for item in $PORTS; do
    p=${item%%:*}; name=${item#*:}
    if port_up "$p"; then
      printf "  ✅ %-6s %s\n" "$p" "$name"
    else
      printf "  ❌ %-6s %s\n" "$p" "$name"
    fi
  done

  echo
  echo "── 进程 ──"
  for pat in "caddy run:Caddy" "cloudflared --config:cloudflared" \
             "dvm-dashboard.py:监控面板" "ipv6-guard.sh:IPv6 守护" \
             "agent2api-server:agent2api" "static/build/app.js:青龙"; do
    p=${pat%%:*}; n=${pat#*:}
    pid=$(pgrep -f "[${p:0:1}]${p:1}" 2>/dev/null | head -1)
    if [ -n "$pid" ]; then printf "  ✅ %-12s PID %s\n" "$n" "$pid"
    else printf "  ❌ %-12s\n" "$n"; fi
  done

  echo
  echo "── 网络 ──"
  IP=$(lan_ip)
  echo "  局域网: ${IP:-未知}"
  V6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" \
        | grep -oE "inet6 [0-9a-f:]+" | awk '{print $2}' | grep -v "^fe80" | head -1)
  echo "  IPv6  : ${V6:-未获取}"
  echo "  accept_ra=$(cat /proc/sys/net/ipv6/conf/wlan0/accept_ra 2>/dev/null)  \
disable_ipv6=$(cat /proc/sys/net/ipv6/conf/wlan0/disable_ipv6 2>/dev/null)"
  ip -6 rule 2>/dev/null | grep -qE "^50:" && echo "  策略路由: ✅ priority 50" || echo "  策略路由: ❌ 缺失"

  echo
  echo "── HTTPS 证书 ──"
  CD="$R/var/lib/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory"
  if [ -d "$CD" ]; then
    for d in "$CD"/*/; do
      [ -d "$d" ] && echo "  ✅ $(basename "$d")"
    done
  else
    echo "  （尚无证书）"
  fi

  echo
  echo "── 隧道 ──"
  if pgrep -f "[c]loudflared --config" >/dev/null 2>&1; then
    if [ "$(curl -s -m 4 -o /dev/null -w '%{http_code}' http://127.0.0.1:20241/ready 2>/dev/null)" = "200" ]; then
      echo "  ✅ 已连接 Cloudflare 边缘"
    else
      echo "  ⚠️  进程在跑但未就绪（出站 UDP/TLS 可能被拦，见 log）"
    fi
  else
    echo "  — 未运行"
  fi

  echo
  echo "── 资源 ──"
  echo "  电量: $(cat /sys/class/power_supply/battery/capacity 2>/dev/null)% \
$(cat /sys/class/power_supply/battery/status 2>/dev/null)"
  echo "  负载: $(cat /proc/loadavg 2>/dev/null | cut -d' ' -f1-3)"
  echo "  内存: $(free -m 2>/dev/null | awk '/Mem:/{printf "%d/%d MB", $3, $2}')"
  echo "  磁盘: $(df -h /data 2>/dev/null | tail -1 | awk '{print $3"/"$2" ("$5")"}')"

  echo
  echo "── 面板 ──"
  IP=$(lan_ip)
  echo "  内网: http://${IP:-<手机IP>}:8765/"
  [ -f "$ENVF" ] && . "$ENVF" 2>/dev/null
  if [ -n "$DASH_LINKS" ]; then
    echo "  入口:"
    echo "$DASH_LINKS" | tr ';' '\n' | while IFS='|' read -r name pub lan; do
      [ -z "$name" ] && continue
      [ -z "$pub" ] && pub="$lan"
      echo "    · $name -> $pub"
    done
  fi
}

do_env() {
  if [ ! -f "$ENVF" ]; then
    echo "❌ 配置不存在: $ENVF"
    return 1
  fi
  echo "配置文件: $ENVF（权限 $(stat -c %a "$ENVF" 2>/dev/null)）"
  echo "----------------------------------------------"
  # 隐去敏感值
  sed -E 's/^(A2A_PASS|CF_API_TOKEN|HTTPS_PROXY)=.*/\1=******/' "$ENVF"
  echo "----------------------------------------------"
  echo "编辑: su -c 'vi $ENVF'  改完执行 mgmt.sh restart"
}

do_restore_legacy() {
  BK=$DATADIR/legacy-service-d
  if [ ! -d "$BK" ]; then
    echo "没有备份目录: $BK"
    return 1
  fi
  n=0
  for f in "$BK"/*; do
    [ -f "$f" ] || continue
    cp "$f" "/data/adb/service.d/$(basename "$f")" && {
      echo "  + 已还原 $(basename "$f")"
      n=$((n+1))
    }
  done
  [ "$n" -gt 0 ] && echo "⚠️  旧脚本已还原，它们会与本模块重复启动同样的服务（幂等但会刷日志）。"
  [ "$n" -gt 0 ] && echo "    确认不再需要时请再移走，或禁用本模块。"
}

do_purge() {
  echo "⚠️  此操作将删除 $DATADIR（含 rootfs 约 4-5G 与服务数据），不可恢复。"
  printf "输入 DELETE 确认: "
  read ans
  if [ "$ans" = "DELETE" ]; then
    do_stop
    umount "$R/proc" "$R/sys" "$R/dev/pts" "$R/dev" 2>/dev/null
    rm -rf "$DATADIR"
    echo "[+] 已删除"
  else
    echo "已取消"
  fi
}

case "$1" in
  start)          do_start ;;
  stop)           do_stop ;;
  restart)        do_stop; sleep 2; do_start ;;
  status)         do_status ;;
  log)            tail -n "${2:-40}" "$LOG" 2>/dev/null || echo "(无日志)" ;;
  dashboard)      IP=$(lan_ip); echo "内网: http://${IP:-<手机IP>}:8765/" ;;
  env)            do_env ;;
  restore-legacy) do_restore_legacy ;;
  purge)          do_purge ;;
  *)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
esac
