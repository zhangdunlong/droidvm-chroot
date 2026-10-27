#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mi-paiai 自动连接小米云。

背景：mi-paiai 的 node 进程起来后，只是 web 服务在监听（/api/status 返回
running=false, state=stopped）。必须显式 POST /api/start 才会真正连上小米云、
开始接收音箱消息。开机自启时若不调用，面板显示在线但音箱完全没反应。

由 boot.sh 在启动 node 之后调用。凭据通过环境变量传入，不落盘。
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = "http://127.0.0.1:36592"
USER = os.environ.get("MP_USER", "")
PASS = os.environ.get("MP_PASS", "")

op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor())


def call(method, path, body=None, timeout=15):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(BASE + path, data=data, method=method,
                                 headers={"Content-Type": "application/json"})
    try:
        with op.open(req, timeout=timeout) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
    except Exception as e:
        return 0, str(e)


# 1) 等 web 服务就绪（最多 30 秒）
for i in range(15):
    st, _ = call("GET", "/", timeout=5)
    if st == 200:
        break
    time.sleep(2)
else:
    print("[!] mi-paiai web 未就绪，跳过自动启动")
    sys.exit(1)

# 2) 登录
if not USER or not PASS:
    print("[!] 缺少 MP_USER / MP_PASS")
    sys.exit(1)

st, body = call("POST", "/api/login", {"username": USER, "password": PASS})
if st != 200:
    print("[!] 登录失败 HTTP %s: %s" % (st, body[:120]))
    sys.exit(1)

# 3) 已在运行就不重复启动
st, body = call("GET", "/api/status")
if '"running":true' in body.replace(" ", "") or '"running": true' in body:
    print("[=] 已在运行，跳过")
    sys.exit(0)

# 4) 启动连接
st, body = call("POST", "/api/start", timeout=30)
print("[+] /api/start -> HTTP %s %s" % (st, body[:120]))

# 5) 确认结果
for i in range(6):
    time.sleep(4)
    st, body = call("GET", "/api/status")
    if '"running":true' in body.replace(" ", "") or '"running": true' in body:
        print("[+] 已连接小米云（running=true）")
        sys.exit(0)

print("[!] 启动后仍未 running，请到面板查看")
sys.exit(2)
