# Sharp LQ133M1JW41 内屏点亮复盘：eDP 链路训练故障的全链路取证

> 机型：Toshiba dynabook G83/HS（Tiger Lake-U i5-1135G7，Iris Xe 80EU `0x9A49`）
> 面板：**Sharp LQ133M1JW41**（13.3" 1920×1080 eDP，DPCD 报 DP 1.4）
> 系统：macOS Tahoe 26.7.2（25G332）· OpenCore 1.0.8 · WhateverXe 0.8.0/1.3.2 + Lilu
> 结论先行：**macOS 的 TGL 图形驱动把固件已建立好的 2-lane eDP 链路改写为 1 lane，导致 Phase 1 时钟恢复（CR）数学上不可能通过；在 `AppleIntelPort::computeLaneCount` 的 fallback 分支改一个字节（1→2）后一次点亮。**

---

## 1. 故障现象

- 内屏完全黑屏（无背光、无 logo），外接 HDMI 正常；
- 内核日志反复出现：

```
Phase 1 of link training failed
e00002bc
```

- 同一块屏在 Windows / Linux i915 下均正常点亮 → 排除硬件。

## 2. eDP 链路训练 101（读本文需要的最小背景）

DP/eDP 链路建立分两个阶段，全部通过 AUX 通道读写 DPCD 寄存器完成：

| 阶段 | 做什么 | 关键 DPCD |
|---|---|---|
| 能力探测 | 读 sink 版本/lane 数/速率表 | `0x000` REV、`0x001` MAX_LINK_RATE、`0x002` MAX_LANE_COUNT |
| **Phase 1：时钟恢复（CR）** | source 发 TPS1 时钟图样，sink 逐 lane 反馈是否锁定 | 写 `0x100` LINK_BW、`0x101` LANE_COUNT、`0x102` TRAINING_PATTERN_SET、`0x103–0x106` 各 lane 电压摆动；读 `0x202` LANE0_1_STATUS（bit0/bit4 = lane0/lane1 的 **CR_DONE**）、`0x204` ALIGN、`0x206–0x207` ADJUST_REQ |
| Phase 2：信道均衡（EQ） | 换 TPS2/TPS3，微调摆动/预加重 | `0x202` 的 EQ_DONE + SYMBOL_LOCKED 位 |

带宽算术（8b/10b）：`有效带宽 = lane 数 × 符号速率 × 0.8`。
1920×1080@60 24bpp 需要 ≈ **3.32 Gbps**（i915 实测口径 `required 415500 / available 432000`，即含 blanking 的链路口径）。

## 3. 证据链一：WhateverXe 静态逆向（先搞清手里有什么）

对 `WhateverXe.kext`（0.8.0，1,850,928 B，sha256 `657b7eec…`）做字符串提取 + Mach-O 符号扫描（2056 个符号）：

**① 被它 hook 的 Apple 原生训练函数**（`FramebufferTrainingNative::entries`，`__DATA,__const @0x187390`，32 字节步长 × 12 项，每项首 8 字节是指向 `__cstring` 的符号名指针）：

```
AppleIntelFramebufferController::doLinkTrainingBegin / doLinkTraining / doLinkTrainingEnd
AppleIntelDisplayPath::{allocatePath, freePath, getFirstPathByPort}
AppleIntelFramebuffer::{addDisplayPath, allocateDisplayPathResources}
AppleIntelFramebufferController::stop
AppleIntelPort::{linkTraining, getPortByDDIE}
```

**表中没有 `computeLaneCount` / `setupOptimalLaneCount`** —— 即 WEX 的 hook 注册表**不改 Apple 的 lane 数计算**，lane 数是 Apple 自己算的。

**② "训练租约（lease）"与"沿用固件路径"机制存在但没有开关**：

```
XE::tglPrepareTrainingLease / tglTrainingLeaseForDDIE / tglObserveTrainingLease
XE::tglAdoptingLease()                                    ← TGL 侧"接管/沿用"入口
Display::Power::NativeBridge::adoptBootPath(ulong,uint,uint) ← 通用"沿用固件已建立路径"
```

对应运行时日志串（可观测）：

```
@ TGL330 resources native-enter ddi=%u adopt=%u
@ Display13 native handoff status=%u writes=%u restored=%u
```

**③ 70 个 `-wex-*` 参数**，其中 eDP 训练类 9 个（`-wex-edp-force-pe1/-vs1/-tps2`、`-wex-edp-clamp-pe`、`-wex-edp-ssc-107-on/off`、`-wex-edp-d4b`、`-wex-d4a`、`-wex-dcoff`），另有观测开关 `-wex-display-trace`、`-wex-tc-aux`、`-wex-tc-bootstrap`（对应 `WhateverXeDPCDFirst/Live/Count` 属性）。

**④ 强制参数的全局量拆成三组**：`tglForcePE1Enabled / tglForcePE1PHYCount / tglForcePE1LaneSetCount`（VS1、TPS2 同构）——"参数到底改不改 lane 数"当时无法静态判定，只能实验。

## 4. 证据链二：DPCD 事务日志解码（让面板自己说话）

用 `-wex-tc-aux -wex-tc-bootstrap` 从 IORegistry 导出 `WhateverXeDPCDFirst/Live`，解码出 **80 字节定长记录**（v1 曾误判为不可解，v2 用 seq 连续性自证）：

```
+0x00 u64 时间戳   +0x08 u64 调用方指针   +0x10 u32 seq(连续)
+0x14 u32 DPCD 地址 +0x18 u32 长度(1/2/4/6/16) +0x1C u32 方向(1写/0读)
+0x20 u32 返回态(0进入/1返回)  +0x28 u32 实传字节数
+0x30 u8[16] 数据副本
```

274 + 128 条记录，地址分布全部落在 DP 训练寄存器区（`0x100–0x10A`、`0x200–0x207`）与能力区（`0x000–0x010`）。

**读出的面板能力**：

| DPCD | 值 | 含义 |
|---|---|---|
| `0x000` | `0x14` | DP **1.4**（推翻"eDP 1.2 老面板"的先行假设） |
| `0x001` | `0x00` | 看似异常，实为 **eDP 1.4 扩展速率表**用法（速率在 `0x010–0x01F`，i915 枚举出 8 个 sink rates 证实） |
| `0x002` | `0xC2` | **2 lane** + 增强帧 |

**读出的失败训练时间线**（5 轮全同）：

```
读 0x100/0x101 → 00 82        ← 固件留下的状态：2 lane + 增强帧（能用的配置！）
写 0x100/0x101 → 0A 81        ← 驱动改写：HBR + 1 lane（0x81 = 1 lane + EF）
写 0x102       → 21           ← TPS1
写 0x103–0x106 → 00…→ 01…    ← 摆动等级 1
读 0x202       → 00 00 80 01 …  ← lane0/lane1 的 CR_DONE 全是 0（5 轮）
写 0x102       → 00           ← 放弃
```

关键事实有二：**驱动把 2 lane 降成 1 lane**；**CR 阶段就全军覆没**（不是"lane0 能锁、lane1 不行"的分歧问题）。

## 5. 证据链三：参数层实验（排除法）

| 迭代 | 改动 | 结果 | 判定 |
|---|---|---|---|
| iter-1a | +`-wex-edp-force-pe1 -wex-edp-force-vs1 -wex-display-trace` | `-wex-display-trace` 无任何输出；Phase 1 失败 ×4（`e00002bc`）；但 AGDP 在训练前读 `0x101=0x82`（**AGDP 认为是 2 lane**，与驱动的 1 lane 分歧同场实锤） | 有歧义：参数没生效 vs 生效仍败 |
| iter-1b | 再 +`-wex-tc-aux -wex-tc-bootstrap` 复采 | 事务日志显示：速率档从 `0x0A`(HBR) 变 `0x14`(HBR2)，但 **lane 仍是 `0x81`(1 lane)**；HBR2 下 1 lane = 4.32 Gbps ≥ 需求 4.155 Gbps 仍失败 → 连"带宽不足"这条假设也被排除 | **force 参数只改速率不改 lane → 参数层关闭** |

方法论要点：**判定四查**（trace 的 LaneSetCount、DPCD 的 `0x101` 写值、训练结果码、人眼+截图）在每轮固定采集，避免"无变化"无法归因。

## 6. 证据链四：Linux i915 三系统对照（决定性）

Ubuntu Live（不装机）`modprobe i915 modeset=1 force_probe=9a49`，经 `/dev/drm_dp_aux0` 直读 DPCD：

**同一块屏、同一份 VBT（前 8607 字节逐字节相同）、同一份 EDID、同一组 DPCD 能力值**下：

| | macOS（WEX） | Linux i915 |
|---|---|---|
| lane / 速率 | **1 lane** @ HBR（后改 HBR2） | **2 lane** @ 216 MHz（HBR） |
| `0x101` | 写 `0x81`（覆盖固件的 `0x82`） | **不写**（保留 `0x82`） |
| 训练 | TPS1 → `0x202=0x00`（CR 失败 ×5） | TPS1 → **CR OK** → TPS3 → **EQ done**（`0x202=0x77` 活跃 / `0x11` 空闲，即两条 lane 的 CR_DONE 位） |
| 结果 | 黑屏 | 1920×1080 正常 |

i915 日志还给出带宽口径：`required 415500 / available 432000`（2 lane）。**1 lane @ HBR 只有 216000，连一半都不到——1 lane 在数学上带不动 1080p60**；而 1 lane @ HBR2（iter-1b 实测）虽带宽够也失败，说明 CR 失败与 lane/PHY 编程方式直接相关，不只是带宽。

这次对照**一次性排除**了：面板/排线/背光硬件、VBT/ACPI 差异、SSC、TPS2、"面板不报速率"、以及"lane0 能锁 lane1 不能"的旧叙事。

## 7. 根因

> **TGL 驱动的 lane 数计算函数 `AppleIntelPort::computeLaneCount()` 在本面板上走入 fallback 分支，返回 1 lane；驱动随后把固件已建立好的 2-lane 链路（DPCD `0x101=0x82`）改写为 1 lane，CR 因 PHY 以 1 lane 编程而失败，训练整体失败 → 内屏黑屏。**
>
> 面板自报能力（2 lane，DP 1.4 + 扩展速率表）与固件预训练状态完全正常——问题纯在 Apple 驱动的计算分支，与 WhateverXe 的 hook 无关（它根本没 hook 这个函数）。

## 8. 修复：一个字节的二进制补丁（iter-3）

**定位**：`AppleIntelTGLGraphicsFramebuffer` 符号表 → `AppleIntelPort::computeLaneCount @ 0x1fc22`。
**反汇编**：函数末尾按带宽阈值分支，fallback 分支：

```
0x1fd74: 41 c7 00 01 00 00 00    mov dword ptr [r8], 1   ← 兜底 1 lane
```

**改动**：`0x1fd77` 一个字节 `01` → `02`（fallback 兜底变 2 lane；其余分支不动）。

**落地方式（Tahoe 特殊坑）**：macOS 26 的 `kmutil create/install` 重建 AuxKC 需要 KDK（build 25G332 无现成 KDK，`--update-boot` 已废弃）→ 改为**直接对已生成的 `AuxiliaryKernelExtensions.kc` 内嵌字节做同偏移 patch**（文件偏移 `0x18fd77`），重启未被签名校验阻止。

**跨版本定位：字节模式签名（推荐，勿硬编码偏移）**——补丁点的可靠特征是：

```
41 c7 00 01 00 00 00        mov dword ptr [r8], 1
b3 01 89 d8                 mov bl, 1 ; mov eax, ebx      ← 后随签名，用于排除同字节串的误匹配
```

在驱动本体与 AuxKC 中各搜一次该模式（`41 c7 00 01 00 00 00` 且后随 `b3 01 89 d8`），把其中的 `01` 改 `02`；已打过（02）则跳过。幂等脚本应：定位 → 备份 → 补丁 → 复验。

| 产物 | sha256 前 8 位 |
|---|---|
| patched 驱动 `/L/E/AppleIntelTGLGraphicsFramebuffer` | `4f1e4b3b` |
| patched AuxKC | `bd461961`（后续系统自动重建为 `4e5656b3`，等价） |
| 原始备份（驱动 `.orig` / AuxKC `.orig`） | `115a4616` / `12445c0f` |

## 9. 为什么"连重训都不需要"

patch 后的观测结果：

```
DPCD 事务日志：不再出现任何 0x101 写入（驱动不再降档）
0x100/0x101 保持 00 82（固件预训练状态原样保留）
dmesg：Phase 1 / e00002bc 计数 = 0
system_profiler：1920×1080@60、30-Bit ARGB2101010、Internal、Online、Main Display
```

机制：`computeLaneCount` 返回 2 后，**驱动的 lane 认知与固件/AGDP/面板三方一致**，驱动判定"链路已是目标状态"，走的是等价于"沿用固件链路"的路径（对应 WEX 里存在但未暴露开关的 `tglAdoptingLease` / `adoptBootPath`）。**这正是修复方向排序里成本最低的一条**——不是"让训练通过"，而是"让驱动别去动一条已经好的链路"。

## 10. 最终配方与验收

| 层 | 配置 |
|---|---|
| EFI（OC 1.0.8 + WEX 1.3.2，kext 31 个） | boot-args 16 项：`-allow3d -disablegfxfirmware -igfxdvmt -vi2c-force-polling alcid=11 TSC_sync_margin=0 -wex-cdclk-sanitize -wex-blfix -wex-dcoff -wex-hdmi-clock600 -wex-hdmi-scdc-write -tgldmic -wex-tgl-va-fallback -wex-tgl-va-sites=1 -wex-tgl-fix-memory-leak -wex-edp-fix-training` |
| 系统侧 | patched TGL 驱动三件套（/L/E）+ patched AuxKC；`computeLaneCount` fallback = 2 |
| 验收 | 内屏 1080p 硬件加速、声音/麦克风/合盖全通过（2026-11-11），上游 1.3.2 升级无回归（1.3.2 新增的 `-wex-edp-fix-training` 与本 patch 共存良好） |

**参数收敛结论**：iter-1b 追加的 5 个参数（force-pe1/vs1、display-trace、tc-aux、tc-bootstrap）在 patch 生效后**全部不需要**——最终只需要「正常 boot-args + 一个字节的 AuxKC patch」。

## 11. 方法论复盘

**做对的**：

1. **先逆向再实验**：静态分析确定了"WEX 不碰 lane 计算"这一关键事实，把实验空间从"WEX 参数怎么调"直接切到"Apple 驱动本身"，少走了整个弯路。
2. **证据分级与审计**：SSC 假设、TPS2 假设、"eDP 1.2 老面板"叙事都被事务日志/对照数据**主动证伪并撤回**；v1 解码错误（80B 结构）被 seq 连续性自证推翻。
3. **单变量迭代 + 固定判定四查**：每一轮失败都能精确归因（参数只改速率不改 lane），没有无效重试。
4. **三系统对照**：Linux i915 用同屏同 VBT 给出"训练成功长什么样"的基准，是整个定位的决定性一步——成本仅一次 Ubuntu Live U 盘。

**差点走偏的**：

1. 早期"lane0 能锁、lane1 没时钟"的旧结论与事务日志矛盾（`0x202` 全 0）——若按旧叙事继续修 lane1 方向就错了；
2. "1 lane 带宽不足"曾被认为是根因，iter-1b 用 HBR2 实测排除（带宽够也失败）；
3. `-wex-edp-ssc-107-off` 差点被当成首选实验——日志显示驱动本来就写 `0x107=0`。

## 12. Sequoia 15.8.3 独立验证（2026-11-12，群友实测）

另一位 G83/HS 群友在**同一块面板（SHP14B8，`0x4D10:0x14B8`）**上，用本 EFI 引导 **macOS Sequoia 15.8.3**，独立复现并验证了本方案：

| 验证点 | 结果 |
|---|---|
| 一字节补丁（同偏移 `0x1fd77` / AuxKC `0x18fd77`） | ✅ Sequoia 下同样有效（两版 framebuffer 哈希不同，但补丁点布局一致） |
| 内屏 | ✅ 点亮 + Metal 2（默认 1680×944 缩放档，可切 1920×1080/1600×900/1440×810） |
| Phase 1 训练失败 | 0 次 |
| 补丁独立性 | 69 参数 WEX + 12 项 boot-args → 黑屏；87 参数 + 16 项 → 黑屏；**任意组合 + 一字节补丁 → 点亮**。补丁独立于 WEX 版本与 boot-args，是唯一决定性因素 |

这使根因结论（`computeLaneCount` fallback 1 lane）从"Tahoe 单版本事实"升级为"**跨 macOS 大版本的驱动行为**"，§8 的字节模式签名也被证实可跨版本定位，无需重新逆向。

群友环境的差异记录：Sequoia 下无 HiDPI（改密封卷 Overrides 需关 authenticated-root，未做）；HDMI 外接在其机器上无输出（本机为花屏，表现不同）；睡眠同样必须禁用。

*群友完整踩坑记录见仓库 `docs/G83黑苹果-踩坑总结.md`（含 SSH 破黑屏迭代法、`dispmode` 分辨率工具、系统更新后 repatch 流程）。*

## 13. 遗留与后续

- **对上游最有价值的请求**：把已存在的 `tglAdoptingLease()` / `adoptBootPath()` 暴露为 boot-arg（等价于社区issue 里的 `-wex-edp-keep`）——固件留下的 `0x101=0x82` 本身就是能用的配置，"沿用"比"重训"便宜得多；
- 图形栈偶发死机（WindowServer watchdog，跨上游版本存在，11-09 原版参数时期即有 panic）是另一层独立问题，候选缓解 `-wex-tgl-hold-render-wake`；
- Tahoe 重建 AuxKC 需要 KDK 的限制，使"装系统后重打 patch"的流程依赖：预生成 AuxKC 直接 patch（本方案），或安装对应 KDK。

---

*取证数据归档：DPCD 事务日志（274+128 条）、Linux i915 全量采集（26 文件）、WEX 符号表分析、各迭代 config 与 panic 报告。本文为 2026-11-11 全天迭代的收敛复盘，判定过程详见仓库 `实验台账.md`。*
