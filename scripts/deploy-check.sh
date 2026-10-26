#!/system/bin/sh
# ============================================================
# 部署后自检脚本
#
# 用法（在手机上运行）：
#   adb push deploy-check.sh /data/local/tmp/
#   adb shell su -c 'sh /data/local/tmp/deploy-check.sh'
#
# 输出每一项的 PASS / FAIL / SKIP，末尾给出汇总。
# 不修改任何配置，纯只读检查。
# ============================================================

R=/data/local/droidvm/rootfs
PASS=0
FAIL=0
SKIP=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP+1)); }

section() { echo; echo "── $1 ─────────────────────────"; }

echo "=============================================="
echo "  DroidVM chroot 部署自检"
echo "  $(date)"
echo "=============================================="

# ---------- 1. root 与架构 ----------
section "1. 运行环境"

if [ "$(id -u)" = "0" ]; then ok "root 权限"; else bad "非 root，后续检查可能不准"; fi

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then ok "架构 $ARCH"; else bad "架构 $ARCH（本方案针对 aarch64）"; fi

echo "  内核: $(uname -r)"

MEM=$(free -m 2>/dev/null | awk '/Mem:/{print $2}')
[ -n "$MEM" ] && echo "  内存: ${MEM} MB"

AVAIL=$(df -m /data 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$AVAIL" ] && echo "  /data 可用: ${AVAIL} MB"

# ---------- 2. chroot ----------
section "2. chroot 环境"

if [ -f "$R/etc/os-release" ]; then
  ok "rootfs 存在"
  echo "  $(grep PRETTY_NAME "$R/etc/os-release" | cut -d'"' -f2)"
else
  bad "找不到 $R/etc/os-release"
fi

if chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin /bin/true 2>/dev/null; then
  ok "chroot 可执行"
else
  bad "chroot 执行失败"
fi

MISS=""
for d in proc sys dev dev/pts; do
  mountpoint -q "$R/$d" 2>/dev/null || MISS="$MISS $d"
done
if [ -z "$MISS" ]; then ok "文件系统挂载完整"; else bad "未挂载:$MISS"; fi

# ---------- 3. 服务端口 ----------
section "3. 服务端口"

check_port() {
  name=$1; port=$2
  if netstat -tln 2>/dev/null | grep -q ":$port "; then
    ok "$name (: $port)"
  else
    bad "$name (: $port) 未监听"
  fi
}

check_port "AI API 网关" 3065
check_port "青龙面板"   5700
check_port "监控面板"   8765
check_port "Caddy HTTP"  80
check_port "Caddy HTTPS" 443

# ---------- 4. IPv6 ----------
section "4. IPv6"

V6=$(ip -6 addr show wlan0 2>/dev/null | grep "scope global" \
      | grep -oE "inet6 [0-9a-f:]+" | awk '{print $2}' | grep -v "^fe80" | head -1)
if [ -n "$V6" ]; then ok "公网 IPv6: $V6"; else skip "未获取公网 IPv6（只能走隧道）"; fi

RA=$(cat /proc/sys/net/ipv6/conf/wlan0/accept_ra 2>/dev/null)
if [ "$RA" = "1" ]; then ok "accept_ra = 1"; else bad "accept_ra = ${RA:-未知}（应为 1）"; fi

if ip -6 rule 2>/dev/null | grep -qE "^50:[[:space:]]"; then
  ok "策略路由 priority 50 存在"
else
  bad "缺少 ip -6 rule priority 50（IPv6 会不通）"
fi

if pgrep -f "ipv6-guard.sh" >/dev/null 2>&1; then
  ok "ipv6-guard 守护在跑"
else
  bad "ipv6-guard 未运行"
fi

# ---------- 5. HTTPS ----------
section "5. HTTPS 证书"

if pgrep -f "caddy run" >/dev/null 2>&1; then
  ok "Caddy 进程存在"
  CERTDIR="$R/var/lib/caddy/caddy/certificates"
  if [ -d "$CERTDIR" ]; then
    N=$(find "$CERTDIR" -name "*.crt" 2>/dev/null | wc -l)
    if [ "$N" -gt 0 ]; then
      ok "已签发 $N 张证书"
      find "$CERTDIR" -name "*.crt" 2>/dev/null | head -5 | while read f; do
        echo "        $(basename $(dirname $(dirname $f)))/$(basename $f)"
      done
    else
      bad "证书目录为空（DNS-01 可能失败）"
    fi
  else
    skip "证书目录不存在"
  fi
else
  bad "Caddy 未运行"
fi

# ---------- 6. 隧道 ----------
section "6. Cloudflare Tunnel"

if pgrep -f "cloudflared --config" >/dev/null 2>&1; then
  ok "cloudflared 进程存在"
  N=$(pgrep -f "cloudflared --config" 2>/dev/null | wc -l)
  echo "        PID: $(pgrep -f 'cloudflared --config' | tr '\n' ' ')"
  if netstat -tln 2>/dev/null | grep -q ":20241 "; then
    ok "隧道 metrics 端口 20241 监听中"
  else
    bad "20241 未监听（隧道可能未注册成功）"
  fi
else
  skip "cloudflared 未运行（未启用隧道）"
fi

# ---------- 7. 面板数据 ----------
section "7. 监控面板数据"

METRICS=$(chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin \
          curl -s -m 5 http://127.0.0.1:8765/api/metrics 2>/dev/null)

if [ -n "$METRICS" ]; then
  ok "面板 API 可访问"
  # 用 argv 传 JSON，避免管道 + heredoc 的引号嵌套问题
  chroot "$R" /usr/bin/env -i PATH=/usr/bin:/bin python3 -c \
    "import sys,json
d=json.loads(sys.argv[1]); b=d['battery']
print('        电量   : %s%% %s' % (b['capacity'], b['status_cn']))
print('        CPU    : %s%% / %s 核' % (d['cpu']['usage'], d['cpu']['cores']))
print('        温度   : CPU %s℃' % d['temp']['cpu'])
print('        内存   : %s%%' % d['mem']['percent'])
up=sum(1 for s in d['services'] if s['up'])
print('        服务   : %d/%d 在线' % (up, len(d['services'])))" \
    "$METRICS" 2>/dev/null || echo "        (chroot 内 python3 不可用，跳过数据解析)"
else
  bad "面板 API 无法访问"
fi

# ---------- 8. 自启脚本 ----------
section "8. 开机自启"

# 文件名可能带自定义前缀，用关键字匹配
check_autostart() {
  key=$1
  hit=$(ls /data/adb/service.d/ 2>/dev/null | grep -i "$key" | head -1)
  if [ -z "$hit" ]; then
    skip "未找到含 '$key' 的自启脚本"
  elif [ -x "/data/adb/service.d/$hit" ]; then
    ok "$hit 存在且可执行"
  else
    bad "$hit 缺少执行权限"
  fi
}

check_autostart "ipv6-forward"
check_autostart "dashboard"
check_autostart "chroot-services"

# ---------- 汇总 ----------
echo
echo "=============================================="
echo "  汇总: PASS $PASS | FAIL $FAIL | SKIP $SKIP"
echo "=============================================="
if [ "$FAIL" -gt 0 ]; then
  echo "  存在失败项，请按 README §12 踩坑清单排查"
  exit 1
else
  echo "  全部通过"
  exit 0
fi
