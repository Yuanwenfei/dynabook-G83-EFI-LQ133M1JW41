# dynabook G83/HS · macOS Tahoe EFI（内屏 JDI LQ133M1JW41）

东芝 dynabook G83/HS（Tiger Lake，i5-1135G7 / Iris Xe 80EU）的 OpenCore 黑苹果 EFI，针对 **JDI LQ133M1JW41**（13.3" 1920×1080 eDP）面板专门适配并实测验收。

基于上游 [g83-11gen-hackintosh-tahoe-efi](https://github.com/xiananliu/g83-11gen-hackintosh-tahoe-efi) **1.3.2**（OpenCore 1.0.8，WhateverXe + Lilu 注入 Iris Xe）。

> 📖 **完整安装与适配说明见 [dynabook-G83-EFI-LQ133M1JW41/README-LQ133M1JW41.md](dynabook-G83-EFI-LQ133M1JW41/README-LQ133M1JW41.md)**

## 实测状态（macOS Tahoe 26.7.2 / 25G332）

| 功能 | 状态 |
|------|------|
| 内屏 LQ133M1JW41 1080p + Iris Xe 硬件加速 | ✅ |
| 声音输出（ALC257，`alcid=11`） | ✅ |
| 麦克风（TGLDmic + HAL 修正版） | ✅ |
| 合盖/开盖（禁睡眠策略） | ✅ 不死机 |
| Wi-Fi / 蓝牙 / 有线网络 | ✅ |
| 摄像头 | ✅ |
| H.264/HEVC 硬解、HDMI 4K 输出 | ✅ |

## ⚠️ 三个必装组件（缺一不可点亮完整功能）

1. **系统侧 eDP 驱动 patch**：原生 `AppleIntelTGLGraphicsFramebuffer` 下 LQ133M1JW41 的 eDP 训练失败会黑屏，需搭配打补丁的 TGL 图形驱动 + 重建 AuxKC（细节见详细 README 第 3 节）
2. **WhateverXe 运行组件**：进系统后安装 [WhateverXe Graphics releases](https://github.com/b00t0x/WhateverXe-Graphics/releases) 最新 pkg 并重启
3. **TGLDmic HAL 修正版**：[TGLDmic-HAL-startup-fix.pkg](https://github.com/xiananliu/TGLDmic-HAL-Fix/releases/download/hal-startup-fix-1/TGLDmic-HAL-startup-fix.pkg)（等内核就绪后再注册麦克风；装后重启）

## 防睡死（本机固件限制）

本机为 Intel Modern Standby（`PEPD`/`INT33A1`），S3 深睡会挂死。建议禁睡眠三重保险（`disablesleep` + `caffeinate -ims` + 守护脚本）。**禁忌：不要 `pmset displaysleepnow` 主动关屏**——会触发 WEX eDP `DBUF power up timeout` 导致合盖重开黑屏。详细方案见详细 README 第 4 节。

## 三码

`config.plist` 的 `PlatformInfo→Generic` 三码为空，使用前请用 [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) 选择 `MacBookPro16,2` 生成并填入 `SystemSerialNumber / MLB / SystemUUID`，`ROM` 填 12 位随机 MAC。

## 已知遗留

GPU 高负载（开网页等）偶发 WindowServer 卡死——跨上游版本存在（原版参数时期即有 panic：WhateverXe + TGLFramebuffer 调用路径 page fault），非本 EFI 引入。缓解方向：`-wex-tgl-hold-render-wake` 对照实验 / 向作者提 issue。

## 致谢

- 上游 EFI / 文档：[xiananliu/g83-11gen-hackintosh-tahoe-efi](https://github.com/xiananliu/g83-11gen-hackintosh-tahoe-efi)
- 图形驱动：[b00t0x/WhateverXe-Graphics](https://github.com/b00t0x/WhateverXe-Graphics)
- 麦克风：[labrouss/TGLDmic](https://github.com/labrouss/TGLDmic) + [xiananliu/TGLDmic-HAL-Fix](https://github.com/xiananliu/TGLDmic-HAL-Fix)
- 防睡死方案参考：[Kansamu216/dynabook-g83-macos-tahoe](https://github.com/Kansamu216/dynabook-g83-macos-tahoe) 的 POWER.md
- OpenCore / kext 项目版权归各自上游（见仓库内 LICENSE 与 docs/）
