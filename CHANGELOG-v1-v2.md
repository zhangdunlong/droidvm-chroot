# v1 → v2 差异对照

本文档记录从 **v1（`droidvm-module`，QEMU/TCG 软件模拟）** 到 **v2（本仓库，chroot 原生）** 的全部变化，
包括做了什么、为什么改、改完效果如何、迁移时要注意什么。

---

## 一句话总结

| | v1 | v2 |
|---|---|---|
| 思路 | 在手机里**模拟**一台电脑 | 让手机**直接当**那台电脑 |
| 手段 | chroot 里装 QEMU → 引导 Debian 12 虚拟机 → 虚拟机里跑 Docker | chroot 直接跑服务进程 |
| 代价 | CPU 逐条翻译指令，满载发热 | 原生执行，几乎没有额外开销 |

手机和 Linux 本来就是同一个内核。只要 root，再模拟一个 CPU 属于纯浪费 —— 这正是 v2 的出发点。

---

## 1. 架构层

### v1

```
Android
 └─ chroot (Ubuntu 22.04，仅作为 QEMU 宿主)
     └─ qemu-system-aarch64 -accel tcg,thread=multi
         └─ Debian 12 cloud-arm64 虚拟机
             ├─ Docker daemon
             │   ├─ 青龙容器
             │   ├─ agent2api 容器
             │   └─ AList 容器
             ├─ 1Panel (:10086)
             └─ OpenSSH (:22)
                 │ hostfwd 端口映射（用户态转发）
                 ▼
             Android 侧端口 2222 / 10086 / 5700 / 3065 / 5244
```

### v2

```
Android (同一内核，共用网络栈)
 └─ chroot (Ubuntu 22.04，直接跑服务)
     ├─ agent2api-server      :3065
     ├─ node (青龙)           :5700
     ├─ node (音箱桥)         :36592
     ├─ python3 (监控面板)    :8765
     ├─ caddy                 :80 / :443
     ├─ cloudflared           (出站隧道)
     └─ gost                  :8080
```

**去掉的四层**：QEMU 指令翻译 → 虚拟机引导 → Docker daemon → hostfwd 端口转发。
每去掉一层都少一次上下文切换，累积起来就是数量级的差别。

---

## 2. 资源占用

| 指标 | v1 实测 | v2 实测 | 说明 |
|---|---|---|---|
| 待机 CPU | 196%（TCG 线程常驻满载） | 0–5% | TCG 无论有没有负载都在翻译 |
| 机身温度 | 78.7°C | 32.5°C | 长期高温会触发降频、损伤电池 |
| 内存 | 固定 4G 分配给 VM（`VM_MEM=4096`） | 约 1.5G，按需 | v1 不管用不用都占着 |
| 磁盘 | rootfs 4.9G + qcow2 2.3G，qcow2 随使用膨胀 | 4.9G | v2 省掉整个虚拟机磁盘 |
| 续航 | 电池撑不到一天 | 正常一天以上 | 主因是 CPU 持续满载 |

> 测量方式：`top` 观察 qemu 进程 CPU%、`dumpsys battery` 读温度、`du -sh` 量磁盘。
> 两版跑的是同一套服务（青龙 + AI 网关 + 音箱桥）。

---

## 3. 性能

| 场景 | v1 | v2 | 倍数 |
|---|---|---|---|
| 青龙面板首屏 | 2–8 秒 | 0.12 秒 | ~20–60× |
| AI 网关本地响应 | 0.6–0.7 秒 | 0.05–0.09 秒 | ~8× |
| 首次可服务时间 | 20–40 分钟（旗舰）/ 1–2 小时（中端） | 5–10 分钟 | ~4–12× |
| 开机后服务就绪 | 60–180 秒 | 30–60 秒 | ~2–3× |

首次部署慢在何处（v1）：cloud-init 要在 TCG 软解下执行 `apt install docker.io`，几百个包逐个解压安装，
中端机实测 1–2 小时。v2 直接解压 rootfs，服务进程启动即用。

---

## 4. 端口与网络

| 项 | v1 | v2 |
|---|---|---|
| 端口暴露 | QEMU `hostfwd` 用户态转发（`VM_PORTS="2222:22 10086:10086 ..."`） | 服务直接监听，无转发 |
| SSH | 2222 → 访客 22 | 不需要（`chroot` 直接进，或 adb shell） |
| 外部访问 | 仅局域网（手册未提供公网方案） | **IPv6 直连 HTTPS + Cloudflare Tunnel 双路** |
| 认证 | 1Panel 入口路径 + 随机密码 | Caddy 自动 Let's Encrypt 证书 + 各服务自管 |
| IPv6 | 未支持 | 完整方案：accept_ra + 策略路由 + DDNS |

v2 新增的两个外网能力是本版本最大的功能增量：

- **IPv6 直连 + Caddy**：`ai.` / `ql.` / `v6.` 三个域名，0.1–0.3 秒响应
- **Cloudflare Tunnel**：`api.` / `dash.` / `files.`，兼容只有 IPv4 的网络

---

## 5. 服务形态

| 服务 | v1 | v2 |
|---|---|---|
| 青龙 | Docker 容器 `whyour/qinglong` | 直接跑 `node /ql/static/build/app.js` |
| AI 网关 | Docker 容器 `aimodcc/agent2api` | 直接跑 `./agent2api-server` |
| 面板 | 1Panel（:10086，需 Docker） | 自研单文件 `dvm-dashboard.py` |
| 进程管理 | Docker restart policy + systemd | `setsid nohup` + 端口探测幂等启动 |
| 升级方式 | `docker pull` 重新拉镜像 | 替换目录 / 重新下载二进制 |

**为什么可以不要 Docker**：Docker 的价值是隔离与镜像分发，
但手机上只跑固定的几个服务、且都由自己维护，隔离带来的收益小于它本身的资源开销和复杂度。
青龙和 agent2api 都是自包含的目录，直接跑完全等价。

---

## 6. 开机自启

| 项 | v1 | v2 |
|---|---|---|
| 载体 | Magisk 模块 `service.sh` + `customize.sh` | `/data/adb/service.d/*.sh`（不打包成模块） |
| 触发时机 | `BOOT_DELAY=45` 秒后 | `until bootanim stopped` + 30~40s |
| 启动内容 | 解压 rootfs → 建 qcow2 → 生成 cloud-init seed → 启动 QEMU → 等 VM 引导 → 等 Docker | 挂载 → 起进程（秒级） |
| 幂等性 | `mgmt.sh` 判断 pid | 每项启动前 `netstat` 查端口 |
| 停止 | `mgmt.sh stop` 杀 QEMU | 直接 `pkill` 对应进程 |

⚠️ **`service.d` 的坑**：Magisk 会执行目录下**所有**文件，不看后缀。
想禁用某个脚本必须**移出目录**，改成 `.bak` 无效（v1 时期踩过这个坑）。

---

## 7. 管理端

| 项 | v1 | v2 |
|---|---|---|
| App | `DVM Lite`（Java，APK） | 网页版监控面板（任何浏览器） |
| 状态页 | 查 QEMU 进程 / 端口转发 / 访客连通性 | 直读 `/proc` `/sys`：电量/温度/CPU/内存/存储 |
| 容器页 | `docker ps` | 端口探测 7 个服务 |
| 访问方式 | 手机装 APK | `https://dash.example.com` 或 `http://<内网IP>:8765` |

**为什么改成网页**：v1 的 App 是为「QEMU + Docker」架构写的，状态页查的是
`qemu` 进程号和 `hostfwd` 规则。切到 chroot 后这些概念全部不存在，App 显示会全红/空白，
改 App 等于重写检测层。网页版跨设备、免安装、改一下就更新，更适合这种长期演进的自用系统。

---

## 8. 迁移指南（v1 → v2）

如果你已经在用 v1，按以下步骤切换：

```bash
# 1) 停掉虚拟机（保留数据盘以防万一）
su -c 'sh /data/adb/modules/DroidVM/bin/mgmt.sh stop'

# 2) 把服务数据从 qcow2 里导出（青龙 data、agent2api 的 db 等）
#    挂载或 ssh 进 VM 拷贝，然后在 chroot 里对应放置
#    v2 的路径：/ql/data、/app

# 3) 复用原 rootfs（它本来就是 Ubuntu 22.04，可直接 chroot）
su -c 'ls /data/local/droidvm/rootfs/etc/os-release'   # 应显示 Ubuntu 22.04

# 4) 清理不再需要的 QEMU 组件（可选，省 20MB+）
su -c 'rm -f /data/local/droidvm/rootfs/usr/bin/qemu-system-aarch64'

# 5) 确认 v2 服务能独立启动后，删除虚拟机磁盘（省 2.3G）
#    !! 确认数据已迁移 !!
su -c 'rm -rf /data/local/droidvm/vm'

# 6) 卸载旧模块（数据盘已删，不会误伤）
#    Magisk → 模块 → DroidVM → 卸载

# 7) 按 README §3 部署 v2 自启脚本
```

迁移前后对比建议用监控面板观察：CPU 应从接近 200% 掉到个位数。

---

## 9. 保留与废弃清单

### 保留

- `/data/local/droidvm/rootfs` 目录结构（完全兼容）
- 服务端口：3065 / 5700 / 36592（与原映射一致，客户端配置不用改）
- 青龙数据目录 `/ql/data`
- Magisk root 环境

### 废弃

| 项 | 原因 |
|---|---|
| `settings.conf` 里的 `VM_MEM` / `VM_SMP` / `VM_PORTS` / `BOOT_DELAY` | 无虚拟机，无需分配资源、无需端口映射 |
| `vm/*.qcow2`、`seed.iso`、`AAVMF_VARS.fd` | 虚拟机磁盘与固件，v2 不存在虚拟机 |
| `bin/mgmt.sh` 的 `start/stop/ssh/docker` 子命令 | 改为直接管理进程 |
| `app/`（DVM Lite APK） | 检测逻辑失效，改网页面板 |
| 1Panel（:10086） | 依赖 Docker，v2 改用轻量自研面板 |
| qemu-system-aarch64 / AAVMF / genisoimage | 不再需要 |

---

## 10. 适用性说明

v2 并不在所有场景都优于 v1，客观列一下边界：

**v2 更合适的场景**

- 只跑自己维护的、无隔离需求的少数几个服务
- 在意续航、发热、响应速度
- 想有公网 HTTPS 入口

**v1 仍有价值的场景**

- 需要跑**别人的** Docker 镜像且不想处理依赖（镜像里自带完整环境）
- 需要在不同架构/发行版之间做隔离测试
- 需要多租户或强隔离（虽然手机上这点意义不大）

如果只是想让手机当服务器跑自建服务，v2 的收益是压倒性的。
