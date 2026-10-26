#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DVM 仪表盘 v2 —— 真我 RMX1971 / chroot 原生版

与 K40 时期的 v1 区别：
  · v1 跑在 QEMU 访客里，靠 host 写 battery.json、靠 cgroup 扫容器、靠 systemd 查服务
  · v2 直接跑在 Android 内核的 chroot 内：
      - 电量/温度 读 /sys/class/power_supply/battery 与 /sys/class/thermal
      - CPU/内存 读 /proc/stat、/proc/meminfo（就是手机全局）
      - 服务状态 改为端口探测（本机已无 Docker/systemd）
  · 零第三方依赖，仅用标准库

访问： http://<手机IP>:8765
"""

import json
import os
import socket
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
REFRESH = 5
CACHE = {}
LOCK = threading.Lock()
START_TS = time.time()

BATT = "/sys/class/power_supply/battery"
DEVICE_NAME = os.environ.get("DASH_DEVICE_NAME", "Android Phone")

# (显示名, 端口, 说明)
SERVICES = [
    ("agent2api", 3065, "AI API 网关"),
    ("青龙", 5700, "定时任务"),
    ("青龙·二实例", 5500, "备用面板"),
    ("mi-paiai", 36592, "小爱音箱桥"),
    ("Caddy", 443, "HTTPS 反代"),
    ("Clash", 7890, "代理核心"),
    ("gost", 8080, "TCP 转发"),
]

# 端口 → 人类可读服务名（用于隧道目标展示）
# 注意：这里只做"名字翻译"，路由事实一律以 cloudflared 配置为准，
#      不要在别处再硬编码域名表——那正是 2026-10-26 标签写错（dash 仍显示青龙）的根因。
PORT_LABELS = {
    3065: "agent2api",
    5700: "青龙",
    5500: "青龙·二实例",
    36592: "mi-paiai",
    443: "Caddy",
    80: "Caddy",
    8080: "gost",
    7890: "Clash",
    8765: "仪表盘",
    20241: "cloudflared 指标",
}

# 快捷入口（{ip4} 会被替换成当前局域网 IP）
#   pub = 公网入口，lan = 内网入口；前端按访问方式自动选
#   v6=True 表示公网入口依赖 IPv6 直连（Caddy），本机无 IPv6 时前端会给出提示
LINKS = [
    {"name": "青龙面板", "pub": "https://ql.example.com",
     "lan": "http://{ip4}:5700", "desc": "定时任务", "v6": True},
    {"name": "青龙·二实例", "pub": "",
     "lan": "http://{ip4}:5500", "desc": "备用面板", "v6": True},
    {"name": "AI 网关", "pub": "https://ai.example.com",
     "lan": "http://{ip4}:3065", "desc": "agent2api", "v6": True},
    {"name": "本面板", "pub": "https://dash.example.com",
     "lan": "http://{ip4}:8765", "desc": "当前页面", "v6": False},
]

# cloudflared 配置候选路径（按优先级，chroot 内绝对路径）
TUNNEL_CONFIGS = [
    "/etc/cloudflared/dvm-config.yml",
    "/etc/cloudflared/config.yml",
]


def rd(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except Exception:
        return default


def ri(path, default=0):
    try:
        return int(rd(path, ""))
    except Exception:
        return default


def human(nbytes):
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if nbytes < 1024:
            return "%.1f %s" % (nbytes, unit)
        nbytes /= 1024.0
    return "%.1f PB" % nbytes


# ---------------- 采集器 ----------------

def collect_battery():
    cap = ri(BATT + "/capacity", -1)
    temp = ri(BATT + "/temp", 0)
    volt = ri(BATT + "/voltage_now", 0)
    cur = ri(BATT + "/current_now", 0)
    status = rd(BATT + "/status", "Unknown")
    health = rd(BATT + "/health", "Unknown")
    charge_now = ri(BATT + "/charge_now", 0)
    charge_full = ri(BATT + "/charge_full", 0)
    design = ri(BATT + "/charge_full_design", 0)   # µAh
    soh = ri(BATT + "/batt_soh", 0)

    status_cn = {
        "Charging": "充电中",
        "Discharging": "放电中",
        "Full": "已充满",
        "Not charging": "未充电",
        "Unknown": "未知",
    }.get(status, status)

    return {
        "capacity": cap,
        "temp_c": round(temp / 10.0, 1) if temp else None,
        "voltage_v": round(volt / 1e6, 2) if volt else None,
        # current_now 在本机是无效小值（个位数），小于 1mA 一律视为无效
        "current_a": round(cur / 1e6, 3) if cur > 1000 else None,
        "status": status,
        "status_cn": status_cn,
        "health": health,
        "charging": status in ("Charging", "Full"),
        # charge_now / charge_full 在本机单位不可靠（4746/3107 且 now>full），
        # 只保留可信的设计容量，当前容量靠 capacity 百分比表达
        "design_mah": round(design / 1000) if design else None,
        "soh": round(soh / 10.0, 1) if soh else None,
    }


_STAT_PREV = {}


def collect_cpu():
    try:
        parts = rd("/proc/stat").split("\n")[0].split()[1:]
        v = [int(x) for x in parts[:8]]
        total = sum(v)
        idle = v[3] + v[4]
        prev = _STAT_PREV.get("v")
        _STAT_PREV["v"] = (total, idle)
        if not prev:
            time.sleep(0.25)
            parts = rd("/proc/stat").split("\n")[0].split()[1:]
            v = [int(x) for x in parts[:8]]
            total2, idle2 = sum(v), v[3] + v[4]
            dt, di = total2 - total, idle2 - idle
        else:
            dt, di = total - prev[0], idle - prev[1]
        usage = (1.0 - di / dt) * 100 if dt > 0 else 0.0
        load = rd("/proc/loadavg", "0 0 0").split()[:3]
        try:
            cores = len(os.sched_getaffinity(0))
        except Exception:
            cores = os.cpu_count() or 0
        return {
            "usage": round(usage, 1),
            "cores": cores,
            "load": [float(x) for x in load],
        }
    except Exception:
        try:
            cores = len(os.sched_getaffinity(0))
        except Exception:
            cores = os.cpu_count() or 0
        return {"usage": None, "cores": cores, "load": [0, 0, 0]}


def collect_mem():
    info = {}
    try:
        for line in rd("/proc/meminfo").splitlines():
            k, _, v = line.partition(":")
            try:
                info[k.strip()] = int(v.strip().split()[0])
            except Exception:
                continue
    except Exception:
        pass
    total = info.get("MemTotal", 0) * 1024
    avail = info.get("MemAvailable", 0) * 1024
    used = total - avail
    swap_total = info.get("SwapTotal", 0) * 1024
    swap_free = info.get("SwapFree", 0) * 1024
    return {
        "total": total,
        "used": used,
        "avail": avail,
        "percent": round(used / total * 100, 1) if total else 0,
        "swap_total": swap_total,
        "swap_used": swap_total - swap_free,
        "total_h": human(total),
        "used_h": human(used),
        "avail_h": human(avail),
        "swap_used_h": human(swap_total - swap_free),
        "swap_total_h": human(swap_total),
    }


def collect_disk():
    try:
        st = os.statvfs("/")
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        used = total - free
        return {
            "total": total,
            "used": used,
            "percent": round(used / total * 100, 1) if total else 0,
            "total_h": human(total),
            "used_h": human(used),
            "free_h": human(free),
        }
    except Exception:
        return {"percent": 0, "total_h": "-", "used_h": "-", "free_h": "-"}


def collect_temp():
    """按传感器类型取值。

    坑：这台机器的 thermal_zone 里混着大量非温度节点
      · lmh-dcvs-*  : 限流硬件阈值，恒定 75000（不是温度）
      · ibat-*      : 电流
      · vbat_*      : 电压
      · soc         : 占位 100
    这些必须排除，否则"最高温"永远是 75℃。
    """
    exclude = ("lmh-dcvs", "ibat", "vbat", "soc", "quiet-therm")
    zones = {}
    try:
        for name in os.listdir("/sys/class/thermal"):
            if not name.startswith("thermal_zone"):
                continue
            base = "/sys/class/thermal/" + name
            typ = rd(base + "/type", "")
            v = ri(base + "/temp", 0)
            if not typ or not (1000 < v < 120000):
                continue
            if any(k in typ for k in exclude):
                continue
            zones[typ] = v / 1000.0
    except Exception:
        pass

    cpu = [
        v
        for k, v in zones.items()
        if k.startswith("cpu") or "cpuss" in k or "gold" in k or "silver" in k or "gpu" in k
    ]
    shell = zones.get("shell_back") or zones.get("shell_frame")
    return {
        "cpu": round(max(cpu), 1) if cpu else None,
        "battery": round(zones["battery"], 1) if "battery" in zones else None,
        "shell": round(shell, 1) if shell else None,
        "board": round(zones["xo-therm-adc"], 1) if "xo-therm-adc" in zones else None,
        "max": round(max(zones.values()), 1) if zones else None,
        "count": len(zones),
    }


def port_open(port, timeout=0.35):
    s = socket.socket()
    s.settimeout(timeout)
    t0 = time.time()
    try:
        s.connect(("127.0.0.1", port))
        return True, round((time.time() - t0) * 1000, 1)
    except Exception:
        return False, None
    finally:
        s.close()


def collect_services():
    out = []
    for name, port, desc in SERVICES:
        ok, ms = port_open(port)
        out.append({"name": name, "port": port, "desc": desc, "up": ok, "ms": ms})
    return out


def proc_running(keyword):
    try:
        for pid in os.listdir("/proc"):
            if not pid.isdigit():
                continue
            try:
                with open("/proc/%s/cmdline" % pid, "rb") as f:
                    cmd = f.read().replace(b"\x00", b" ").decode("utf-8", "replace")
                if keyword in cmd:
                    return True
            except Exception:
                continue
    except Exception:
        pass
    return False


def parse_ingress(path):
    """极简 cloudflared ingress 解析（零依赖，不引 yaml）。

    只关心 ingress 段内的 hostname / service 两个键，格式形如：
        ingress:
          - hostname: api.example.com
            service: http://127.0.0.1:3065
            originRequest: ...
          - service: http_status:404      # 兜底
    解析失败一律返回 []，由调用方降级提示，不抛异常。
    """
    out = []
    cur = None
    inside = False
    try:
        with open(path) as f:
            for raw in f:
                line = raw.split("#", 1)[0].rstrip()
                if not line.strip():
                    continue
                s = line.strip()
                if not inside:
                    if s.startswith("ingress:"):
                        inside = True
                    continue
                # ingress 段结束：回到顶层键
                if not line[0].isspace() and not s.startswith("-"):
                    break
                if s.startswith("-"):
                    if cur:
                        out.append(cur)
                    cur = {}
                    s = s[1:].strip()
                    if not s:
                        continue
                if cur is None:
                    continue
                k, _, v = s.partition(":")
                k = k.strip()
                if k in ("hostname", "service"):
                    cur[k] = v.strip().strip('"').strip("'")
        if cur:
            out.append(cur)
    except Exception:
        return []
    return out


def describe_service(service):
    """service 字符串 → (展示文本, 可用于探测的端口或 None)"""
    if not service:
        return "未知", None
    if service.startswith("http_status:"):
        return "占位 %s" % service.split(":", 1)[1], None
    port = None
    if "://" in service:          # http:// / https:// / tcp:// / ssh:// 等
        tail = service.rsplit(":", 1)
        if len(tail) == 2 and tail[1].strip().isdigit():
            port = int(tail[1].strip())
    if port is None:
        return service, None
    label = PORT_LABELS.get(port)
    return ("%s · %d" % (label, port) if label else "127.0.0.1:%d" % port), port


def collect_tunnel():
    running = proc_running("cloudflared")
    ok20241, _ = port_open(20241)

    src = ""
    entries = []
    for p in TUNNEL_CONFIGS:
        if os.path.exists(p):
            src = p
            entries = parse_ingress(p)
            break

    hosts = []
    for item in entries:
        host = item.get("hostname", "").strip()
        if not host:          # 兜底规则无 hostname，不展示
            continue
        target, port = describe_service(item.get("service", ""))
        up = None
        if port is not None:
            up, _ = port_open(port)
        hosts.append({"host": host, "target": target, "port": port, "up": up})

    return {
        "running": running,
        "metrics_port": ok20241,
        "config": src,
        "hosts": hosts,
    }


def collect_net():
    ip4 = ""
    try:
        # 不产生真实流量：UDP connect 只取路由选中的源地址
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("223.5.5.5", 53))
        ip4 = s.getsockname()[0]
        s.close()
    except Exception:
        pass
    ip6 = ""
    try:
        s = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
        s.connect(("2400:3200::1", 53))
        ip6 = s.getsockname()[0]
        s.close()
    except Exception:
        pass
    return {"ipv4": ip4, "ipv6": ip6}


def collect_uptime():
    up = 0.0
    try:
        up = float(rd("/proc/uptime", "0 0").split()[0])
    except Exception:
        pass
    d = int(up // 86400)
    h = int((up % 86400) // 3600)
    m = int((up % 3600) // 60)
    if d:
        txt = "%d 天 %d 小时" % (d, h)
    elif h:
        txt = "%d 小时 %d 分" % (h, m)
    else:
        txt = "%d 分钟" % m
    return {"seconds": up, "text": txt}


def collect_links(net):
    """快捷入口。环境变量 DASH_LINKS，格式：

        名称|公网URL|内网URL        三段（推荐，前端按访问来源自动选）
        名称|URL                   两段（公网内网同一个地址）

    多条目用 ; 分隔。URL 里可用 {ip4} 占位当前局域网 IP。例：
      DASH_LINKS="青龙面板|https://ql.example.com|http://{ip4}:5700;AI 网关|https://ai.example.com"

    留空则整卡隐藏（开源版默认不带真实地址）。
    仅做地址拼装，不做跨域探测（浏览器会拦，后端探测又会拖慢刷新）。
    """
    ip4 = (net or {}).get("ipv4") or "127.0.0.1"
    raw = (os.environ.get("DASH_LINKS") or "").strip()
    out = []
    if not raw:
        return out
    for item in raw.split(";"):
        item = item.strip()
        if not item or "|" not in item:
            continue
        parts = [x.strip() for x in item.split("|")]
        name = parts[0]
        pub = parts[1] if len(parts) > 1 else ""
        lan = parts[2] if len(parts) > 2 else pub
        pub = pub.replace("{ip4}", ip4)
        lan = lan.replace("{ip4}", ip4)
        if not name or not (pub or lan):
            continue
        out.append({"name": name, "pub": pub, "lan": lan or pub, "desc": ""})
    return out


def snapshot():
    net = collect_net()
    return {
        "ts": time.time(),
        "ts_text": time.strftime("%m-%d %H:%M:%S"),
        "hostname": DEVICE_NAME,
        "battery": collect_battery(),
        "cpu": collect_cpu(),
        "mem": collect_mem(),
        "disk": collect_disk(),
        "temp": collect_temp(),
        "services": collect_services(),
        "tunnel": collect_tunnel(),
        "net": net,
        "links": collect_links(net),
        "uptime": collect_uptime(),
        "dash_uptime": time.time() - START_TS,
    }


def refresh_loop():
    while True:
        try:
            data = snapshot()
            with LOCK:
                CACHE.clear()
                CACHE.update(data)
        except Exception as e:
            with LOCK:
                CACHE["error"] = str(e)
        time.sleep(REFRESH)


# ---------------- HTTP ----------------

PAGE = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>DVM 仪表盘</title>
<style>
  :root{
    --bg:#080910; --card:rgba(255,255,255,.045); --line:rgba(255,255,255,.08);
    --txt:#e8eaf2; --dim:#8b90a8; --pur:#a855f7; --pink:#ec4899;
    --ok:#34d399; --bad:#f87171; --warn:#fbbf24;
  }
  *{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
  body{
    margin:0;background:var(--bg);color:var(--txt);
    font-family:-apple-system,"PingFang SC","Noto Sans CJK SC","Microsoft YaHei",sans-serif;
    padding:18px 14px 40px;max-width:760px;margin:0 auto;
    background-image:
      radial-gradient(900px 420px at 12% -8%,rgba(168,85,247,.20),transparent 62%),
      radial-gradient(760px 380px at 92% 4%,rgba(236,72,153,.14),transparent 60%);
    background-attachment:fixed;
  }
  header{display:flex;align-items:baseline;justify-content:space-between;gap:10px;margin-bottom:16px}
  h1{font-size:19px;margin:0;letter-spacing:.4px;
     background:linear-gradient(92deg,#c084fc,#f472b6);-webkit-background-clip:text;background-clip:text;color:transparent}
  .sub{font-size:11.5px;color:var(--dim);text-align:right;line-height:1.6}
  .grid{display:grid;grid-template-columns:repeat(2,1fr);gap:10px}
  /* min-width:0 必须加：grid 的 1fr 最小值是 min-content，
     不加会让「温度」卡片的三个 nowrap 指标撑破列宽，窄屏整页横向溢出 */
  .card{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:14px 15px;
        min-width:0;
        backdrop-filter:blur(14px);-webkit-backdrop-filter:blur(14px)}
  .wide{grid-column:1/-1}
  .k{font-size:11.5px;color:var(--dim);letter-spacing:.5px;margin-bottom:7px}
  .v{font-size:25px;font-weight:600;font-variant-numeric:tabular-nums;letter-spacing:-.5px}
  .v small{font-size:12px;font-weight:400;color:var(--dim);margin-left:3px}
  .bar{height:6px;border-radius:99px;background:rgba(255,255,255,.08);margin-top:10px;overflow:hidden}
  .bar>i{display:block;height:100%;border-radius:99px;
         background:linear-gradient(90deg,var(--pur),var(--pink));transition:width .45s ease}
  .bar.ok>i{background:linear-gradient(90deg,#10b981,#34d399)}
  .bar.warn>i{background:linear-gradient(90deg,#f59e0b,#fbbf24)}
  .bar.bad>i{background:linear-gradient(90deg,#dc2626,#f87171)}
  /* 不用 flex gap：部分国产浏览器内核不支持，改用 margin */
  .meta{font-size:11.5px;color:var(--dim);margin-top:10px;display:flex;flex-wrap:wrap}
  .meta span{white-space:nowrap;margin:0 18px 5px 0}
  .meta b{color:#c9cde0;font-weight:500}
  .svc{display:flex;align-items:center;padding:9px 0;border-bottom:1px solid rgba(255,255,255,.05);font-size:13.5px}
  .svc:last-child{border-bottom:none}
  .dot{width:8px;height:8px;border-radius:99px;flex:0 0 auto;margin-right:9px}
  .dot.on{background:var(--ok);box-shadow:0 0 9px rgba(52,211,153,.85)}
  .dot.off{background:var(--bad);box-shadow:0 0 9px rgba(248,113,113,.6)}
  .svc .nm{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .svc .pt{color:var(--dim);font-size:11.5px;font-variant-numeric:tabular-nums}
  .svc .ms{color:var(--ok);font-size:11px;min-width:40px;text-align:right}
  .svc .ms.bad{color:var(--bad)}
  .host{display:flex;justify-content:space-between;gap:10px;font-size:12.5px;padding:6px 0;
        border-bottom:1px solid rgba(255,255,255,.05);color:var(--dim);min-width:0}
  .host:last-child{border-bottom:none}
  .host>span{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .host>b{flex:0 1 auto;min-width:0;text-align:right;white-space:nowrap;
          overflow:hidden;text-overflow:ellipsis}
  .host b{color:#c9cde0;font-weight:500;font-family:ui-monospace,Menlo,monospace;font-size:11.5px}
  .tag{display:inline-block;font-size:10.5px;padding:2px 8px;border-radius:99px;margin-left:6px;
       background:rgba(52,211,153,.14);color:var(--ok);border:1px solid rgba(52,211,153,.28)}
  .tag.off{background:rgba(248,113,113,.13);color:var(--bad);border-color:rgba(248,113,113,.3)}
  /* 快捷入口 */
  .lnk{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:10px 0;
       border-bottom:1px solid rgba(255,255,255,.05);font-size:13.5px;
       color:var(--txt);text-decoration:none;min-width:0}
  .lnk:last-child{border-bottom:none}
  .lnk:active{opacity:.6}
  .lnk>span:first-child{min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .lnk .u{color:var(--dim);font-size:11px;font-weight:400}
  .lnk .go{flex:0 0 auto;font-size:11.5px;color:var(--pur);white-space:nowrap}
  .lnk.dim{opacity:.5}
  .lnk.dim .go{color:var(--warn)}
  footer{margin-top:16px;text-align:center;font-size:11px;color:var(--dim);line-height:1.7}
  @media(max-width:430px){.v{font-size:22px}.card{padding:12px 13px}}
</style>
</head>
<body>
<header>
  <h1>DVM 仪表盘</h1>
  <div class="sub"><span id="host">—</span><br><span id="ip">—</span></div>
</header>

<div class="grid">
  <div class="card wide">
    <div class="k">快捷入口</div>
    <div id="links"></div>
  </div>

  <div class="card wide">
    <div class="k">电池</div>
    <div style="display:flex;align-items:flex-end;justify-content:space-between;gap:12px">
      <div class="v"><span id="batt">—</span><small>%</small></div>
      <div style="text-align:right;font-size:11.5px;color:var(--dim);line-height:1.7">
        <div id="batt-status">—</div>
        <div id="batt-temp">—</div>
      </div>
    </div>
    <div class="bar" id="batt-bar"><i style="width:0%"></i></div>
    <div class="meta">
      <span>电压 <b id="batt-volt">—</b></span>
      <span>健康 <b id="batt-health">—</b></span>
      <span>健康度 <b id="batt-soh">—</b></span>
      <span>设计容量 <b id="batt-cap">—</b></span>
    </div>
  </div>

  <div class="card">
    <div class="k">CPU</div>
    <div class="v"><span id="cpu">—</span><small>%</small></div>
    <div class="bar" id="cpu-bar"><i style="width:0%"></i></div>
    <div class="meta"><span>核心 <b id="cores">—</b></span><span>负载 <b id="load">—</b></span></div>
  </div>

  <div class="card">
    <div class="k">温度 · CPU</div>
    <div class="v"><span id="temp">—</span><small>℃</small></div>
    <div class="bar" id="temp-bar"><i style="width:0%"></i></div>
    <div class="meta">
      <span>电池 <b id="temp-batt">—</b></span>
      <span>外壳 <b id="temp-shell">—</b></span>
      <span>主板 <b id="temp-board">—</b></span>
    </div>
  </div>

  <div class="card wide">
    <div class="k">内存</div>
    <div class="v"><span id="mem-p">—</span><small>%</small></div>
    <div class="bar" id="mem-bar"><i style="width:0%"></i></div>
    <div class="meta"><span>已用 <b id="mem-u">—</b></span><span>可用 <b id="mem-a">—</b></span><span>总计 <b id="mem-t">—</b></span><span>Swap <b id="mem-s">—</b></span></div>
  </div>

  <div class="card wide">
    <div class="k">存储（data 分区）</div>
    <div class="v"><span id="disk-p">—</span><small>%</small></div>
    <div class="bar" id="disk-bar"><i style="width:0%"></i></div>
    <div class="meta"><span>已用 <b id="disk-u">—</b></span><span>剩余 <b id="disk-f">—</b></span><span>总计 <b id="disk-t">—</b></span></div>
  </div>

  <div class="card wide">
    <div class="k">服务</div>
    <div id="svcs"></div>
  </div>

  <div class="card wide">
    <div class="k">Cloudflare 隧道 <span id="tunnel-tag" class="tag">—</span></div>
    <div class="host"><span>cloudflared 进程</span><b id="tunnel-proc">—</b></div>
    <div id="hosts"></div>
  </div>
</div>

<footer>
  <div>运行 <span id="uptime">—</span> · 更新于 <span id="ts">—</span></div>
  <div>每 3 秒自动刷新 · 数据来自 Android 内核 /proc /sys</div>
</footer>

<script>
const $=id=>document.getElementById(id);
function bar(el,pct,rev){
  const i=el.firstElementChild; i.style.width=Math.max(0,Math.min(100,pct||0))+'%';
  el.className='bar'+(rev?(pct>=88?' bad':pct>=70?' warn':''):(pct>=88?' bad':pct>=70?' warn':''));
}
async function tick(){
  try{
    const r=await fetch('/api/metrics',{cache:'no-store'});
    const d=await r.json();
    if(d.error){$('ts').textContent='采集异常：'+d.error;return;}

    $('host').textContent=d.hostname||'—';
    $('ip').textContent=(d.net.ipv4||'')+(d.net.ipv6?' · IPv6':'');
    $('uptime').textContent=d.uptime.text;
    $('ts').textContent=d.ts_text;


    const b=d.battery;
    $('batt').textContent=b.capacity>=0?b.capacity:'—';
    $('batt-status').textContent=b.status_cn||'—';
    $('batt-temp').textContent=b.temp_c?('电池 '+b.temp_c+'℃'):'—';
    $('batt-volt').textContent=b.voltage_v?(b.voltage_v+' V'):'—';
    $('batt-health').textContent=b.health||'—';
    $('batt-soh').textContent=b.soh?(b.soh+'%'):'—';
    $('batt-cap').textContent=b.design_mah?(b.design_mah+' mAh'):'—';
    bar($('batt-bar'),b.capacity,true);
    // 电量越低越该显红，这里反过来：低电量高警示
    const bb=$('batt-bar'); bb.className='bar'+(b.capacity<=15?' bad':b.capacity<=30?' warn':'');

    const c=d.cpu;
    $('cpu').textContent=c.usage==null?'—':c.usage;
    $('cores').textContent=c.cores||'—';
    $('load').textContent=(c.load||[]).map(x=>x.toFixed(2)).join(' / ');
    bar($('cpu-bar'),c.usage,true);

    const t=d.temp;
    $('temp').textContent=t.cpu==null?'—':t.cpu;
    $('temp-batt').textContent=t.battery==null?'—':t.battery+'℃';
    $('temp-shell').textContent=t.shell==null?'—':t.shell+'℃';
    $('temp-board').textContent=t.board==null?'—':t.board+'℃';
    bar($('temp-bar'),t.cpu?Math.min(100,(t.cpu-25)/60*100):0,true);

    const m=d.mem;
    $('mem-p').textContent=m.percent;
    $('mem-u').textContent=m.used_h; $('mem-a').textContent=m.avail_h;
    $('mem-t').textContent=m.total_h;
    $('mem-s').textContent=m.swap_total?(m.swap_used_h+'/'+m.swap_total_h):'无';
    bar($('mem-bar'),m.percent,true);

    const k=d.disk;
    $('disk-p').textContent=k.percent;
    $('disk-u').textContent=k.used_h; $('disk-f').textContent=k.free_h; $('disk-t').textContent=k.total_h;
    bar($('disk-bar'),k.percent,true);

    $('svcs').innerHTML=d.services.map(s=>
      `<div class="svc"><span class="dot ${s.up?'on':'off'}"></span>
       <span class="nm">${s.name}<span style="color:var(--dim);font-size:11px"> · ${s.desc}</span></span>
       <span class="pt">${s.port}</span>
       <span class="ms ${s.up?'':'bad'}">${s.up?(s.ms+'ms'):'down'}</span></div>`).join('');

    // 快捷入口：内网打开走内网地址，公网打开走公网域名
    const isLan=/^(10\.|127\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(location.hostname);
    const v6ok=!!(d.net&&d.net.ipv6);
    $('links').innerHTML=(d.links||[]).map(l=>{
      const url=isLan?(l.lan||l.pub):(l.pub||l.lan);
      const needV6=!isLan&&l.v6&&!v6ok&&l.pub;      // 公网入口依赖 IPv6，本机暂无
      const scope=isLan?'内网':(l.pub?'公网':'内网');
      const tip=needV6?'公网需 IPv6，当前未获取':(l.desc||'');
      const tipHtml = tip ? `<span class="u"> · ${tip}</span>` : '';
      return `<a class="lnk${needV6?' dim':''}" href="${url}" target="_blank" rel="noopener">
        <span>${l.name}${tipHtml}</span>
        <span class="go">${needV6?'仅内网':scope} ↗</span></a>`;
    }).join('');

    const tu=d.tunnel;
    $('tunnel-tag').textContent=tu.running?'运行中':'未运行';
    $('tunnel-tag').className='tag'+(tu.running?'':' off');
    $('tunnel-proc').textContent=tu.running?('running'+(tu.config?(' · '+tu.config.split('/').pop()):'')):'stopped';
    if(!tu.hosts.length){
      $('hosts').innerHTML=`<div class="host"><span>未解析到域名路由</span><b>${tu.config||'未找到 cloudflared 配置'}</b></div>`;
    }else{
      $('hosts').innerHTML=tu.hosts.map(h=>{
        const dot=h.up===true
          ?'<span class="dot on" style="display:inline-block;margin-right:7px;vertical-align:middle"></span>'
          :h.up===false
          ?'<span class="dot off" style="display:inline-block;margin-right:7px;vertical-align:middle"></span>':'';
        return `<div class="host"><span>${dot}${h.host}</span><b>→ ${h.target}</b></div>`;
      }).join('');
    }
  }catch(e){ $('ts').textContent='请求失败：'+e.message; }
}
tick(); setInterval(tick,3000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            self._send(200, PAGE, "text/html; charset=utf-8")
        elif path == "/api/metrics":
            with LOCK:
                data = dict(CACHE)
            self._send(200, json.dumps(data, ensure_ascii=False))
        elif path == "/healthz":
            self._send(200, "ok", "text/plain; charset=utf-8")
        else:
            self._send(404, json.dumps({"error": "not found"}))


def main():
    threading.Thread(target=refresh_loop, daemon=True).start()
    time.sleep(0.6)
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print("dvm-dashboard v2 listening on 0.0.0.0:%d" % PORT, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
