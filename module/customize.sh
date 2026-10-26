#!/sbin/sh
# ============================================================
# DroidVM Chroot 安装脚本（Magisk 安装器环境，busybox ash）
#
# 手工部署（不经 zip）时不需要这个脚本，按 mgmt.sh 里的
# "install-manual" 分支做等价操作即可。
# ============================================================

SKIPMOUNT=true
PROPFILE=false
POSTFSDATA=false
LATESTARTSERVICE=true

ui_print "- DroidVM Chroot v2.0.0"
ui_print "- 在 chroot 里原生跑 Linux 服务栈（不使用 QEMU）"

# ---------- 架构检查 ----------
ARCH=$(getprop ro.product.cpu.abi 2>/dev/null)
case "$ARCH" in
  arm64*|aarch64*) ui_print "- 架构: $ARCH (支持)" ;;
  *)
    ui_print "! 架构: ${ARCH:-未知}"
    abort "! 本模块仅支持 arm64 设备"
    ;;
esac

# ---------- chroot 环境检查 ----------
R=/data/local/droidvm/rootfs
if [ -d "$R/etc" ] && [ -f "$R/etc/os-release" ]; then
  ui_print "- chroot rootfs: 已就绪"
  ui_print "  $(grep -m1 PRETTY_NAME "$R/etc/os-release" | cut -d'"' -f2)"
else
  ui_print "! 未找到 chroot 环境: $R"
  ui_print "! 模块会安装，但服务无法启动"
  ui_print "! 请先按 README 准备 rootfs（或用 migrate-legacy 复用旧 rootfs）"
fi

# ---------- 移出旧的 service.d 脚本，避免双份启动 ----------
# Magisk 的 service.d 不看后缀，改名无效，必须移出目录
BK=/data/local/droidvm/legacy-service-d
mkdir -p "$BK" 2>/dev/null
MOVED=0
for f in 50-zw-ipv6-forward.sh 95-zw-dashboard.sh 99-zw-chroot-services.sh \
         50-ipv6-forward.sh 95-dashboard.sh 99-chroot-services.sh; do
  if [ -f "/data/adb/service.d/$f" ]; then
    mv "/data/adb/service.d/$f" "$BK/" 2>/dev/null && {
      ui_print "- 已移出 /data/adb/service.d/$f"
      MOVED=$((MOVED+1))
    }
  fi
done
[ "$MOVED" -gt 0 ] && ui_print "- 旧脚本已备份到 $BK（mgmt.sh restore-legacy 可还原）"

# ---------- 运行配置 ----------
ENVF=/data/adb/droidvm.env
if [ ! -f "$ENVF" ]; then
  cat > "$ENVF" <<'ENVEOF'
# ============================================================
# DroidVM Chroot 运行配置
# 明文凭据，权限必须是 600，且不要提交到任何仓库
# ============================================================

# ---- AI API 网关（3065）----
# A2A_PASS 为空时会跳过该服务启动，避免用弱密码起服务
A2A_USER=admin
A2A_PASS=

# ---- Caddy 证书（DNS-01 需要）----
# Cloudflare Token，权限只需 Zone.DNS.Edit
CF_API_TOKEN=

# ---- Caddy 出站代理（可选）----
# 出站 443 被运营商拦时填，例如 http://127.0.0.1:7890
HTTPS_PROXY=

# ---- 监控面板（8765）----
# 快捷入口：名称|公网URL|内网URL，多条目用 ; 分隔
# 例：青龙面板|https://ql.example.com|http://{ip4}:5700
DASH_LINKS=
DASH_DEVICE_NAME=

# ---- 隧道（可选，纯 IPv4 网络兜底）----
# quic 或 http2；留空默认 quic
CF_PROTOCOL=
ENVEOF
  chmod 600 "$ENVF" 2>/dev/null
  ui_print "- 已生成配置模板: $ENVF"
  ui_print "  !! 请填入 A2A_PASS 与 CF_API_TOKEN 后重启或执行 mgmt.sh start"
else
  ui_print "- 已存在配置: $ENVF（保留原值）"
fi

# ---------- 权限 ----------
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/bin/mgmt.sh" 0 0 0755
set_perm "$MODPATH/scripts/boot.sh" 0 0 0755
[ -f "$ENVF" ] && set_perm "$ENVF" 0 0 0600

ui_print "- 安装完成"
ui_print "- 管理: su -c 'sh /data/adb/modules/DroidVM-Chroot/bin/mgmt.sh status'"
ui_print "- 重启后自动启动；首启见 /data/local/tmp/droidvm-boot.log"
