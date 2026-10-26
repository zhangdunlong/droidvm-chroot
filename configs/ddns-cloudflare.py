#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
cron: */10 * * * *
new Env('DDNS 同步')

把手机的当前 IPv6 地址同步到 Cloudflare 的多条 AAAA 记录。

数据来源：/tmp/ipv6-current.txt
由 Android 层的 ipv6-guard.sh 每 60 秒检测地址变化后写入。
（chroot 内看到的 /tmp 就是宿主 rootfs 的 /tmp）

环境变量：
  CF_API_TOKEN   Cloudflare API Token，权限仅需 Zone.DNS.Edit
  CF_ZONE_ID     Cloudflare Zone ID（域名概览页右下角）
  DDNS_RECORDS   要同步的记录，逗号分隔，如 ai.example.com,ql.example.com
  DDNS_TTL       记录 TTL 秒数，默认 60

用法（青龙环境变量配好后，直接作为定时任务运行）：
  python3 ddns-cloudflare.py
"""

import os
import sys

import requests

API = "https://api.cloudflare.com/client/v4"
IPV6_FILE = "/tmp/ipv6-current.txt"
TIMEOUT = 20


def env(key, default=""):
    return (os.environ.get(key) or default).strip()


def read_ipv6():
    try:
        with open(IPV6_FILE, "r", encoding="utf-8") as f:
            return f.read().strip()
    except FileNotFoundError:
        print("❌ 找不到 %s —— IPv6 守护进程是否在跑？" % IPV6_FILE)
        return ""
    except Exception as e:
        print("❌ 读取 %s 失败：%s" % (IPV6_FILE, e))
        return ""


def cf_request(method, path, token, **kwargs):
    headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
    }
    url = API + path
    try:
        r = requests.request(method, url, headers=headers, timeout=TIMEOUT, **kwargs)
        return r.json()
    except Exception as e:
        return {"success": False, "errors": [{"message": str(e)}]}


def sync_one(name, ipv6, zone_id, token, ttl):
    """返回 (状态, 说明)：status ∈ ok / skip / fail"""
    d = cf_request(
        "GET",
        "/zones/%s/dns_records?type=AAAA&name=%s" % (zone_id, name),
        token,
    )
    if not d.get("success"):
        return "fail", "查询被拒：%s" % d.get("errors")

    records = d.get("result") or []

    if not records:
        # 记录不存在则创建
        d2 = cf_request(
            "POST",
            "/zones/%s/dns_records" % zone_id,
            token,
            json={"type": "AAAA", "name": name, "content": ipv6, "ttl": ttl, "proxied": False},
        )
        if d2.get("success"):
            return "ok", "已新建 → %s" % ipv6
        return "fail", "新建失败：%s" % d2.get("errors")

    changed = 0
    for rec in records:
        if rec.get("content") == ipv6 and rec.get("ttl") == ttl:
            continue
        d3 = cf_request(
            "PATCH",
            "/zones/%s/dns_records/%s" % (zone_id, rec["id"]),
            token,
            json={"content": ipv6, "ttl": ttl},
        )
        if d3.get("success"):
            changed += 1
        else:
            return "fail", "更新失败：%s" % d3.get("errors")

    if changed:
        return "ok", "已更新 %d 条 → %s" % (changed, ipv6)
    return "skip", "无变化（%s）" % ipv6


def main():
    token = env("CF_API_TOKEN")
    zone_id = env("CF_ZONE_ID")
    raw_records = env("DDNS_RECORDS")
    ttl = int(env("DDNS_TTL", "60") or 60)

    if not token or not zone_id or not raw_records:
        print("❌ 缺少环境变量：需要 CF_API_TOKEN / CF_ZONE_ID / DDNS_RECORDS")
        return 1

    records = [x.strip() for x in raw_records.replace("\n", ",").split(",") if x.strip()]
    ipv6 = read_ipv6()
    if not ipv6:
        return 1

    print("DDNS 同步 · IPv6 = %s · 共 %d 条记录" % (ipv6, len(records)))

    ok = skip = fail = 0
    for name in records:
        status, msg = sync_one(name, ipv6, zone_id, token, ttl)
        icon = {"ok": "✅", "skip": "➖", "fail": "❌"}[status]
        print("  %-28s %s %s" % (name, icon, msg))
        if status == "ok":
            ok += 1
        elif status == "skip":
            skip += 1
        else:
            fail += 1

    print("\n完成：更新 %d / 无变化 %d / 失败 %d" % (ok, skip, fail))
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
