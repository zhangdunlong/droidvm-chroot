---
name: droidvm-chroot
description: 在已 Root 的 arm64 安卓手机上，用 chroot 原生方式（不使用 QEMU/TCG 等任何指令模拟）部署 Linux 服务栈，并通过 IPv6 直连 + Caddy 自动 HTTPS、以及 Cloudflare Tunnel 两条链路对外提供服务。当用户提到「手机当服务器」「手机跑青龙/面板/API 网关」「安卓上跑 Linux」「root 手机部署服务」「手机公网访问」「手机 IPv6 内网穿透」「DroidVM」时使用。也用于把已有的 QEMU 虚拟机方案迁移到 chroot 原生。
---

# 在 Root 安卓手机上原生运行 Linux 服务栈

## 这是什么

把一台闲置的 Root 安卓手机变成常驻小服务器。核心主张：**安卓和 Linux 是同一个内核，只要 root，就
不应该再用 QEMU 模拟一个 CPU。**

后果很直接：CPU 占用从 200% 降到个位数，温度从 79°C 降到 33°C，面板响应从 8 秒降到 0.12 秒。

三个子能力：

| 能力 | 作用 |
|---|---|
| chroot 原生托管 | 在手机里跑 Linux 服务，零模拟、零容器开销 |
| IPv6 直连 + 自动 HTTPS | 家宽公网 IPv6 + Caddy + Let's Encrypt，0.1–0.3 秒响应 |
| Cloudflare Tunnel | 兼容只有 IPv4 的网络，不暴露家庭 IP |

---

## 何时使用

**应该用**

- 用户想让 root 过的安卓手机长期跑服务（面板、定时任务、API 网关、下载器、监控）
- 用户抱怨"手机跑虚拟机太烫/太慢/太耗电"
- 用户想从公网访问手机上的服务，但运营商封了端口或没有公网 IPv4
- 用户已有 QEMU 版方案（如 `droidvm-module`），想降低资源占用

**不该用**

- 手机没有 root —— 本方案全程依赖 `su`
- 需要运行第三方 Docker 镜像且不愿处理依赖（那种场景虚拟机反而省事）
- 需要强隔离/多租户（手机场景一般不需要）
- 非 arm64 架构（本方案针对 arm64，x86 手机极罕见）

**需要向用户确认的关键信息**

1. 是否能 `su -c id` 拿到 uid=0
2. 运营商是否下发了公网 IPv6（`ip -6 addr show wlan0` 是否有 `2408:` / `240e:` / `2001:` 前缀的全局地址）
3. 是否有域名，且能否用 Cloudflare 托管（隧道和 DNS-01 证书都需要）
4. 手机可用存储是否 ≥ 10GB

---

## 能力边界（先明确，别承诺过头）

| 可以做 | 不可以做 |
|---|---|
| 部署自建/开源服务、开 HTTPS 入口、做监控面板 | 在没 root 的设备上运行 |
| 迁移 QEMU 方案到 chroot | 保证运营商不封 80/443 入站 |
| 配置 DDNS 应对 IPv6 变化 | 保证 IPv6 前缀永不变化 |
| 配置 Cloudflare Tunnel | 用免费 Tunnel 承载大流量/视频 |

---

## 阶段 0 · 环境探测（先跑完再动手）

```bash
# 0.1 设备与 root
adb devices -l
adb shell su -c 'id; getprop ro.product.model; getprop ro.build.version.release'

# 0.2 架构（必须 arm64）
adb shell 'uname -m'        # 期望 aarch64

# 0.3 内存与存储
adb shell 'free -m | head -2; df -h /data | tail -1'

# 0.4 是否已有旧方案残留
adb shell su -c 'ls -la /data/local/droidvm/ 2>/dev/null; ls /data/adb/modules/ 2>/dev/null'

# 0.5 IPv6 能力
adb shell su -c 'ip -6 addr show wlan0 | grep inet6'
adb shell su -c 'cat /proc/sys/net/ipv6/conf/wlan0/accept_ra'
adb shell su -c 'ip -6 rule'

# 0.6 端口占用（避免冲突）
adb shell su -c 'netstat -tln | grep LISTEN'
```

**判定规则**

| 探测结果 | 决策 |
|---|---|
| `su -c id` 不是 uid=0 | 停止，告知用户需要先 root |
| `uname -m` 非 aarch64 | 停止，本方案不适用 |
| 已有 `/data/local/droidvm/rootfs` | 进入「迁移路径」（见阶段 1B） |
| `accept_ra` = 0 且无 IPv6 地址 | 需要执行阶段 4 的 IPv6 修复；若运营商不支持则只能靠隧道 |
| `ip -6 rule` 里有 `100: from all unreachable` | 必须加 `priority 50 lookup wlan0` 规则，否则 IPv6 不通 |

---

## 阶段 1 · 建立 chroot 环境

### 1A 全新部署

```bash
R=/data/local/droidvm
adb shell su -c "mkdir -p $R/rootfs"

# 方式一：官方 base rootfs（推荐）
# 在任一台 Linux 上：
wget https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz
adb push ubuntu-base-22.04-base-arm64.tar.gz /data/local/tmp/rootfs.tar.gz
adb shell su -c "tar -xpf /data/local/tmp/rootfs.tar.gz -C $R/rootfs"

# 方式二：复用 Docker 导出
# docker create --name tmp --platform linux/arm64 ubuntu:22.04
# docker export tmp | tar -xpf - -C rootfs
```

**验证**

```bash
adb shell su -c "cat $R/rootfs/etc/os-release | head -3"
# 期望：PRETTY_NAME="Ubuntu 22.04.x LTS"
```

### 1B 从 QEMU 版迁移

旧 rootfs 本身也是 Ubuntu 22.04，**可以直接复用**，不需要重建：

```bash
# 1) 先停旧虚拟机
adb shell su -c 'sh /data/adb/modules/DroidVM/bin/mgmt.sh stop'

# 2) 确认 rootfs 可用
adb shell su -c 'cat /data/local/droidvm/rootfs/etc/os-release'

# 3) 清理不再需要的 QEMU 组件（可选，省 20MB+）
adb shell su -c 'rm -f /data/local/droidvm/rootfs/usr/bin/qemu-system-aarch64'

# 4) 数据迁移后再删虚拟机磁盘（省约 2.3G）
#    !! 必须先确认青龙数据/网关 db 已拷到 chroot 对应目录 !!
adb shell su -c 'du -sh /data/local/droidvm/vm; rm -rf /data/local/droidvm/vm'
```

### 1C 安装最小依赖

```bash
adb shell su -c "chroot $R /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root /bin/bash -c 'apt-get update && apt-get install -y ca-certificates curl python3 tzdata'"
```

**⚠️ 最容易踩的坑**：chroot 里 `bash -lc` **不会加载** `/etc/profile`，PATH 为空，
表现为 `curl: command not found`。必须显式传 PATH：

```bash
# ❌ 错
chroot $R /bin/bash -lc 'curl -I https://example.com'
# ✅ 对
chroot $R /usr/bin/env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
  /bin/bash -c 'curl -I https://example.com'
```

---

## 阶段 2 · 部署服务

### 2.1 通用启动模式

所有服务统一用这个模板，**不要用 systemd**（chroot 里跑 init 会和 Android 的 SELinux 打架）：

```bash
chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
  <业务所需的环境变量> \
  /bin/sh -c 'cd <工作目录> && setsid nohup <启动命令> >> <日志路径> 2>&1 < /dev/null &'
```

三个参数缺一不可：

- `env -i`：清空 Android 的环境变量，避免 `LD_PRELOAD` 注入
- `setsid nohup`：脱离终端，adb 断开也不被杀
- `< /dev/null`：防止进程持有终端句柄

### 2.2 青龙面板（:5700）

```bash
chroot "$R" /usr/bin/env -i \
  PATH=/usr/local/bin:/usr/bin:/bin HOME=/root TZ=Asia/Shanghai LANG=C.UTF-8 \
  QL_DIR=/ql QL_DATA_DIR=/ql/data QL_BRANCH=master QL_PORT=5700 QL_CONTAINER=true \
  ENABLE_WEB_PANEL=true ENABLE_HANGUP=true \
  /bin/sh -c 'cd /ql && setsid nohup /usr/local/bin/node /ql/static/build/app.js >> /ql/data/log/boot.log 2>&1 < /dev/null &'
```

前置：把青龙镜像里的 `/ql` 目录放进 rootfs。青龙不依赖 Docker，只依赖 node。

**验证**

```bash
adb shell su -c 'netstat -tln | grep ":5700 "'
curl -s -o /dev/null -w "%{http_code}\n" http://<手机IP>:5700/
```

### 2.3 其他服务

按同样模式替换 `cd` 目录与启动命令即可。常见端口规划：

| 端口 | 服务 | 备注 |
|---|---|---|
| 3065 | AI API 网关 | |
| 5700 | 青龙 | 也可再开第二个实例（如 5500） |
| 8765 | 监控面板 | 见阶段 6 |
| 80 / 443 | Caddy | 见阶段 4 |
| 8080 | gost 转发 | IPv4→IPv6 兼容用 |

---

## 阶段 3 · 开机自启

### 3.1 放置脚本

```bash
# 把模板里的 <...> 占位符替换成实际值后：
adb push 99-chroot-services.sh /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/99-chroot-services.sh /data/adb/service.d/'
adb shell su -c 'chmod 755 /data/adb/service.d/*.sh'
```

### 3.2 启动脚本骨架

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
    chroot "$R" /usr/bin/env -i PATH=... HOME=/root \
      /bin/sh -c 'cd /ql && setsid nohup node /ql/static/build/app.js >> /ql/data/log/boot.log 2>&1 < /dev/null &'
  fi
) &
```

三个必须遵守的规则：

1. **整个脚本用 `( ... ) &` 包起来**，否则会阻塞 Magisk 启动流程
2. **必须等 `bootanim stopped`**，太早 `mount --bind` 会失败
3. **每项启动前先 `netstat` 查端口**，保证重复执行幂等

### 3.3 ⚠️ 禁用脚本的正确方式

Magisk 的 `service.d` 会执行目录下**所有**文件，**不看后缀**。
把 `99-xxx.sh` 改名成 `99-xxx.sh.bak` **仍然会被执行**。要禁用必须移出目录：

```bash
adb shell su -c 'mkdir -p /data/adb/disabled-services && mv /data/adb/service.d/99-xxx.sh /data/adb/disabled-services/'
```

---

## 阶段 4 · IPv6 直连 + 自动 HTTPS

### 4.1 判断可行性

```bash
adb shell su -c 'ip -6 addr show wlan0 | grep "scope global"'
```

有 `2408:` / `240e:` / `2001:` 开头的全局地址 → 可行。
只有 `fe80:` 链路本地地址 → 运营商没下发，跳到阶段 5 用隧道。

### 4.2 修 IPv6 的两处限制

```bash
# 限制一：accept_ra 默认 0，拿不到公网前缀
adb shell su -c 'echo 1 > /proc/sys/net/ipv6/conf/wlan0/accept_ra'
adb shell su -c 'echo 1 > /proc/sys/net/ipv6/conf/all/accept_ra'
# 重启 WiFi 触发一次 RA
adb shell su -c 'svc wifi disable; sleep 3; svc wifi enable'

# 限制二：策略路由把 IPv6 全判 unreachable
adb shell su -c 'ip -6 rule'      # 若见 "100: from all unreachable"
adb shell su -c 'ip -6 rule add priority 50 lookup wlan0'
```

两项**重启后都会丢**，必须靠常驻守护（阶段 4.4）。

### 4.3 Caddy + Let's Encrypt DNS-01

Caddy 官方二进制不含 cloudflare DNS 插件，需自己编译：

```bash
# 在任意 Linux 上
xcaddy build --with github.com/caddy-dns/cloudflare
adb push caddy /data/local/tmp/
adb shell su -c 'cp /data/local/tmp/caddy /data/local/droidvm/rootfs/usr/local/bin/ && chmod 755 ...'
```

Caddyfile 关键片段：

```caddyfile
{
    admin off
    servers { protocols h1 h2 }   # 禁用 HTTP/3，UDP:8080 常被占
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

**四个必须注意的点**

| 点 | 说明 |
|---|---|
| `resolvers 8.8.8.8` | 手机开着代理软件时本地 DNS 返回 fake-ip（198.18.x.x），Caddy 查 TXT 会拿到假地址，验证必失败 |
| `propagation_delay` | 不是 `dns_propagation_delay`，后者不存在，会导致启动报错 |
| 不要写 `auto_https off` | 会让 `tls internal` 也失效 |
| 出站 443 | 若被运营商拦，给 Caddy 传 `HTTPS_PROXY`；**入站 443 通常可用，别混为一谈** |

### 4.4 IPv6 守护进程

每 60 秒：纠正 `accept_ra`、补策略路由、Caddy 保活、把当前 IPv6 写入文件。

```bash
adb shell su -c 'setsid nohup /data/adb/ipv6-guard.sh >/dev/null 2>&1 &'
```

### 4.5 DDNS

家宽 IPv6 前缀会变。链路：

```
ipv6-guard.sh  →  /tmp/ipv6-current.txt  →  定时任务读文件  →  Cloudflare API 更新 AAAA
```

```python
# 每 10 分钟执行
RECORDS = ["ai.example.com", "ql.example.com"]
ipv6 = open("/tmp/ipv6-current.txt").read().strip()
for name in RECORDS:
    # GET /zones/{zone}/dns_records?type=AAAA&name={name}
    # 若与 ipv6 不同 → PATCH 更新
```

TTL 设为 60 秒加快生效。

---

## 阶段 5 · Cloudflare Tunnel

没有公网 IPv6，或不想暴露家庭 IP 时使用。

### 5.1 创建

```bash
cloudflared tunnel login
cloudflared tunnel create droidvm
cloudflared tunnel route dns droidvm dash.example.com
```

### 5.2 配置

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
  - service: http_status:404
```

### 5.3 固定边缘 IP（弱网关键优化）

手机上开代理软件时，DNS 返回 fake-ip 会让 cloudflared 连不上边缘节点。跳过 DNS 直接指 IP：

```bash
cloudflared --config /etc/cloudflared/config.yml --no-autoupdate tunnel \
  --protocol quic --ha-connections 2 --edge-ip-version 4 \
  --edge 198.41.192.57:7844 \
  --edge 198.41.200.233:7844 \
  --edge 198.41.192.167:7844 \
  run
```

**成功标志**：日志中出现至少两条

```
INF Registered tunnel connection connIndex=0 ... protocol=quic
INF Registered tunnel connection connIndex=1 ... protocol=quic
```

### 5.4 改配置必须重启

cloudflared 不支持热重载：

```bash
adb shell su -c 'pkill -f "cloudflared --config"; sleep 2'
adb shell su -c 'chroot $R /usr/bin/env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root /bin/sh -c "setsid nohup /etc/cloudflared/run-tunnel.sh >> /tmp/cf.log 2>&1 < /dev/null &"'
```

> 改 `ingress` 会断线数秒，操作前告知用户。

---

## 阶段 6 · 监控面板

单个 Python 文件，纯标准库，零依赖。完整源码见 `configs/dvm-dashboard.py`。

```bash
adb push dvm-dashboard.py /data/local/tmp/
adb shell su -c "mkdir -p $R/opt/dashboard && cp /data/local/tmp/dvm-dashboard.py $R/opt/dashboard/ && chmod 755 $R/opt/dashboard/dvm-dashboard.py"
adb shell su -c "chroot $R /usr/bin/env -i PATH=/usr/bin:/bin HOME=/root /bin/sh -c 'cd /opt/dashboard && setsid nohup python3 dvm-dashboard.py >> dash.log 2>&1 < /dev/null &'"
```

### 数据源对照

| 指标 | 路径 |
|---|---|
| 电量 / 电池温度 / 电压 / 健康度 | `/sys/class/power_supply/battery/{capacity,temp,voltage_now,health}` |
| CPU 使用率 | `/proc/stat` 两次采样差分 |
| 可用核心数 | `len(os.sched_getaffinity(0))`（**不是** `os.cpu_count()`） |
| 内存 | `/proc/meminfo` |
| 存储 | `os.statvfs("/")` |
| CPU 温度 | `/sys/class/thermal/thermal_zone*/{type,temp}` |
| 服务状态 | TCP connect `127.0.0.1:<port>` |
| 隧道状态 | 扫 `/proc/*/cmdline` 找 `cloudflared` |

### 三个数据陷阱（不处理会显示错误数据）

**1. `thermal_zone` 混着非温度节点**

| type | 实际内容 |
|---|---|
| `lmh-dcvs-00/01` | 限流阈值，恒为 75000 |
| `ibat-*` | 电流 |
| `vbat_*` | 电压 |
| `soc` | 占位 100 |

直接取全局最大值会永远显示「75℃」。必须按 `type` 过滤，只取 `cpu*` / `cpuss*` / `gold` / `silver` / `gpu`。

**2. `charge_now` / `charge_full` 单位不可靠**

某机型实测 `4746 / 3107`（当前 > 满充），除 1000 显示「5/3 mAh」。
只有 `charge_full_design`（µAh）可信；`current_now` 若为个位数说明是无效值，应丢弃。

**3. `batt_soh` 是千分比**

`840` 要 ÷10 得 `84.0%`。

### 前端陷阱

国产浏览器（如基于旧内核的 VIA）**不支持 flex `gap`**，会导致小字糊在一起。
统一用 `margin` 控制间距，`grid gap` 是支持的。

---

## 阶段 7 · 验收清单

逐项确认，全部通过才算完成：

```bash
# 1) 进程与服务
adb shell su -c 'netstat -tln | grep LISTEN'

# 2) chroot 可用
adb shell su -c "chroot /data/local/droidvm/rootfs /usr/bin/env -i PATH=/usr/bin:/bin /bin/true && echo chroot-ok"

# 3) IPv6 地址与路由
adb shell su -c 'ip -6 addr show wlan0 | grep "scope global"; ip -6 rule | head -3'

# 4) HTTPS 入口（外部访问，注意可能有 DNS 缓存）
curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" https://ai.example.com/

# 5) 隧道状态
adb shell su -c 'pgrep -f cloudflared; tail -5 /tmp/cf.log'

# 6) 面板数据
curl -s https://dash.example.com/api/metrics | head -c 300

# 7) 开机自启（最后做：重启手机后复验上面 1–6）
adb reboot
```

| 项 | 期望 |
|---|---|
| 端口 | 3065 / 5700 / 8765 / 443 均在 LISTEN |
| chroot | 输出 `chroot-ok` |
| IPv6 | 有 `scope global` 地址，`ip -6 rule` 中含 `priority 50` |
| HTTPS | 200，且耗时 < 1 秒（IPv6 直连） |
| 隧道 | 至少 2 条 `Registered tunnel connection` |
| 面板 | 返回 JSON，含 `battery` / `cpu` / `services` |
| 重启后 | 以上全部自动恢复 |

---

## 故障决策树

```
服务访问不了
├─ 局域网内也访问不了？
│  ├─ 端口没监听 → netstat 查；没起 → 看启动日志
│  └─ 端口在听但连不上 → SELinux 拦截？ su -c 'setenforce 0' 临时验证
└─ 局域网正常，公网不行
   ├─ 走域名（IPv6）
   │  ├─ 域名解析不出 AAAA → DDNS 没跑，或 /tmp/ipv6-current.txt 为空
   │  ├─ 解析对但超时 → ip -6 rule 少了 priority 50；或运营商封了入站
   │  └─ 443 握手失败 → Caddy 没起 / 证书没签下来（看 caddy.out）
   └─ 走隧道
      ├─ 日志无 Registered → DNS 解析到 fake-ip，改用 --edge 固定 IP
      ├─ 有 Registered 但 502 → ingress 里的 service 端口写错
      └─ 慢（>10s）→ 正常现象，隧道国内会绕境外边缘节点
```

---

## 与 v1（QEMU 方案）的关系

如果用户之前用过 `droidvm-module`（QEMU/TCG + Docker），务必注意**不要照搬**：

| v1 的概念 | v2 对应做法 |
|---|---|
| `VM_MEM` / `VM_SMP` | 不存在，服务按需吃内存 |
| `VM_PORTS="2222:22 5700:5700"` | 不存在，服务直接监听 |
| `mgmt.sh start/stop/ssh/docker` | 直接 `pkill` / `chroot ... sh` |
| Docker 容器 | chroot 内进程 |
| `service.sh`（模块） | `/data/adb/service.d/*.sh` |
| DVM Lite APK 状态页 | 网页面板 |
| qcow2 数据盘 | 不存在，数据直接在 rootfs |

迁移时 **rootfs 可以直接复用**（本来就是 Ubuntu 22.04），只需把服务数据搬进去，
然后删掉 `vm/*.qcow2`（约 2.3G）和 `qemu-system-aarch64`。

---

## 安全红线（必须向用户说明）

1. **青龙面板 = 远程命令执行**。不要裸露公网，至少强密码 + 二次验证，或加 IP 白名单。
2. Cloudflare Token 只授 `Zone.DNS.Edit`，不要用全局 Token。
3. 凭据文件（`caddy.env`、隧道 json）权限 `600`。
4. 手机长期联网注意散热与电池健康，建议限制充电上限。
5. 所有 `<...>` 占位符替换后，**不要把真实值提交回仓库**。
