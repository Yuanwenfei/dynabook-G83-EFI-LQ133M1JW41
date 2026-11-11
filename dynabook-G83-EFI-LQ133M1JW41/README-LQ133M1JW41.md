# EFI — dynabook G83/HS · 内屏 LQ133M1JW41 定制版

> 基于上游 [g83-11gen-hackintosh-tahoe-efi](https://github.com/xiananliu/g83-11gen-hackintosh-tahoe-efi) **1.3.2**（commit `112eca2`）+ 本机（内屏 Sharp LQ133M1JW41 13.3" FHD eDP）实测修复的完整 EFI。
> 2026-11-11 全项验收通过（内屏点亮 1080p 硬件加速 / 声音 / 麦克风 / 合盖不睡死）。

## 1. 机型与屏幕

| 项目 | 值 |
|------|-----|
| 机器 | Toshiba dynabook G83/HS（Tiger Lake U） |
| CPU | Intel Core i5-1135G7 |
| 核显 | Iris Xe 80EU（`0x9A49`），WhateverXe + Lilu |
| **内屏** | **Sharp LQ133M1JW41（13.3" 1920×1080 eDP）** |
| 声卡 | Realtek ALC257（`alcid=11`） |
| 系统 | macOS Tahoe 26.7.2（25G332） |
| SMBIOS | MacBookPro16,2（**三码为空**，安装前需自行生成，见第 4 节） |

## 2. 本 EFI 与上游 1.3.2 的差异

| 差异 | 说明 |
|------|------|
| config 三码为空 | 与上游一致（`SystemSerialNumber`/`SystemUUID` 为空 string，无 `MLB`/`ROM` 键），安装前用 GenSMBIOS 生成填入 |
| boot-args 16 项 | −`alcdelay=1000`（上游 1.3.2 移除，声卡正常注册）＋ 新增 `-wex-tgl-va-fallback -wex-tgl-va-sites=1 -wex-tgl-fix-memory-leak -wex-edp-fix-training` |
| 启用 kext 31 个 | 上游 1.3.2 移除了 ECEnabler |

完整 boot-args：

```
-allow3d -disablegfxfirmware -igfxdvmt -vi2c-force-polling alcid=11 TSC_sync_margin=0 -wex-cdclk-sanitize -wex-blfix -wex-dcoff -wex-hdmi-clock600 -wex-hdmi-scdc-write -tgldmic -wex-tgl-va-fallback -wex-tgl-va-sites=1 -wex-tgl-fix-memory-leak -wex-edp-fix-training
```

## 3. ⚠️ 关键：系统侧 eDP 驱动 patch（必装，否则内屏黑屏）

上游 EFI 单独使用时，LQ133M1JW41 面板在原生 `AppleIntelTGLGraphicsFramebuffer` 下 **eDP 训练失败 → 黑屏**。必须配合系统侧 patch（已打补丁的 TGL 图形驱动 + 重建的 AuxKC）：

| 文件 | sha256（前 8 位） |
|---|---|
| `/Library/KernelCollections/AuxiliaryKernelExtensions.kc`（patched） | `4e5656b3`（每次重建哈希不同，含 patched TGL 即可） |
| `/Library/Extensions/AppleIntelTGLGraphicsFramebuffer.kext`（patched） | `4f1e4b3b` |
| `/Library/Extensions/AppleIntelTGLGraphics.kext` + `AppleIntelTGLCompat.kext`（配套） | — |

> 本机当前系统已打好 patch（2026-11-11 验收）。**重装系统时需重打**——patched 驱动与恢复工具在 G 盘急救包 v2（`r.sh` 一键恢复）与 `_pull\` 归档。

## 4. 安装步骤（新机 / 重装系统）

1. **BIOS**：关闭 Secure Boot（其他默认）
2. **三码（必做）**：用 [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) 选择 `MacBookPro16,2` 生成，填入 config `PlatformInfo→Generic`：`SystemSerialNumber` / `MLB` / `SystemUUID`；`ROM` 填 12 位随机 MAC（data）
3. **引导**：把本 `EFI` 目录放到目标盘 ESP（`EFI/OC` 结构不变）
4. **装图形组件（必装）**：进系统后到 [WhateverXe Graphics Releases](https://github.com/b00t0x/WhateverXe-Graphics/releases) 下载最新 pkg 安装并重启
5. **装 TGL 驱动 patch（内屏必装）**：见上文第 3 节；或直接克隆本机已 patch 的 `/L/E` 三个 kext + `kmutil`（需 KDK）——最稳的是整盘备份恢复
6. **装麦克风组件（必装）**：[`TGLDmic-HAL-startup-fix.pkg`](https://github.com/xiananliu/TGLDmic-HAL-Fix/releases/download/hal-startup-fix-1/TGLDmic-HAL-startup-fix.pkg)（等内核就绪后再注册麦克风；装后重启，声音→输入选 *Internal Microphone (TGLDmic)*）
7. **防睡死（强烈建议）**：本机固件为 Intel Modern Standby，S3 深睡会挂死。采用禁睡眠三重保险（`pmset -a disablesleep 1 sleep 0 hibernatemode 0 standby 0 powernap 0` + launchd `caffeinate -ims` + 每 5 秒保活守护）。**禁忌：不要 `pmset displaysleepnow` 主动关屏**——会触发 WEX eDP `DBUF power up timeout` → 合盖重开黑屏

## 5. 验收记录（2026-11-11）

| 功能 | 状态 |
|------|------|
| 内屏 LQ133M1JW41 1080p + Iris Xe 硬件加速 | ✅ |
| 声音输出（内建扬声器，alcid=11） | ✅ |
| 麦克风输入（TGLDmic + HAL fix） | ✅ |
| 合盖/开盖（禁睡眠策略） | ✅ 不死机 |
| Wi-Fi / 蓝牙 / 有线 | ✅（上游组件） |
| 摄像头 | ✅（上游组件） |

**已知遗留**：GPU 高负载（开网页等）偶发 WindowServer 卡死（跨上游版本存在，11-09 原版时期即有 panic：WhateverXe + TGLFramebuffer 调用路径 page fault）。缓解方向：`-wex-tgl-hold-render-wake` 对照实验 / 向作者提 issue。

## 6. 目录结构（与上游一致）

```
EFI-LQ133M1JW41/
├── EFI/
│   ├── BOOT/BOOTx64.efi
│   └── OC/
│       ├── ACPI/  Drivers/  Kexts/  Resources/
│       ├── config.plist        ← iter-7（29dd2a8b…，16 项 boot-args + 三码）
│       └── OpenCore.efi
├── docs/                       ← 上游文档（TGLDmic 许可等）
├── README-LQ133M1JW41.md       ← 本文件
├── LICENSE  VERSION
```

## 7. 备份与恢复速查（本机）

| 资产 | 位置 |
|---|---|
| 系统侧点亮基线 | A 机 `~/hackintosh-backup-20261111-ITER7-132/`；B 机 `_pull\` + G 盘急救包 v2 |
| 内置 ESP 13 项旧稳定态 | `internal-esp-pre-iter7.tgz`（`de1d4210`） |
| U 盘 EFI 迭代备份 | `_pull\iter3-bin\usb-pre-iter7\` |
| 实验全记录 | `_pull\usb-efi-baseline-20261111\实验台账.md` |
