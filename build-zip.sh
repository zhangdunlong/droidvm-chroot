#!/bin/sh
# ============================================================
# 把 module/ 打包成 Magisk 可直接刷入的 zip
#
# 用法（在仓库根目录）:
#   sh build-zip.sh
# 产物:
#   DroidVM-Chroot-vX.Y.Z.zip
#
# 说明：
#   · 用 Python 的 zipfile 而不是系统 zip —— Windows / Linux 行为一致，
#     并且可以显式设置 update-binary 与 *.sh 的可执行位（zip 里是 external_attr）。
#   · 脚本文件必须以 LF 写入，否则刷入时会报 "bad interpreter"。
# ============================================================
set -e

cd "$(dirname "$0")"

VER=$(grep '^version=' module/module.prop | cut -d= -f2 | tr -d '\r')
[ -z "$VER" ] && VER="dev"
OUT="DroidVM-Chroot-${VER}.zip"

echo "打包 $OUT ..."

python3 - "$OUT" <<'PY'
import os
import sys
import zipfile

out = sys.argv[1]
SRC = "module"

# 这些文件需要可执行位
EXEC = {
    "META-INF/com/google/android/update-binary",
    "customize.sh",
    "service.sh",
    "uninstall.sh",
    "bin/mgmt.sh",
    "scripts/boot.sh",
}

count = 0
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for root, dirs, files in os.walk(SRC):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for name in sorted(files):
            full = os.path.join(root, name)
            # zip 内路径以 module 内容为根（Magisk 要求）
            arc = os.path.relpath(full, SRC).replace("\\", "/")
            zi = zipfile.ZipInfo(arc, date_time=(2026, 1, 1, 0, 0, 0))
            zi.compress_type = zipfile.ZIP_DEFLATED
            mode = 0o755 if arc in EXEC else 0o644
            zi.external_attr = (0o100000 | mode) << 16
            with open(full, "rb") as f:
                z.writestr(zi, f.read())
            count += 1

print("  %d 个文件" % count)
PY

echo "完成: $(pwd)/$OUT"
echo "刷入方式: Magisk → 模块 → 从本地安装 → 选该 zip → 重启"
