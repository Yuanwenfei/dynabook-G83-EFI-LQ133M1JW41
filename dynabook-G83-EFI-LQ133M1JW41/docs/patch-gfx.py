#!/usr/bin/env python3
"""Windows / macOS 通用离线补丁器：dynabook G83/HS eDP computeLaneCount 一字节补丁。

模式签名（双条件防误匹配，跨 Tahoe 26.x / Sequoia 15.x 通用）：
    41 c7 00 01 00 00 00    mov dword ptr [r8], 1    <- 补丁目标（+3 处 01 -> 02）
    b3 01 89 d8             mov bl,1 ; mov eax,ebx   <- 后随签名

用法：
    python3 patch-gfx.py <file>             # 定位 + 补丁（幂等，已打过自动跳过）
    python3 patch-gfx.py <file> --dry-run   # 只定位报告，不写入

处理对象（从 Mac 拷来，改完拷回原路径重启生效）：
    AppleIntelTGLGraphicsFramebuffer.kext/Contents/MacOS/AppleIntelTGLGraphicsFramebuffer
    /Library/KernelCollections/AuxiliaryKernelExtensions.kc

原理与取证详见同目录 eDP-link-training-postmortem.md。
"""
import sys
import os
import shutil
import argparse

PRE_HEAD = bytes.fromhex("41c700")      # mov dword ptr [r8], xx
POST = bytes.fromhex("b30189d8")        # mov bl,1 ; mov eax,ebx
PATCH_IDX = 3                           # 目标字节在 PRE_HEAD 后 index 3（41 c7 00 [xx] 00 00 00）


def find_hits(data: bytes):
    """命中 xx=01（未打）与 xx=02（已打）两种状态，保证幂等。"""
    hits, i = [], 0
    while True:
        i = data.find(PRE_HEAD, i)
        if i < 0:
            break
        seg = data[i:i + 11]
        if len(seg) == 11 and seg[3] in (1, 2) and seg[4:7] == b"\x00\x00\x00" and seg[7:11] == POST:
            hits.append(i)
        i += 1
    return hits


def main() -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

    ap = argparse.ArgumentParser(description="eDP computeLaneCount 一字节补丁（模式签名定位）")
    ap.add_argument("file", help="驱动本体或 AuxiliaryKernelExtensions.kc")
    ap.add_argument("--dry-run", action="store_true", help="只定位报告，不写入")
    a = ap.parse_args()

    if not os.path.isfile(a.file):
        print(f"ERROR: 文件不存在: {a.file}")
        return 1

    data = open(a.file, "rb").read()
    print(f"文件: {a.file} ({len(data)} 字节)")

    hits = find_hits(data)
    if not hits:
        print("未找到补丁模式 —— 此版本驱动布局可能不同，请人工反汇编确认")
        return 2

    states = [(hex(o), data[o + PATCH_IDX]) for o in hits]
    print(f"命中 {len(hits)} 处: {states}")

    if all(s == 2 for _, s in states):
        print("全部已是 2 lane（02），跳过（幂等）")
        return 0
    if any(s not in (1, 2) for _, s in states):
        print("命中字节异常（非 01/02），拒绝写入，请人工检查")
        return 3
    if a.dry_run:
        print("[dry-run] 将把 01 改为 02，未写入")
        return 0

    bak = a.file + ".bak"
    if not os.path.exists(bak):
        shutil.copy2(a.file, bak)
        print(f"备份: {bak}")

    nd = bytearray(data)
    for o in hits:
        if nd[o + PATCH_IDX] == 1:
            nd[o + PATCH_IDX] = 2
    with open(a.file, "wb") as f:
        f.write(bytes(nd))

    chk = open(a.file, "rb").read()
    ok = all(chk[o + PATCH_IDX] == 2 for o in hits)
    print(f"写入与回读验证: {'OK' if ok else 'FAIL'}")
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())
