#!/bin/bash
# repatch.sh — dynabook G83/HS eDP computeLaneCount 双版本自适应补丁
# 适用：macOS Tahoe 26.x / Sequoia 15.x（模式签名定位，不依赖固定偏移）
#
# 原理：AppleIntelTGLGraphicsFramebuffer 的 computeLaneCount() fallback 分支
#   mov dword ptr [r8], 1  (41 c7 00 01 00 00 00)
#   mov bl, 1 ; mov eax, ebx  (b3 01 89 d8)   ← 后随签名，排除误匹配
# 把其中的 01 改成 02（fallback 2 lane），使驱动不再把固件预训练好的
# 2-lane eDP 链路降级改写，Phase 1 训练即通过（详见 docs/eDP-link-training-postmortem.md）。
#
# 用法：
#   sudo bash repatch.sh             # 定位 + 补丁（幂等，已打过自动跳过）
#   sudo bash repatch.sh --dry-run   # 只定位报告，不写入
#   sudo bash repatch.sh --reboot    # 补丁成功后自动重启
set -u

DRY=0; REBOOT=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --reboot)  REBOOT=1 ;;
    *) echo "未知参数: $a"; exit 1 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0"; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: 需要 python3"; exit 1; }

echo "== repatch: macOS $(sw_vers -productVersion) ($(sw_vers -buildID)) =="

SLE_KEXT="/System/Library/Extensions/AppleIntelTGLGraphicsFramebuffer.kext"
LE_KEXT="/Library/Extensions/AppleIntelTGLGraphicsFramebuffer.kext"
AUXKC="/Library/KernelCollections/AuxiliaryKernelExtensions.kc"

# 0) /L/E 没有驱动副本时，从密封卷拷一份（patch 的工作副本）
if [ ! -f "$LE_KEXT/Contents/MacOS/AppleIntelTGLGraphicsFramebuffer" ]; then
  if [ -f "$SLE_KEXT/Contents/MacOS/AppleIntelTGLGraphicsFramebuffer" ]; then
    echo "== /L/E 无驱动副本，从密封卷拷贝 =="
    cp -R "$SLE_KEXT" "$LE_KEXT" || { echo "ERROR: 拷贝失败"; exit 1; }
    chown -R root:wheel "$LE_KEXT"
  else
    echo "ERROR: 密封卷里也找不到 TGL framebuffer kext"; exit 1
  fi
fi

TS=$(date +%Y%m%d-%H%M%S)
BK="$HOME/gfx-backup-$TS"
mkdir -p "$BK"

export PATCH_DRY=$DRY PATCH_BK="$BK"

RESULT=0
for F in "$LE_KEXT/Contents/MacOS/AppleIntelTGLGraphicsFramebuffer" "$AUXKC"; do
  echo "-- 处理: $F"
  python3 - "$F" <<'PYEOF'
import sys, os, shutil

path = sys.argv[1]
dry  = os.environ.get("PATCH_DRY") == "1"
bk   = os.environ["PATCH_BK"]

data = open(path, "rb").read()
PRE_HEAD = bytes.fromhex("41c700")       # mov dword ptr [r8], xx
POST = bytes.fromhex("b30189d8")         # mov bl,1 ; mov eax,ebx

hits, i = [], 0
while True:
    i = data.find(PRE_HEAD, i)
    if i < 0:
        break
    seg = data[i:i+11]
    if len(seg) == 11 and seg[3] in (1, 2) and seg[4:7] == b"\x00\x00\x00" and seg[7:11] == POST:
        hits.append(i)
    i += 1

if not hits:
    print(f"   未找到补丁模式 —— 此版本驱动布局不同，需人工分析（offsets 打印到 stderr 略）")
    sys.exit(2)

states = [(hex(o), data[o+3]) for o in hits]   # 01 在 PRE 模式的 index 3
if all(s == 2 for _, s in states):
    print(f"   已是 2 lane（{states}），跳过（幂等）")
    sys.exit(0)
if any(s not in (1, 2) for _, s in states):
    print(f"   命中字节异常（{states}），拒绝写入，请人工检查")
    sys.exit(3)

if dry:
    print(f"   [dry-run] 将 patch {states}")
    sys.exit(0)

dst = os.path.join(bk, os.path.basename(path))
if not os.path.exists(dst):
    shutil.copy2(path, dst)

nd = bytearray(data)
for o in hits:
    if nd[o+3] == 1:
        nd[o+3] = 2
open(path, "wb").write(bytes(nd))

# 回读验证
chk = open(path, "rb").read()
ok = all(chk[o+3] == 2 for o in hits)
print(f"   PATCHED {[(hex(o), '1->2') for o in hits]}，回读 {'OK' if ok else 'FAIL'}（备份: {dst}）")
sys.exit(0 if ok else 3)
PYEOF
  RC=$?
  if [ $RC -ne 0 ]; then RESULT=$RC; fi
done

echo "== 完成（result=$RESULT）=="
if [ $RESULT -eq 0 ]; then
  echo "提示：AuxKC 已直接改写，重启生效。系统更新后 /L/E 与 AuxKC 会被覆盖，重跑本脚本即可。"
  [ $REBOOT -eq 1 ] && { echo "5 秒后重启…"; sleep 5; reboot; }
else
  echo "存在未解决项：未找到模式(2)或字节异常(3)。请勿重启，先人工核对（可发 dmesg/log 到 issue）。"
fi
exit $RESULT
