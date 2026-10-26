# DroidVM Lite · 在 Root 安卓手机上原生运行 Linux 服务栈

> **v2.0 — 去掉软件模拟，改 chroot 原生运行**
> 同一台手机、同一套服务，CPU 占用从 196% 降到个位数，温度从 78.7°C 降到 32.5°C。

这个项目把一台闲置的 Root 安卓手机变成常驻小服务器：跑青龙面板、AI API 网关、音箱桥接、监控面板，
通过 **IPv6 直连 + 自动 HTTPS** 和 **Cloudflare Tunnel** 两条链路对外提供服务。

配套一份 [SKILL.md](./SKILL.md)：把整套流程写成智能体可执行的指令，其他 AI 代理照着做就能复刻。

---

## 0. 先说清楚：它和上一版有什么不同

上一版是 [`droidvm-module`](https://github.com/zhangdunlong/droidvm-module)：**QEMU/TCG 纯软件模拟**一台 Debian 12 虚拟机，
里面再跑 Docker。能跑，但代价很大。

这一版（v2）**完全不用软件模拟**：直接把 Ubuntu rootfs 作为 chroot 挂进 Android 内核跑。
Android 和 Linux 本来就是同一个内核，只要 root，就没有必要再模拟一个 CPU。

| 维度 | v1 · QEMU/TCG（已归档思路） | **v2 · chroot 原生（本仓库）** | 变化 |
|---|---|---|---|
| CPU 执行方式 | QEMU 逐条翻译 arm64 指令 | 原生执行，无翻译 | **质的差别** |
| 待机 CPU 占用 | 满载 ~196%（TCG 线程常驻） | 0–5% | ↓ 约 97% |
| 机身温度 | 78.7°C（长期烫手、触发降频） | 32.5°C | ↓ 46°C |
| 青龙面板响应 | 2–8 秒（冷启动更久） | 0.12 秒 | ↓ 约 20–60× |
| 首次可服务时间 | 20–40 分钟（旗舰）/ 1–2 小时（中端），apt 在软解下极慢 | 5–10 分钟（解压 rootfs + 起服务） | ↓ 一个数量级 |
| 磁盘占用 | rootfs 4.9G + qcow2 2.3G（且 qcow2 持续膨胀） | 4.9G（无虚拟机磁盘） | 省 2.3G |
| 端口暴露方式 | QEMU `hostfwd` 用户态转发，多一层开销 | 服务直接监听，零转发 | 少一跳 |
| 开机自启 | 模块 `service.sh` + 45 秒延迟 + 等 VM 引导 | `service.d` 脚本 + 等 bootanim 结束 | 更早可用 |
| 服务形态 | Docker 容器 | 直接在 chroot 内托管进程 | 少了 Docker 一层 |
| 外网入口 | 无（仅局域网 + 手工改路由） | IPv6 直连 HTTPS + Cloudflare Tunnel 双路 | 新增 |
| 运维面板 | 依赖 `docker ps` / cgroup 扫描 | 直读 `/proc` `/sys`，端口探测 | 无依赖 |
| 内存占用 | 固定吃 4G 给 VM（`VM_MEM`） | 按需，服务实际用多少算多少 | 省 3G+ |

> 一句话：**v1 是在手机里模拟一台电脑；v2 是让手机直接当那台电脑。**

逐项的详细差异（含踩坑原因）见 [CHANGELOG-v1-v2.md](./CHANGELOG-v1-v2.md)。

---

## 1. 架构

```
┌──────────────────────────────────────────────────────────────────┐
│  Root 安卓手机（arm64，Magisk / KernelSU）                          │
│                                                                    │
│  Android 层                                                        │
│  ├─ /data/adb/service.d/50-ipv6-forward.sh    IPv6 + Caddy 启动    │
│  ├─ /data/adb/service.d/95-dashboard.sh       面板启动             │
│  ├─ /data/adb/service.d/99-chroot-services.sh  业务服务启动        │
│  ├─ /data/adb/ipv6-guard.sh                   常驻自愈守护         │
│  └─ /data/adb/caddy.env                       Caddy 凭据（600）    │
│                                                                    │
│  chroot: /data/local/droidvm/rootfs  (Ubuntu 22.04 arm64, ~4.9G)   │
│  ├─ agent2api   :3065   AI API 网关                                │
│  ├─ 青龙         :5700   定时任务面板                              │
│  ├─ mi-paiai    :36592   智能音箱桥                                │
│  ├─ Caddy       :80/:443 自动 HTTPS 反代（LE DNS-01）              │
│  ├─ cloudflared          隧道客户端（可选）                        │
│  ├─ gost        :8080    IPv4→IPv6 兼容转发                        │
│  └─ dashboard   :8765    监控面板（纯标准库）                      │
│                                                                    │
│  网络栈直接复用 Android（同一内核，无 NAT 中间层）                  │
└──────────────────────────────────────────────────────────────────┘
        │                                    │
        │  IPv6 直连（快，需公网 v6）          │  Cloudflare Tunnel（兼容纯 v4 网络）
        ▼                                    ▼
   ai.example.com  ──┐                  api.example.com
   ql.example.com  ──┼─ Caddy :443      dash.example.com
   v6.example.com  ──┘  自动证书         files.example.com
```

**关键点**：chroot 与 Android 共用同一个 Linux 内核和网络栈。
所以 chroot 内进程监听的端口，等于手机上监听的端口，局域网可直接访问，**不需要任何端口转发**。

---

## 2. 前置条件

| 项 | 要求 |
|---|---|
| 架构 | arm64 / aarch64（近年手机都是） |
| 系统 | Android 10+ |
| Root | Magisk 24+ / KernelSU / APatch，且 `su` 可用 |
| 内存 | ≥ 4GB（本项目实测 7.4GB 机型，服务常驻约 1.5GB） |
| 存储 | ≥ 10GB 可用 |
| 网络 | IPv6 直连方案需运营商下发公网 IPv6；没有则只用 Cloudflare Tunnel |

验证 root 与 chroot 能力：

```bash
adb shell su -c 'id; echo ---; ls /data/local/'
```

---

## 3. 快速开始（5 步）

```bash
# 1) 准备目录
R=/data/local/droidvm
su -c "mkdir -p $R/rootfs"

# 2) 导入 Ubuntu 22.04 arm64 rootfs（见 §4.1 三种获取方式）
#    解压后应存在 $R/rootfs/etc/os-release

# 3) 挂载 chroot 必需的文件系统
su -c 'for d in proc sys dev dev/pts; do
  mountpoint -q /data/local/droidvm/rootfs/$d || mount --bind /$d /data/local/droidvm/rootfs/$d
done'

# 4) 布置服务与自启脚本（configs/ 目录下的模板改名后放入）
su -c 'cp configs/99-chroot-services.example.sh /data/adb/service.d/99-chroot-services.sh'
su -c 'chmod 755 /data/adb/service.d/*.sh'

# 5) 重启手机，或手动跑一次
su -c 'sh /data/adb/service.d/99-chroot-services.sh'
```

完成后访问 `http://<手机局域网IP>:3065` 应能看到 AI 网关面板。

> 完整的分步操作、每步验证命令、失败回滚，见 [SKILL.md](./SKILL.md)。

---

## 4. 原理详解

### 4.1 chroot 环境从哪来

三种方式，按需选择：

**A. 用官方云镜像 rootfs（推荐，最干净）**

```bash
# 在任意 Linux 机器上
wget https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz
mkdir rootfs && sudo tar -xpf ubuntu-base-22.04-base-arm64.tar.gz -C rootfs
# 拷到手机
adb push rootfs.tar.gz /data/local/tmp/
adb shell su -c 'tar -xpf /data/local/tmp/rootfs.tar.gz -C /data/local/droidvm/rootfs'
```

**B. 复用已有的 v1 rootfs**（从 QEMU 版升级上来）

v1 的 rootfs 本来就是 Ubuntu 22.04（当时只用来承载 QEMU 二进制），**可以直接拿来做 chroot**。
里面的 `qemu-system-aarch64`、`AAVMF` 固件等可以删掉，能省 20MB 以上。

**C. 用 Docker 导出**

```bash
docker create --name tmp --platform linux/arm64 ubuntu:22.04
docker export tmp | sudo tar -xpf - -C rootfs
```

**rootfs 里需要的最小依赖**：`bash`、`coreutils`、`ca-certificates`、`curl`、`python3`（面板和部分脚本用）。
不需要 systemd —— 本项目用 `setsid nohup` 直接托管进程，比在 chroot 里跑 init 更轻。

### 4.2 为什么不用 systemd

chroot 里跑 systemd 需要 `--privileged` 级别的权限和 cgroup 挂载，在 Android 上经常与 SELinux 冲突，
且 Android 自身已经在管进程生命周期。所以直接：

```bash
chroot "$R" /usr/bin/env -i PATH=... HOME=/root \
  /bin/sh -c 'cd /app && setsid nohup ./server >> /app/run.log 2>&1 < /dev/null &'
```

- `env -i`：清空环境变量，避免 Android 的 `LD_PRELOAD`、`ANDROID_*` 干扰
- `setsid nohup`：脱离终端会话，adb 断开也不会被杀
- `< /dev/null`：防止进程持有终端句柄

### 4.3 关键坑：环境变量必须显式传

`bash -lc` 在 chroot 里**不会加载** `/etc/profile`（Android 的 init 环境没有 login tty），
表现为「`curl: command not found`」「`env: command not found`」。正确写法：

```bash
# ❌ 错
chroot $R /bin/bash -lc 'curl ...'

# ✅ 对
chroot $R /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  /bin/bash -c 'curl ...'
```

---

## 5. 对外网站（脱敏后清单）

本项目跑起来后，对外暴露以下入口。下表把真实域名替换为 `example.com`，你部署时换成自己的。

### 5.1 走 IPv6 + Caddy（快，0.1–0.3 秒）

| 域名 | 后端 | 用途 |
|---|---|---|
| `ai.example.com` | `127.0.0.1:3065` | AI API 网关 + 移动端管理面板 |
| `ql.example.com` | `127.0.0.1:5700` | 青龙定时任务面板 |
| `v6.example.com` | `127.0.0.1:3065` | 旧入口兼容 / 排障用 |

### 5.2 走 Cloudflare Tunnel（兼容纯 IPv4 网络，2–20 秒）

| 域名 | 后端 | 用途 |
|---|---|---|
| `api.example.com` | `127.0.0.1:3065` | AI API（给不支持 IPv6 的客户端） |
| `dash.example.com` | `127.0.0.1:8765` | 监控面板（电量/CPU/服务/隧道） |
| `files.example.com` | `http_status:404` | 预留占位 |

### 5.3 局域网直连（最快，毫秒级）

```
http://192.168.1.100:3065/     AI 网关
http://192.168.1.100:5700/     青龙
http://192.168.1.100:8765/     监控面板
http://192.168.1.100:36592/    音箱桥
```

> 同一 WiFi 下永远优先用局域网地址 —— 不经过任何公网链路。

---

## 6. IPv6 直连 + 自动 HTTPS

Android 对 IPv6 做了两层限制，必须都绕开，否则「有地址但连不通」。

### 6.1 限制一：默认不接受路由通告

```bash
cat /proc/sys/net/ipv6/conf/wlan0/accept_ra   # 通常是 0
```

`accept_ra=0` 意味着手机拿不到运营商下发的公网 IPv6 前缀。要临时置 1，并重启一次 WiFi 触发 RA：

```bash
echo 1 > /proc/sys/net/ipv6/conf/wlan0/accept_ra
echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra
svc wifi disable; sleep 3; svc wifi enable
```

⚠️ 这个值**重启后会恢复为 0**，所以需要一个常驻守护进程反复纠正（见 §6.3）。

### 6.2 限制二：策略路由把 IPv6 全部判为 unreachable

```bash
ip -6 rule
# 100:	from all unreachable      ← 这条会导致所有 IPv6 出站/入站失败
```

绕过方式：插一条优先级更高的规则，把流量导到 `wlan0` 路由表：

```bash
ip -6 rule add priority 50 lookup wlan0
```

同样，重启后丢失，需要守护。

### 6.3 守护进程（`configs/ipv6-guard.example.sh`）

每 60 秒做四件事：

1. 纠正 `accept_ra`
2. 补回 `ip -6 rule priority 50`
3. Caddy 挂了就拉起来
4. 检测 IPv6 地址变化，写入 `/tmp/ipv6-current.txt` 供 DDNS 读取

```bash
su -c 'setsid nohup /data/adb/ipv6-guard.sh >/dev/null 2>&1 &'
```

### 6.4 端口可用性（不同运营商差异很大，必须实测）

本项目实测结论：

| 端口 | 入站 | 说明 |
|---|---|---|
| 80 | ✅ | |
| 443 | ✅ | **注意：出站 443 可能被拦，入站不受影响** |
| 8080 | ✅ | |
| 3000 / 8443 / 9090 | ❌ | 部分运营商拦截 |

> 这里有个常见误判：Caddy 申请证书时访问 Let's Encrypt 失败，会被误认为「443 被拦」。
> 实际上那是**出站** 443 的问题。用 `curl -I https://acme-v02.api.letsencrypt.org` 单独确认出站，
> 再从外部 `curl -I https://你的域名` 确认入站。

出站被拦时，给 Caddy 挂 HTTP 代理即可（本项目用本机 clash）：

```bash
export HTTPS_PROXY=http://127.0.0.1:7890
```

### 6.5 Caddy 自动证书（Let's Encrypt DNS-01）

用 DNS-01 而非 HTTP-01，因为手机上 80 端口经常被占用或不稳定。

```caddyfile
{
    admin off
    servers { protocols h1 h2 }   # 禁用 HTTP/3，UDP:8080 常被占用
}

https://ai.example.com {
    tls {
        dns cloudflare {env.CF_API_TOKEN}
        ca https://acme-v02.api.letsencrypt.org/directory
        resolvers 8.8.8.8 1.1.1.1
        propagation_delay 15s
        propagation_timeout 180s
    }
    encode gzip
    reverse_proxy 127.0.0.1:3065
}
```

三个必须注意的点：

1. **`resolvers 8.8.8.8`** —— 手机若开了代理软件，本地 DNS 会返回 fake-ip（`198.18.x.x`），
   Caddy 查 TXT 记录会拿到假地址，导致验证永远失败。
2. **`propagation_delay`** —— 不是 `dns_propagation_delay`，后者不存在会直接启动报错。
3. **不要写 `auto_https off`** —— 那会让 `tls internal` 也失效。

Caddy 需要带 cloudflare DNS 插件，官方二进制没有，自己编译：

```bash
xcaddy build --with github.com/caddy-dns/cloudflare
```

完整模板见 [`configs/Caddyfile.example`](./configs/Caddyfile.example)。

### 6.6 DDNS：把变化的 IPv6 写回 Cloudflare

家宽 IPv6 前缀会变（重启光猫、运营商轮换）。方案：守护进程写文件 → 青龙定时任务读文件 → 调 Cloudflare API 更新 AAAA。

```python
# configs/ddns-cloudflare.py（节选）
RECORDS = ["ai.example.com", "ql.example.com", "v6.example.com"]
# 每 10 分钟：读 /tmp/ipv6-current.txt → 查 AAAA → 不同则 PATCH
```

配置见 [`configs/ddns-cloudflare.py`](./configs/ddns-cloudflare.py)。TTL 设 60 秒，加快生效。

---

## 7. Cloudflare Tunnel 穿透（纯 IPv4 环境的兜底）

有公网 IPv6 时隧道不是必需，但以下场景必须靠它：公司网络只有 IPv4、运营商封了入站、不想暴露家庭 IP。

### 7.1 创建隧道

```bash
cloudflared tunnel login
cloudflared tunnel create droidvm
cloudflared tunnel route dns droidvm dash.example.com
```

### 7.2 配置文件（`configs/cloudflared-config.example.yml`）

```yaml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/droidvm-tunnel.json

ingress:
  - hostname: api.example.com
    service: http://127.0.0.1:3065
    originRequest:
      keepAliveTimeout: 10s
  - hostname: dash.example.com
    service: http://127.0.0.1:8765
    originRequest:
      keepAliveTimeout: 10s
  - hostname: files.example.com
    service: http_status:404
  - service: http_status:404
```

### 7.3 QUIC + 固定边缘 IP（国内弱网的关键优化）

默认 cloudflared 走 QUIC 时会先用 DNS 解析边缘节点，而手机上代理软件的 fake-ip 会返回
`198.18.x.x`，导致连接超时。解决：**跳过 DNS，直接指定边缘 IP**。

```bash
cloudflared --config /etc/cloudflared/config.yml \
  --no-autoupdate tunnel \
  --protocol quic \
  --ha-connections 2 \
  --edge-ip-version 4 \
  --edge 198.41.192.57:7844 \
  --edge 198.41.200.233:7844 \
  --edge 198.41.192.167:7844 \
  run
```

启动成功的标志是日志里出现两条以上：

```
INF Registered tunnel connection connIndex=0 ... location=sin20 protocol=quic
INF Registered tunnel connection connIndex=1 ... location=sin13 protocol=quic
```

> 如果代理软件开了 fake-ip 模式，还需把 `argotunnel.com`、`cfargotunnel.com` 加入 `fake-ip-filter`。

### 7.4 改完配置要重启

cloudflared 不支持热重载，改 `ingress` 后必须重启进程，会断线数秒：

```bash
pkill -f "cloudflared --config"; sleep 2
setsid nohup /etc/cloudflared/run-tunnel.sh >> /tmp/cf.log 2>&1 < /dev/null &
```

完整模板见 [`configs/cloudflared-config.example.yml`](./configs/cloudflared-config.example.yml)。

---

## 8. 服务部署

每个服务都用同一套模式：`env -i` + `setsid nohup` + 日志重定向。

### 8.1 青龙面板（:5700）

```bash
chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
  QL_DIR=/ql QL_DATA_DIR=/ql/data QL_BRANCH=master QL_PORT=5700 QL_CONTAINER=true \
  ENABLE_WEB_PANEL=true ENABLE_HANGUP=true \
  /bin/sh -c 'cd /ql && setsid nohup /usr/local/bin/node /ql/static/build/app.js >> /ql/data/log/boot.log 2>&1 < /dev/null &'
```

青龙不需要 Docker 也能跑，只是把官方镜像里的 `/ql` 目录搬进 rootfs。

### 8.2 AI API 网关（:3065）

```bash
chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  AGENT2API_ADMIN_USER=admin AGENT2API_ADMIN_PASSWORD='<强密码>' \
  AGENT2API_HOST=0.0.0.0 AGENT2API_UI_DIR=/app/ui AGENT2API_CAPTCHA_ENABLED=0 \
  /bin/sh -c 'cd /app && setsid nohup ./agent2api-server >> /app/a2a.log 2>&1 < /dev/null &'
```

### 8.3 端口清单

| 端口 | 服务 | 谁在监听 |
|---|---|---|
| 3065 | AI API | `agent2api-server` |
| 5700 | 青龙 | `node /ql/static/build/app.js` |
| 36592 | 音箱桥 | `node apps/web/dist/index.js` |
| 8765 | 监控面板 | `python3 dvm-dashboard.py` |
| 80 / 443 | HTTPS 反代 | `caddy run` |
| 8080 | IPv4→IPv6 转发 | `gost` |

---

## 9. 监控面板

单文件、纯标准库、零依赖。源码见 [`configs/dvm-dashboard.py`](./configs/dvm-dashboard.py)。

数据全部来自 Android 内核，不依赖 Docker / systemd：

| 指标 | 数据源 |
|---|---|
| 电量 / 电池温度 / 电压 / 健康度 | `/sys/class/power_supply/battery/*` |
| CPU 使用率 | `/proc/stat` 两次采样差分 |
| 可用核心数 | `len(os.sched_getaffinity(0))` |
| 内存 | `/proc/meminfo` |
| 存储 | `os.statvfs("/")` |
| CPU 温度 | `/sys/class/thermal/thermal_zone*/` |
| 服务状态 | TCP 连接探测 `127.0.0.1:<port>` |
| 隧道状态 | 扫 `/proc/*/cmdline` 找 `cloudflared` |

### 快捷入口（面板顶部的跳转链接）

面板顶部会列出常用服务的直达链接，由环境变量 `DASH_LINKS` 配置：

```bash
DASH_LINKS="青龙面板|https://ql.example.com|http://{ip4}:5700;AI 网关|https://ai.example.com|http://{ip4}:3065"
```

- 格式：`名称|公网URL|内网URL`，多条目用 `;` 分隔
- 两段写法 `名称|URL` 表示内外网同一个地址
- `{ip4}` 会被替换成当前局域网 IP
- 前端会按访问来源自动选择：内网打开走内网地址，公网打开走公网域名
- 留空则整张卡片隐藏

### 三个必须知道的数据陷阱

1. **`thermal_zone` 里混着非温度节点**
   `lmh-dcvs-00/01` 恒为 `75000`（限流阈值）、`ibat-*` 是电流、`vbat_*` 是电压、`soc` 是占位。
   直接取全局最大值会永远得到「75℃」。必须按 `type` 名称过滤，只取 `cpu*` / `cpuss*` / `gold` / `silver` / `gpu`。

2. **`charge_now` / `charge_full` 单位不可靠**
   某机型实测 `4746 / 3107`（当前 > 满充），除 1000 后显示「5/3 mAh」。
   只有 `charge_full_design`（µAh）可信；`current_now` 若为个位数说明是无效值。

3. **`batt_soh` 是千分比**
   `840` 要 ÷10 得 `84.0%`。

### 前端的坑

国产浏览器（如基于旧版 Chromium 的 VIA）**不支持 flex `gap`**，会导致小字糊在一起。
统一用 `margin` 控制间距，`grid gap` 是支持的。

```bash
chroot "$R" /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root \
  /bin/sh -c 'cd /opt/dashboard && setsid nohup python3 dvm-dashboard.py >> dash.log 2>&1 < /dev/null &'
```

---

## 10. 开机自启

Magisk 的 `/data/adb/service.d/` 会按文件名顺序执行目录下**所有**文件（不看后缀），
所以「重命名成 `.bak` 来禁用」是无效的，必须移出目录。

推荐的三个脚本：

| 文件 | 职责 | 等待 |
|---|---|---|
| `50-ipv6-forward.sh` | 开 IPv6、加策略路由、起 Caddy、起守护 | 等网络通 |
| `95-dashboard.sh` | 起监控面板 | bootanim 结束 + 40s |
| `99-chroot-services.sh` | 起业务服务（青龙/网关/音箱桥/隧道） | bootanim 结束 + 30s |

统一模板：

```bash
#!/system/bin/sh
(
  until [ "$(getprop init.svc.bootanim)" = "stopped" ]; do sleep 10; done
  sleep 30
  R=/data/local/droidvm/rootfs
  for d in proc sys dev dev/pts; do
    mountpoint -q "$R/$d" 2>/dev/null || mount --bind "/$d" "$R/$d"
  done
  if ! netstat -tln 2>/dev/null | grep -q ":5700 "; then
    chroot "$R" /usr/bin/env -i PATH=... HOME=/root /bin/sh -c '... setsid nohup ... &'
  fi
) &
```

三个细节：

- 整个脚本用 `( ... ) &` 包起来放进后台，否则会阻塞 Magisk 的启动流程
- `until bootanim stopped` 是必须的，太早执行 `mount --bind` 会失败
- 每项启动前先 `netstat` 检查端口，保证幂等

---

## 10.5 Magisk 模块形态（推荐）

除了前面那种「往 `service.d` 丢脚本」的方式，本仓库还提供完整的 Magisk 模块：
在面具里可启用 / 禁用 / 卸载，服务生命周期由模块统一管理。

### 装什么、放哪里

```
module/
├── module.prop                 # id=droidvm_chroot  version=v2.0.0
├── customize.sh                # 刷入时：查架构/rootfs、移出旧 service.d 脚本、生成配置
├── service.sh                  # 开机自启（后台子 shell，毫秒级返回，不阻塞 Magisk）
├── uninstall.sh                # 卸载：停服务、保留数据
├── bin/mgmt.sh                 # 管理命令
├── scripts/boot.sh             # 启动总入口（挂载→IPv6→Caddy→gost→业务→面板→守护）
└── META-INF/…                  # Magisk 安装器入口
```

运行期落在：

| 路径 | 内容 |
|---|---|
| `/data/adb/modules/DroidVM-Chroot/` | 模块主体（随模块卸载消失） |
| `/data/local/droidvm/` | 数据目录（rootfs + 服务数据，卸载保留） |
| `/data/adb/droidvm.env` | 运行配置，权限 600，含明文凭据 |
| `/data/local/tmp/droidvm-boot.log` | 启动日志 |

### 配置（`/data/adb/droidvm.env`）

```bash
A2A_USER=admin
A2A_PASS='<AI 网关管理员密码>'          # 留空则跳过该服务
CF_API_TOKEN='<Cloudflare Token>'       # 证书 DNS-01 用，仅需 Zone.DNS.Edit
HTTPS_PROXY='http://127.0.0.1:7890'     # 出站 443 被拦时填
DASH_LINKS='青龙面板|https://ql.example.com|http://{ip4}:5700'
DASH_DEVICE_NAME='Android Phone'
```

改完执行 `mgmt.sh restart`。

### 管理命令

```bash
M=/data/adb/modules/DroidVM-Chroot/bin/mgmt.sh
su -c "sh $M status"            # 端口/进程/IPv6/证书/隧道/资源 总览
su -c "sh $M start"             # 启动（幂等，已在跑的跳过）
su -c "sh $M stop"
su -c "sh $M restart"
su -c "sh $M log 60"            # 最近 60 行启动日志
su -c "sh $M env"               # 查看配置（凭据值打码）
su -c "sh $M restore-legacy"    # 还原安装时移出的 service.d 脚本
su -c "sh $M purge"             # 删除 /data/local/droidvm（危险，需输入 DELETE）
```

### 打包与刷入

```bash
sh build-zip.sh
# 产物 DroidVM-Chroot-v2.0.0.zip（8 个文件，脚本自动带可执行位）
```

Magisk → 模块 → 从本地安装 → 选 zip → 重启。

> 打包脚本用 Python 的 `zipfile` 而非系统 `zip`：Windows 和 Linux 行为一致，
> 且能显式写入 `update-binary` 等文件的可执行位（zip 里是 `external_attr`）。

### ⚠️ 与 `service.d` 脚本不能共存

Magisk 会执行 `/data/adb/service.d/` 下**所有文件，不看后缀**——
改名成 `.bak` 照样会被执行，必须**移出目录**。

`customize.sh` 会自动把 `50-ipv6-forward.sh` / `95-dashboard.sh` / `99-chroot-services.sh`
移到 `/data/local/droidvm/legacy-service-d/`。如果你手工部署模块，这一步要自己做：

```bash
su -c 'mkdir -p /data/local/droidvm/legacy-service-d'
su -c 'mv /data/adb/service.d/*ipv6-forward* /data/adb/service.d/*dashboard* /data/adb/service.d/*chroot-services* /data/local/droidvm/legacy-service-d/ 2>/dev/null'
```

否则会出现双份启动：两个脚本都会 `svc wifi disable/enable`（导致开机后短暂断网）、
都会尝试起同一个服务（幂等但不干净）。

## 11. 性能实测

同一套服务，两台手机对比：

| 指标 | v1 · QEMU/TCG 软解 | v2 · 中端机 + chroot |
|---|---|---|
| 待机 CPU | 196%（TCG 常驻） | 0–5% |
| 机身温度 | 78.7°C | 32.5°C |
| 青龙首屏 | 2–8s | 0.12s |
| 稳定运行 | 电池撑不到一天 | 续航正常 |
| 内存常驻 | 4G（固定分配给 VM） | 约 1.5G（按需） |

> 两台机器 SoC 不同，但差距主要来自「是否做指令翻译」，不是硬件代差。

---

## 12. 踩坑清单

| 现象 | 原因 | 解决 |
|---|---|---|
| `curl: command not found`（chroot 内） | `bash -lc` 不读 profile，PATH 为空 | 用 `env -i PATH=...` 显式传 |
| 拿到 IPv6 但 ping 不通 | `100: from all unreachable` 策略路由 | `ip -6 rule add priority 50 lookup wlan0` |
| 重启后 IPv6 又没了 | `accept_ra` 复位 | 常驻守护每 60s 纠正 |
| Caddy 证书签不下来 | 本地 DNS 是 fake-ip | `resolvers 8.8.8.8 1.1.1.1` |
| Caddy 启动报 unknown directive | 写了 `dns_propagation_delay` | 正确是 `propagation_delay` |
| cloudflared 连不上 | DNS 返回 fake-ip | 指定 `--edge <真实IP>:7844` |
| 隧道日志有两行 Registered 但访问 502 | ingress 后端端口写错 | 核对 `service:` 指向的端口 |
| 自启脚本改了没生效 | 改名成 `.bak` 仍在同目录 | 必须移出 `service.d/` |
| 面板温度永远 75℃ | `lmh-dcvs` 限流阈值冒充温度 | 按 type 过滤 |
| 面板电量显示 5/3 mAh | `charge_now` 单位不可靠 | 只用 `charge_full_design` |
| 面板小字挤在一起 | 浏览器不支持 flex `gap` | 改 margin |
| 从 v1 升级后磁盘少 2.3G | 旧 qcow2 还在 `/data/local/droidvm/vm/` | 确认不再需要后删除 |

---

## 13. 安全与脱敏说明

本仓库发布前做了以下处理：

| 项 | 处理方式 |
|---|---|
| 域名 | 真实域名 → `example.com` |
| 公网 IP / IPv6 | → `192.168.1.100` / `2001:db8::` 文档保留地址 |
| Cloudflare Zone ID / Tunnel UUID | → `<ZONE_ID>` / `<TUNNEL_UUID>` 占位 |
| API Token / 各类密钥 | → `<CF_API_TOKEN>` 占位，**不含任何可用凭据** |
| 管理员密码 | → `<强密码>` 占位 |
| 邮箱 / Telegram chat_id / 账号 | 全部移除 |
| 设备型号 | 泛化为「arm64 手机」 |
| 日志与数据库 | 不含任何运行日志、青龙数据、用户 Cookie |

**部署时请自行替换所有 `<...>` 占位符，并且不要把这些值提交回仓库。**

安全建议：

1. 青龙面板本质是「远程命令执行」，**不要裸露公网**。至少开强密码 + 二次验证，或只允许 IP 白名单。
2. `caddy.env`、隧道凭据文件权限设 `600`。
3. Cloudflare Token 只给 `Zone.DNS.Edit`，不要用全局 Token。
4. 手机长期联网运行时注意散热与电池健康，建议限制充电上限（80%）。

---

## 14. 目录说明

```
.
├── README.md                       # 本文档：完整方案
├── SKILL.md                        # 智能体可执行说明（照做即可复刻）
├── CHANGELOG-v1-v2.md              # 与上一版 QEMU 方案的逐项差异
├── configs/
│   ├── Caddyfile.example           # Caddy 反代 + 自动证书
│   ├── cloudflared-config.example.yml
│   ├── 50-ipv6-forward.example.sh  # IPv6 自启
│   ├── ipv6-guard.example.sh       # IPv6 常驻守护
│   ├── 99-chroot-services.example.sh
│   ├── 95-dashboard.example.sh
│   ├── ddns-cloudflare.py          # AAAA 自动同步
│   └── dvm-dashboard.py            # 监控面板（单文件）
└── scripts/
    └── deploy-check.sh             # 部署后自检脚本
```

---

## 15. 许可

[GPL-3.0](./LICENSE) © zhangdunlong

与上一代 [droidvm-module](https://github.com/zhangdunlong/droidvm-module) 采用相同协议。
仅供学习研究，请遵守当地法律法规与运营商条款。
