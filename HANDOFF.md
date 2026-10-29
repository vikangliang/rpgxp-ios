# HANDOFF — MKXP-Z iOS 构建接力

> 本文件专门写给「接手继续云编译」的会话/人。AI 记忆**不随仓库走**，所以把接力上下文写在这里。

## 当前状态（2026-10-29，更新于 `63a6874`）

> 今天两条线：① 默认关闭调试快照（落盘+行扫描探针）已提交 `fa33fb0`，仅日志清理；② 引擎锁 60fps（无上限 106fps 白烧电+跑飞）已提交 `63a6874`，目标 `kTargetFps=60` 且注释留了 120Hz 一行切换。**⚠️ 推翻旧假设**：此前以为 `soft max` ~19ms 尖刺是每秒 PNG 落盘所致，① 提交后真机日志显示尖刺仍在（落盘开/关几乎一样）→ 真凶是 `glFinish`+`glReadPixels` 的 **GPU 回读阻塞**（软呈现固有成本，非持续掉帧）。EAGL 0x502 逼出软呈现，故尖刺只能异步回读/直渲削幅度（均未做）。④ mega 回退未做；游戏计时方式（帧计数 vs 实时）未决。

### 2026-10-29 性能收尾：锁 60 + 诊断 gate + 尖刺根因锤定（GPU 回读，非落盘）

**今天两条提交（均在 `scripts/mkxp-framework/ios_embed.mm`）：**
1. **① 默认关闭调试快照（`fa33fb0`）**：`mkxp_softPresent` 顶部加 `s_diagEnabled = (getenv("MKXP_DIAG") != NULL)`（默认关），`dumpImg` 创建被 `if` 包住 → 默认 NULL，行扫描探针 + 每秒一次 PNG 落盘短路跳过。**仅日志清理**，真机日志 `scene dump`/`MONOLINE`/`ROWSAMP`/`red-ish` 已归零。⚠️ **重要修正**：① 并未消除尖刺（见下），作为干净日志保留；此前"消尖刺"的承诺未兑现。
2. **② 引擎锁 60fps（`63a6874`）**：`swz_presentRenderbuffer` 钩子（同步于 RGSS 线程）顶部加帧限制器，按 `1/60s` 间距 `SDL_Delay` 睡眠卡住整条 RGSS 循环。`kTargetFps=60.0` 常量（= PC mkxp vsync），注释写明未来换 120Hz + 实时计时游戏时一行改读 `UIScreen.mainScreen.maximumFramesPerSecond` 吃满 120Hz。睡眠放在 `hookT0`/`softMs` 测量前 → 不污染耗时指标。

**动机（已查实）**：iOS `SDL_GL_SetSwapInterval(1)` **不阻塞 SDL 循环**，且 mkxp `syncToRefreshrate=true` 只是禁用软件限制器 → 引擎无上限自由跑（实测 ~106fps，轻帧冒 130+）。既白烧电又让帧计数游戏跑飞（2.65× 设计）。② 把回读从 106→60 次/秒。

**尖刺根因锤定（推翻"落盘主因"旧假设）**：
- 现象：PROFILE `soft max` 偶发 18–30ms（战斗多精灵→30，轻场景→10），量的是 `mkxp_softPresent()` 单帧耗时。
- 我最初断言"每秒 PNG 落盘含 fsync 是主因"，但 ① 提交后真机日志 `soft max` 仍 18–30ms（落盘开/关几乎一样）→ 假设推翻。
- 重读 `mkxp_softPresent` 全文逐操作排除：hash/memcpy/CGImageCreate 固定 786KB（恒定 ~1.7ms，冲不到 30）；`dispatch_async`（741 行）非阻塞（排除主线程争用）；诊断块（469–701）已关；`glGetError` 自旋环无错误洪流（无 `readback err`）。
- **唯一能偶发暴涨的只有 `glFinish()`(437) + `glReadPixels()`(442) 的 GPU 回读阻塞**——`glFinish` 强制等 GPU 画完，`glReadPixels` GPU→CPU 同步读回，负载高时阻塞到 30ms。平均 `read`（600 帧均值 3.4–5.2ms）掩盖单帧尖刺，`soft max` 抓最坏一下。
- **结论**：尖刺是 iOS 软上屏管线固有成本，偶发单帧晚一点，非持续掉帧，游戏仍 60fps 可玩。

**约束（任何"改回读"方案前提）**：EAGL 默认帧缓冲 present 在此环境不可用（present 后 FBO 0 作废、绘制被 `0x502` 拒），画面只能走"软呈现"（FBO→glReadPixels→CGImage→UIImageView）。故 ①/② 都改不了尖刺幅度，② 只降回读频率。

**真解路线（待评估，高风险，未做）**：
- 异步回读（PBO / `glFenceSync`）：读上一帧已完成像素、去每帧 `glFinish` 阻塞 → 尖刺幅度大降；风险是 ANGLE/Metal 的 PBO/fence 支持可能不稳，需先最小原型验证。
- 直渲到屏幕层（修 EAGL present 0x502 根因）：彻底去回读；原作者在此撞墙，根因在 SDL↔mkxp↔iOS GL 状态机，高风险。

**未决 / 接棒待办**：
- **④ mega 上限回退 2048**（`ios_hook.rb`）：讨论过未做。仅正方形/竖图 mega 省内存，本机 ~900MB 远低于 Jetsam 几乎无感；改的是已验证可用路径，性价比低。
- **未决问题**：该游戏是"帧计数计时"还是"实时计时"？决定 ② 的"速度对齐 PC"是否生效（帧计数→iOS 现 1.5× 设计=对齐 PC；实时→仅省电）。用户尚未按体感确认。
- **接棒验证 ②**：CI 双绿后装包看 PROFILE `fps=`≈60、角标不再 130+，并按体感核对"速度和 PC 比是快了/一致/慢了"。

**当前稳定构建 = `63a6874`**（诊断默认关 + 引擎锁 60）。

### ⚠️ 2026-10-21 23:29 真机日志判别：7.4s 未消 ≠ 修复无效，是**包里根本没有**

**铁证**：`framework-entry.patch` 自 `1b354e6`（10-21 17:51）起，在 `tilemap.cpp` 的 `buildAtlas()` 末尾注入了
`rgss: buildAtlas t=%ums blits=%zu atlas=%dx%d`。每次进图必走 `atlasDirty → buildAtlas()`（`tilemap.cpp:1016-1020`），
**必打印一次**。而 23:29 那份日志 1~1921 行**一次都没有** → 该二进制早于 `1b354e6`，必然也早于 `f9d5763`。

**别用 hook banner 判版本**：日志里的 `compat hooks v10` 来自 `f91a992`（**10-19 20:40**，两天前），
早于全部 atlas 改动，**不能证明包是新的**。

| 提交 | 时间 | 内容 |
|---|---|---|
| `f91a992` | 10-19 20:40 | hook banner v10 ← 日志里看到的版本标记 |
| `1b354e6` | 10-21 17:51 | patch 给 `buildAtlas` 加计时 |
| `96ae059` | 10-21 20:16 | atlas 缓存（**手改 deps，不进 CI，白改**） |
| `f9d5763` | 10-21 21:59 | GPU blit + atlas 缓存写进 `build_mkxp_ios.sh`（CI 真正生效源） |
| `e7c25cc` | 10-21 22:39 | CI #254 崩溃修复 |
| `319e181` | 10-21 23:04 | 编译失败修复（re.sub 替换串二次转义） |
| 日志 | 10-21 23:29:33 | **距最后一个构建修复仅 25 分钟**，iOS 云编译一轮远超此时长 |

**顺带查出并已修一个「白装机」漏洞**（`scripts/build_mkxp_ios.sh`）：
1. `git apply` 失败会静默回退 `patch -p1 -f`，后者**逐 hunk 丢弃不匹配项**。
2. 第 939 行的 9 个签名校验**没有一个属于 `tilemap.cpp`** → tilemap hunk 被丢，构建照样绿、照样出包。
3. 已把 `"rgss: buildAtlas t="` 加进校验列表 → tilemap 缺失立即 FATAL，绝不再出「以为修了其实没修」的包。
4. 已给 atlas 缓存注入 `rgss: atlas-cache HIT/MISS key='...'` 日志：
   - `HIT` → 缓存生效，重进同图应 ~0ms；
   - `MISS key=''`（空） → `tileset->filename()` 为空（tileset 没走 `Bitmap(const char*)` 构造），缓存永不命中、
     7.4s 依旧；届时须换 key（如 tileset 对象地址 + 尺寸），**不要**再改文件名字面。

**下一步**：推上去出下一版包再测。新包日志判据（缺任一 = 白装一轮）：
`rgss: buildAtlas t=` ＋ 首次 `rgss: atlas-cache MISS` ＋ 重进同图 `rgss: atlas-cache HIT`。

### 🔴 当前主攻（旧结论，10-21）：室内→室外 ~10s 卡顿 = Tilemap 图集重建 —— ⚠️ 2026-10-22 复核见下方 🔴🔴，此结论已被推翻/需修正

**诊断手段**：`3010f5b` 在 `ios_hook.rb` 加建图阶段计时（lazy 安装、纯日志、`$__mkxp_timing` 开关 + rescue，不影响功能）；首次精灵解析时安装，此后每次进图打 `[map-timing]` 各阶段 ms。

**真机日志结论**（进一次室外可见）：
| 阶段 | 耗时 | 判定 |
|---|---|---|
| `Game_Map#setup` | 3–57ms | 忽略 |
| **`Spriteset_Map#init`** | **~7400ms** | **就是它（每次进室外都 7.4s）** |
| 后续小 `Spriteset_Map#init` | 47–182ms | 快的重 init |

- **7.4s 是沉默 C++**（期间无任何解码/加载日志）→ 即 Tilemap 的 **`buildAtlas()`**（`src/display/tilemap.cpp`）：把 autotiles + 整个 40MB 巨型 tileset（256×38660）blit 进一个 GL 纹理图集（FBO blit + 上传）。
- **不是解码**：tileset 已 pinned 缓存（`17c2faf`），7.4s 窗口内无 `slow decode`。
- **为何每次进都 7.4s**：每进图新建 Tilemap → tileset 一赋值即 `atlasDirty` → `buildAtlas` 重建+重传整个图集；而**同一套 Outside tileset 的图集是同一个**，反复白重建（此前的像素 pin 没覆盖到 GL 图集这一层）。
- **红鲱鱼排除**：日志里那批 Metal `"Insufficient Permission (to submit GPU work from background)"` 紧挨 `willEnterForeground`——是**下载日志时 App 切后台**所致，非卡顿主因。
- **误导纠正**：一直追的 143ms tileset 解码仅占 10s 的 1.4%，不是瓶颈。

**修复方向（C++ 改动，待用户拍板）**：
1. **主推：按 tileset 缓存 GL 图集纹理**——同一套 tileset 的图集解一次留着（在 shState 层按 tileset 键缓存 TexFBO），之后进任何用它的图直接复用 → 回退重进室外从 7.4s → ~0。与像素 pin 一脉相承，但缓存的是 GL 图集而非 CPU 像素。
2. **先确认再改**：`tilemap.cpp` 的 `buildAtlas` + 地图数据绑定处各加 `+Nms` timing，一版诊断包坐实 7.4s 确在图集重建（而非地图数据处理），再上修复。
3. 次选：优化巨型 tileset 图集构建本身。

### 🔴🔴 2026-10-22 复判：7.4s 真凶 = bitmap.cpp 的 autotile 展开 blit（f15464e 没压住）

> 本节能直接定位结论，靠的是**源码级追链路**（不是旧日志考古——旧日志判别已踩过"旧包陷阱"，见 memory #17）。

**已确认的事实链**
- 当前 HEAD = `1e944f7`：它是 `dc93e52` 之上的 ES3 回滚（`79f2c0c`/`1e1397e` 的 nativeBlit=1 已 revert）。
- `dc93e52` 是 `f15464e` 的后代 → 所以 `f15464e` 的 **buildAtlas 修复**（旧路径 `subRectImageUpload`/glTexSubImage2D 整幅 ~42MB 拷贝 → 改为每车道 `glTexImage2D` + GPU blit 进 atlas FBO，并**禁用 atlas 缓存**）依然存在于 `1e944f7` 的 `framework-entry.patch`（git 校验 dc93e52 的 patch 含 `subRectImageUpload`/`buildAtlas`/`glTexImage2D` 命中）。
- **但用户 2026-10-22 报告：装 `1e944f7` 进图仍是 ~7.4s**（`Spriteset_Map#init`）。→ `f15464e` 的 buildAtlas 重写**没有消掉** 7.4s。

**根因复判（源码推理 + 留一个待 device 坐实的点）**
- 旧 §🔴 把 7.4s 归给 `tilemap.cpp` 的 `buildAtlas`（每次进图重建整张 40MB 图集）。`f15464e` 已把它改成 GPU blit，预期 <2s。
- 既然 `1e944f7` 仍 7.4s，剩余大头**更可能是 `bitmap.cpp` 里 `AutotileExpander.expand` 的那几千次 1:1 `blt`**（宽 autotile 一张就 6144 次），`f15464e` 完全没碰这条路径。
- **源码铁证（bitmap.cpp）**：`Bitmap(int,int)` 构造里 `clear()` → `addTaintedArea(rect())` 把**新建 dest 整张标脏**。autotile 展开对全新 dest 做 `opacity=255` 的 `blt`，`stretchBlt` 的 FAST 路径守卫是
  `opacity==255 && (!touchesTaintedArea(destRect) || !m_gpuSeeded)`；对"整张脏 + 从未上传 GPU"的全新 dest = `(!true || !false)` = `true` → **走 FAST 路径**。iOS ES2 下 `GLMeta::blitEnd` 没有 `glBlitFramebuffer` → 走 **shader 回退（每 blit ~15 个 GL 调用）**。6144 次 ×15 = 残余 7.4s。
- ⚠️ **诚实保留的两种可能**（device 日志未再坐实）：(a) `f15464e` 的新 GPU-blit 路径在 Metal 翻译层仍然慢；(b) 主导开销就是 autotile 展开 blit。**两者修法不同，但 (b) 的修法对 (a) 无害**。

**ES3 原生 blit 已永久封死（别再试）**
- `79f2c0c`/`1e1397e` 试过 `glBlitFramebuffer` 原生 blit（设 `nativeBlit=1`）——本可让 FAST 路径降到 ~1 GL 调用，但它**破坏 iOS 软呈现**（标题界面卡死 + `0x506` 帧缓冲错误），已回滚。所以根治只能走 **CPU 侧**，不能靠原生 blit。

**拟定修法（CPU 累积 + 末尾单次上传，不碰显示管线、不动游戏）**
1. `BitmapPrivate` 加 `bool m_gpuSeeded = false`（GPU 纹理已有真实内容；全新 dest 默认 false）。在**图片加载 ctor**（`uploadImage` 之后，~bitmap.cpp:643）和 **pixeldata ctor**（~:667）置 `true`；`Bitmap(int,int)` 全新 dest 保持 `false`。
2. `stretchBlt` FAST 路径：若 `!p->m_gpuSeeded`，改用 **CPU 累积**——对 dest 惰性 `SDL_Surface`（`allocSurface` 后填透明），源经 `ensureCpuSurface()`（`glReadPixels` 从 `gl.fbo` 下载，复用 `getPixel` 同款机制）拿到像素，用 `SDL_BlitScaled` 拷进 dest，然后 `return`（**延迟 GPU 上传**）。源若拿不到 CPU surface（如 megaSurface）则回落到原 GL blit 并置 `m_gpuSeeded=true` 防止反复重试。
3. **单次上传钩子**：在 `Bitmap::getGLTypes()`（`const`，`const_cast` 后）和 `Bitmap::bindTex` 里调 `ensureGpuUpload()`——`TEX::uploadImage(gl.width, gl.height, surface->pixels, GL_RGBA)` 把累积的 CPU surface 一次传上 `gl.tex`，释放 surface、置 `m_gpuSeeded=true`、重新 `addTaintedArea(rect())` 整张。autotile 展开结束后 buildAtlas 绑该纹理时即触发这一次上传。
4. 效果：autotile 展开 = 几千次廉价 CPU 拷贝 + **一次**上传，残余 7.4s 应降到几十 ms；只对"全新、从未上传 GPU 的 dest"生效，UI/精灵 blit（已 seeded 或重叠进脏区）走原 GL 路径 → 预期无视觉回归，但**核心 blit 路径改动，必须真机验证**。

**⚠️ patch 生成硬约束（踩过坑，见 memory #14/#85402296）**
- `bitmap.cpp` 在 `framework-entry.patch` **之前**会被构建脚本 pre-patch 改过：`3a-2`（tainted 区域非法矩形护栏，动 `addTaintedArea`/`substractTaintedArea`）、`3a-3`（drawText 视口裁剪诊断）。→ 任何新增 `bitmap.cpp` hunk **必须基于 pre-patched 源码**，不能对 pristine 重 `git diff`。
- 正确流程：以 `dc93e52` 的 `framework-entry.patch` 作底（它本就针对 pre-patched 源码）→ clone 里先跑 `build_mkxp_ios.sh` 里的 `3a-2`+`3a-3` 两段 Python（或直接复刻替换串）→ `git apply dc93e52:scripts/mkxp-framework/framework-entry.patch`（记为 DCE）→ 改代码 → `git diff DCE..MINE -- src/display/bitmap.cpp src/display/bitmap.h` → 把该 hunk **追加**进 `framework-entry.patch`。`bitmap.h` 未被 pre-patch 动过，可用 pristine 上下文。
- **必须给新代码加一个签名串**（如 `fprintf(stderr,"rgss: cpuBlit fresh-dest fast path\n")` 或独特注释），并加进 `scripts/build_mkxp_ios.sh` 的 9 个签名 FATAL 校验列表（~:939）——否则 hunk 被 `patch -p1 -f` 静默丢弃时会**悄悄出"以为修了其实没修"的包**（memory #14 同款事故）。

**决策（2026-10-22）**
- 用户暂不强推实现，先把分析落 HANDOFF。当前可用构建 = `1e944f7`（功能正常、无 ES3，但每次进图仍 ~7.4s）。
- 下次恢复时二选一：① 先发一版诊断包（在 autotile 展开外加 `[map-timing]` 子计时，对比 `buildAtlas t=`）坐实 (a) vs (b)；或 ② 直接按上面约束实现 CPU-blit 修法（它对 (b) 必有效、对 (a) 无害）。

**已完成项（今天上午，✅ 已验证）：**

| 项 | 状态 | 说明 |
|---|---|---|
| spng 视觉 bug（裂痕/黑白块/全黑地图） | ✅ 已修已验 | 根因=今早新加的 libspng 路径把巨型 tileset（256×38660）解成黑/乱图，且 spng「假成功」不回退 libpng。`a571d23` 起 spng 默认关，真机确认块/黑图消失 |
| 昨晚的裂痕（另一病根） | ✅ 已修 | 昨晚裂痕是 **tileset 钉死→OOM/内存压力**所致，`8548a7c` 取消 pin 已解决；**与 spng 无关**，两次视觉问题根因不同，别混 |
| 室内↔室外切图重解卡顿 | ✅ 已修已验 | `17c2faf`+`2882aad`：`bitmap.cpp` 的 `DecodedPixelCache` 加**独立 `pinned` 表**（`PINNED_MAX=4`），mega-surface(tileset) 钉住、不受 96MB LRU 淘汰。真机日志 `tileset pinned:` 钉住 interior1+outside，每会话仅首进解 1 次、回退零重解；内存稳 ~468MB（安全） |
| ~~首进图一次性卡顿（143ms）~~ | ❌ 误导，已排除 | 143ms tileset 解码仅占 10s 的 1.4%，**不是瓶颈**；真凶是上方 🔴 的 Tilemap 图集重建（`buildAtlas` ~7.4s）。「后台预热/黑屏期解码 tileset」方案作废 |

- **当前稳定构建 = `2882aad`**（spng 默认关 + tileset 安全 pin + `tileset pinned:` 日志标记）。CI 双绿、已装机验证：裂痕正常、来回切图 0ms、每帧 hook avg ~5ms、内存稳。
- **改动位置**：
  - `scripts/mkxp-framework/ios_embed.mm`：spng 开关（`mkxp_ios_spng_disabled()` 默认返回 1）+ 三指手势（**手势在用户环境不触发，已无关紧要，可删**）。
  - `scripts/mkxp-framework/framework-entry.patch`：`bitmap.cpp` 的 `DecodedPixelCache` 加 pinned 表 + `put(isMega)` + `clear()`、`tryRead` 改调 `mkxp_ios_spng_disabled()`、`tileset pinned:` 日志。
- **spng 休眠未删**：`mkxp_spng_decode_abgr` 路径仍在 patch 内但默认关；**勿再启用**（净负收益：对 40MB 图仅省 ~10ms 却搞出黑图）。是否清理死代码待定。
- **下一步候选（⚠️ 已作废：下面 1/2 都针对 143ms tileset 解码，而它并非瓶颈；真正待办见上方 🔴 的「按 tileset 缓存 GL 图集」）**：
  1. ~~后台预热 tileset~~（作废）：目标 143ms 非瓶颈，做了也几乎无感。
  2. ~~黑屏期同步解码~~（作废）：同理，目标 143ms 非瓶颈。
- **关键教训**：spng 是 2026-10-21 **早上**才引入的回归；昨晚（10-20）的裂痕病根是 tileset pin/OOM（`8548a7c` 已修）。两次视觉问题根因不同。

## 历史状态（2026-10-20，更新于 `d55c23d`）

> 里程碑盘点：

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 流水线 | ✅ | Flutter 壳 + mkxp 插件 + 云构建 + 侧载，IPA 可出 |
| M1 编译/框架化 | ✅✅✅ | 双 workflow 全绿；`MKXP.framework` 含引擎；12 编译坑 + 6 链接坑全填平 |
| M1 真机首测（闪退） | ✅ 已修 | 装包/壳/桥接/链接全通；点启动闪退 → `625cbd5` 派发到主线程修掉 |
| M2 阶段一（导入+启动链路） | ✅ | 文件选择器/ZIP 导入/游戏库/启动·删除/日志对话框/透明浮层就位 |
| M2 阶段二（触摸浮层/设置/日志/详情页） | ✅ 已完成 | 原生 `MkxpTouchOverlay`（圆环摇杆+2×2 键直调 mkxp_key）、五页 UI、游戏详情页、退出菜单 |
| **M2 关键 Bug：启动后无画面** | ✅ 已修已验 | 点启动卡「正在启动」/无画面 → `15ab649`+`baa3646` 循环甩后台线程；真机已出画面（M3 在其上继续调） |
| M3 真机调通 + 四运行时修复 | 🔧 基本完成 | ①BGM自愈 ③解码缓存 已修；EventScriptError(has_follower)已根治；②撕裂 glFinish 修复已实现、待真机验证(d55c23d)；④消息框少字定位中(上游脚本切片)。当前 `d55c23d` CI 双绿 |

- 最新提交：`32918a4`（M3：has_follower 改 public，根治 EventScriptError 弹窗）。M3 真机调通 + 四运行时修复（BGM/撕裂/加载/文本）均已完成、构建冲突已修通；完整细节见文末「CI 链复盘 + 全项目根因总表」。自 `8eac281` 起进入 M3 真机调通：黑屏无声三连修、
  UIKit 崩溃根治（`MKXPZ_IOS_EMBED` 守卫）、GL 上下文回主线程、zlib LoadError 根治、sdl2-image JPEG、
  Ruby GC 调优、脚本加载打点。其前 `baa3646` 及更早均双 workflow 全绿；**拉取后仅 `.vscode/` 未跟踪**
  （编辑器目录，可忽略，不影响构建）。
- **M0 流水线 ✅**（Flutter 壳 + mkxp 插件 + 云构建 + 侧载，IPA 可出）。
- **M1 全部完成 ✅✅✅**（`625cbd5` 起双 workflow 全绿）：
  - `MKXP.framework`：核心 = libmkxp + 静态 Ruby + SDL2_sound（`-force_load` 全量载入）；
    vcpkg 依赖在 `MKXP.framework/Libs/*.a` **按需加载**（去重，见坑 #18）；
  - `rpgxp-loader-ipa` **12.26MB**（M0 时约 7.5MB，差额 = 引擎 + 4.5MB CJK 字体），
    即 IPA 已含引擎；App 侧桥接（launch/quit/key）与透明浮层均已就位；
  - 编译期十二坑（#3/#6-#12）+ 链接期六坑（#13-#18）全填平。
- **M1 真机验证（已完成）**：Sideloadly 装包 → 填游戏目录（如 `games/Essentials`）→
  点「启动引擎」→ 看 `mkxp.log`（主界面有 启动/关机/读取原生日志 三按钮 + 目录输入框）。
  **真机首测（2026-10-16）**：装包/Flutter 壳/桥接/链接全通，但**点启动即闪退**——
  根因：引擎整体跑后台 `std::thread`，SDL2 的 iOS 后端（UIWindow/CAEAGLLayer/UIKit
  事件泵）只支持主线程。已修于 `625cbd5` 后的 `mkxp_framework.cpp`（`dispatch_async`
  派发到主线程、立即返回）。若再崩，取 iPhone 设置→隐私→分析与改进→分析数据里最新的
  `rpgxpLoader-*.ips` 崩溃日志定位。
- **M2 关键 Bug（已修，CI 绿待真机验，`15ab649`+`baa3646`）**：闪退修掉后**点启动卡在「正在启动」、
  永远不出现游戏画面**。根因：`EventThread.process()` 这个阻塞事件循环在主线程永不退出，占死
  iOS 主线程 run loop → Core Animation 无法上屏（画面冻在 Flutter 浮层）。`15ab649` 把
  SDL 初始化+建窗+起 RGSS 线程留在主线程（UIKit 安全，后台线程 SDL_Init/CreateWindow 会崩），
  **阻塞事件循环与终止清理挪到后台 `std::thread`**，`mkxp_z_main` 立即返回 → 主线程 run loop
  恢复、画面才上得去。`15ab649` 编译期曾因 `RGSSThreadData(EventThread*, ...)` 实参误写成解引用
  `*evThread` 报错，`baa3646` 改回传指针后双 workflow 全绿——**IPA 已可侧载真机验证**。
- 游戏文件目前只能经 Finder 文件共享进入沙盒（`UIFileSharingEnabled` 尚未开，需的话 CI 加 patch）。
- 已跑通的子步骤（CI 已验证）：
  - MRI Ruby 3.3.12 静态库 `libruby.3.3-static.a` + 头文件 staged；
  - vcpkg `arm64-ios-static` 静态 triplet 编出全部 C 依赖；
  - `SDL2_sound` v2.0.6 源码交叉编译出 `libSDL2_sound.a`；
  - mkxp-z v2.4.2 编译 + 框架化入口 `mkxp_run/mkxp_key/mkxp_quit`（M1-A）。

## M2 进度（2026-10-16 起，已全部完成 ✅）

**阶段一（导入+启动链路）✅**：`file_picker`/`archive`/`path_provider`；`game_library.dart` 扫描
`Documents/games/`（顶层含 Game.ini 即一个游戏）、Zip 导入（自动定位游戏根，兼容直铺/套一层，
跳过 `__MACOSX`/`.DS_Store`/`._*`）、删除；`Mkxp.launchGame` 透出错误（含 mkxp_run 返回码含义）。

**阶段二（界面功能）✅**：全部做完——
- 完整 UI 五页：`lib/screens/` 下 `library`（游戏库列表 + 启动/删除 + 导入 + 刷新）/
  `import`（解压进度条，按未压缩字节计进度 + 当前文件名）/ `log_view`（读 `mkxp.log`）/
  `settings`（设置 + `app_settings.dart`）/ `game_detail`（点列表先进详情，点"开始游戏"才启动）/
  `game_run`（运行页）；
- 原生触摸浮层 `mkxp/ios/Classes/MkxpTouchOverlay.swift`：圆环摇杆 + 2×2 动作键，直调 `mkxp_key`
  （解决 SDL 全屏窗吞触摸，不依赖 Flutter 主线程）；
- 游戏内退出菜单、真实图标、游玩时长、`SDL_HINT_ORIENTATIONS` 横屏 hint。

## M3 进度（2026-10-16 起，真机调通 ✅ + 四运行时修复 ✅；④消息框少字定位中 🔧）

M2 无画面修好后上真机，暴露一连串 iOS 实测问题，已连环修复（提交均带 `m3` 前缀）：

- **黑屏无声三连修**（`f4f36a1`）：① 引擎 C++/Ruby 日志重定向到 `Documents/mkxp.log`
  （`mkxp_framework.cpp` 里 `freopen` stdout/stderr，App 内日志页可读，是无 Mac 的唯一调试通道）；
  ② AVAudioSession 激活挪后台；③ 后台线程 `SDL_ShowSimpleMessageBox` 不安全 → 改为只写日志。
- **UIKit 崩溃根治**（`2c011f0`）：`EventThread::process` 跑在后台线程，而窗口操作（SETFULLSCREEN/
  WINRESIZE/WINREPOSITION/WINCENTER/WINRENAME/标题设置）会改 UIKit 视图 → 后台线程碰 UIKit 必崩
  `NSInternalInconsistencyException: Call must be made on main thread`（Essentials 的
  `Graphics.resize_screen` 必踩）。`framework-entry.patch` 的 `eventthread.cpp` 加 `MKXPZ_IOS_EMBED`
  守卫，这些操作在嵌入模式全部吞掉（窗口固定全屏，内部分辨率由 RGSS 线程 `Screen.setResolution` 调）。
- **GL 上下文回主线程**（`0909989`）：实测崩溃栈直指 `SDL_GL_CreateContext@rgssThread` ——
  GL 上下文创建必须主线程，已从 rgssThread 挪回（与 `MKXPZ_INIT_GL_LATER` 的处理配合）。
- **zlib LoadError 根治**（多轮：`31912ba`→…→`cee6bd0`→**`rb_provide_feature` 正解**）：
  真机 `require 'zlib'` 报 LoadError。`dlsym Init_zlib` + `$LOADED_FEATURES<<'zlib'` 都救不了
  （`require` 先按 `$LOAD_PATH` 找文件、找不到即 LoadError，根本不查 loaded features；dlsym 又脆弱）。
  **正解**（`binding-mri.cpp` 的 `mriBindingInit`）：若 `!const_defined?(:Zlib)` 直接 `Init_zlib()`
  定义模块 + `rb_provide_feature(rb_str_new_cstr("zlib"))` 把 feature 正式登记，此后 `require 'zlib'`
  直接成功。`Init_zlib`/`rb_provide_feature` 都在 `libruby-static.a`（`-force_load` 全量载入），
  `extern "C"` 声明后直接调用即可。`mkxp_framework.cpp` 的 `used` 锚点 `zlib_ext_anchor` 仍保留
  （强制保留 `Init_zlib`，无害）。详见坑 #21。
- **sdl2-image JPEG**（`a3584d5`）：真机日志 `'JPEG images are not supported'` → vcpkg `sdl2-image` 启用 JPEG 特性。
- **Ruby GC 调优**（`05a6dd0`）：iOS 无 JIT，Ruby 纯解释执行；Essentials 启动期解释 1MB 脚本、定义上万对象，
  默认 GC 阈值触发海量 GC 是启动慢主因。在 `ruby_init` 前 `setenv` 放大 `RUBY_GC_HEAP_INIT_SLOTS`(2M)/
  `GROWTH_FACTOR`(2.0)/`MALLOC_LIMIT`(256M)/`OLDMALLOC_LIMIT`(256M) 等。
- **脚本加载打点**（`3ee2341`/`7abee44`）：`binding-mri.cpp` 加 `[stage]`/`rgss: N/t=...ms` 时间戳，
  区分"慢"与"卡死"（inflate/exec 每 50-100 段打点）。
- **CI**：iOS 打包并入 `build-mkxp.yml`（build-ios job，`4697b13`），失败/成功状态发布改用可写 `GITHUB_TOKEN`
  （`4959966`）；`build-mkxp.yml` 增 ~146 行、`ios.yml` 微调。`vcpkg install` 加 `--recurse`（`3597acd`）。

## 环境要求

### 本地（另一台电脑）——只需能推代码，其余全在云端
- **git**：任意安装路径，配置好能 `push` 到本仓库即可（HTTPS 凭据或 SSH key）。
  Windows 上 git 不一定在 PATH，常见位置 `C:\Program Files\Git\cmd\git.exe`、
  `C:\src\git\cmd\git.exe`，找不到时用 `Get-Command git` 定位后把其目录加进 `$env:PATH`。
- **网络**：能访问 github.com（拉取 + 触发 Actions）。
- **仓库远程**：默认 `origin` 指向 `github.com/vikangliang/rpgxp-ios`（`push` 到 `main` 即触发 CI）。
- （可选）**Flutter SDK**：仅用于本地 `flutter analyze` / `flutter test` 自检 Dart 代码；
  iOS 编译**不能**在本地做（无 Mac），必须在 CI。Windows 装 Flutter 即可跑 analyze。
- 编辑器/AI：用任意编辑器改 `scripts/`、CMake、Dart 文本即可，**无需本地编译任何原生代码**。

### 云端 CI（GitHub Actions `macos-15`）——真正的构建环境
- macOS 15 runner，默认 Xcode 16.4（自带 iPhoneOS SDK、Apple clang 17）。
- Homebrew 已预装；脚本内 `brew install` 补：`cmake ninja automake libtool pkg-config bison xxd`。
- `ruby@3.3`（3.3.12）已预装，作 MRI Ruby 交叉编译的引导器。
- 其余全部由脚本自动 clone + 编译，**无需预装**：
  - MRI Ruby 源码（交叉编 `libruby-static.a`）
  - vcpkg + 全部 C 依赖（`arm64-ios-static` 静态 triplet）
  - `SDL2_sound` v2.0.6（源码交叉编译）
  - mkxp-z v2.4.2（手搓 CMake 编 `libmkxp.a`）
- 缓存：workflow 用 `actions/cache` 缓存 `deps/vcpkg/installed` 与 `deps/ruby-ios`，
  命中即跳过重建（改脚本 / triplet 时 key 会变而失效）。

> 结论：另一台电脑**不需要 Mac、不需要 Xcode、不需要 vcpkg/Ruby**；只要 git 能 push，
> 剩下的全交给 CI。唯一会随机器变的是 git 的可执行路径与凭据。

## 怎么触发云编译

- `push` 到 `main` 会**同时**触发：
  - `build-mkxp.yml`：编 `MKXP.framework`，上传 artifact（`MKXP-framework` / `mkxp-build-log`）；
  - `ios.yml`：编 M0 App 的未签名 IPA（`rpgxp-loader-ipa`）。
- 接手动作：本机 `git pull` → 改 `scripts/` 或 `CMakeLists.txt` → `commit && push`，CI 自动跑。
- 看日志：GitHub → Actions → 对应 workflow run → 下载 artifact（尤其 `mkxp-build-log`）。
- **免 token 看状态（关键，接手者只读这两个分支即可，无需截图/登 GitHub）**：
  - `build-mkxp.yml` 永远把跨归档符号冲突报告推到 `ci-status` 分支的 `ci-status/last-collisions.md`
    （`COLLISION_COUNT` 是预期的重复符号，已被「核心 force_load + 依赖按需加载」消化，非致命）；
    **仅失败时**额外推 `ci-status/last-failure.md`（错误行 + 日志尾部）。
  - `ios.yml` 现已 `always()` 把构建状态推到 `ci-status-ios` 分支的 `ci-status/last-failure.md`
    （成功写 `# iOS build success`，失败写 `# iOS build failure` + 重复/未定义符号聚合 + 日志尾部）。
  - 本地读取（公开仓库免登录）：`git fetch origin ci-status ci-status-ios`，再
    `git show origin/ci-status:ci-status/last-collisions.md` /
    `git show origin/ci-status-ios:ci-status/last-failure.md`；
    用里面的 `commit: <sha>` 对上自己推送的提交，即知是否轮到本次、绿还是红。
  注意 `git fetch origin ci-status ci-status-ios` 中若某分支尚不存在会整条报错，
  需**分开 fetch**（如本机另写 `get-ci.ps1` 逐个拉取并容错）。
- **iOS 失败摘要需要 PAT（重要）**：`ios.yml` 由 `workflow_run` 触发，拿到的 `GITHUB_TOKEN` 是
  **只读**的，`git push` 到 `ci-status-ios` 会被拒（摘要步骤也会因此崩）。已在 `ios.yml` 的
  Publish 步骤改用仓库 Secret **`CI_PUSH_TOKEN`**（fine-grained PAT，仅本仓库、Contents: RW）推送；
  无该 Secret 时退回 `GITHUB_TOKEN` 并 `continue-on-error` 容忍失败。**接手者必须先建这个 Secret**
  才能自动读到 iOS 失败摘要——否则只能去 Actions 页面手动看日志。建法：GitHub → Settings →
  Developer settings → Fine-grained tokens → 生成（Repository access 选 rpgxp-ios，Contents: RW）→
  复制 → 仓库 Settings → Secrets and variables → Actions → New secret：`CI_PUSH_TOKEN`。
  **注意**：重跑一个基于旧提交的失败 run 不会带上后续提交的修复，必须在一个含修复的提交上跑。

## 已踩的坑（别再踩）

1. **`find_library(SDL2)` 太脆** → `scripts/mkxp-cmake/CMakeLists.txt` 的 `find_mkxp_lib`
   改为**递归 glob** `lib<name>.a` + framework 主二进制，并在 configure 与 vcpkg 装完两处都
   dump 安装目录（`VCPKG_INSTALL` / `DEP_LIB` 下的 `.a` 清单）。
2. **xxd 嵌入三处错** → 同一 CMakeLists：
   - 符号名：用 `file(RELATIVE_PATH)` 取**相对构建目录**路径 `../shader/xxx` 再 `xxd -i`，
     产出 `___shader_*` / `___assets_*`（3 个下划线），而非传绝对路径得到的 `_Users_runner_...`；
   - 文件名：输出必须是 `*.xxd`（源码是 `#include "simple.frag.xxd"`），原写成 `.c`；
   - 重复符号：`.xxd` 被 `shader.cpp/main.cpp/eventthread.cpp/font.cpp` 直接 `#include`，
     **绝不能**加进 `add_library` 源列表，改由自定义目标 `mkxp_embed_xxd` 驱动生成，`gen/` 加进 include。
3. **`MKXPZ_PLATFORM` 误判 macOS** → `build_mkxp_ios.sh` 用 `sed` 把
   `src/system/system.h` 里的 `MKXPZ_PLATFORM_MACOS` 改成 `MKXPZ_PLATFORM_LINUX`
   （仅 `-D` 不够：源文件里的 `#define` 后定义会覆盖命令行）。
4. **Ruby iOS 交叉编译**：
   - iOS 上 `system()` 标 unavailable，`vm_dump.c` 无宏守卫 → `sed` 改 `system(buf)`/`system(cmd)` 为 `0`；
   - 用 runner 原生 `ruby@3.3` 作 MINIRUBY/BUILTRUBY/PREP 引导；
   - `--with-static-linked-ext`，只 `make libruby.3.3-static.a`（绕过 Ruby 3.3 可执行链接把 Makefile 当目标的坑）；
   - `ulimit -s 65536` 防内建字节码编译栈溢出。
5. **`SDL2_sound`**：vcpkg 无此端口且其 `main` 已升 SDL3 → 固定源码编 `icculus/SDL_sound` 的 `v2.0.6`。
6. **第三方头文件不在 `include/` 根下**（configure 过了，编译期炸一片 `'xxx.h' file not found`）→
   `scripts/mkxp-cmake/CMakeLists.txt` 必须显式加子目录：`include/AL`（openal-soft，mkxp-z 以 `<al.h>` 引用）、
   `include/uchardet`（uchardet 0.0.8 起装 `${CMAKE_INSTALL_INCLUDEDIR}/uchardet` 子目录）、
   `include/pixman-1`（对应 meson 的 pkg-config `pixman-1`）、`<SDLSOUND_PREFIX>/include/SDL2`
   （SDL2_sound v2.0.6 把 `SDL_sound.h` 装进 `SDL2/`）、`${RUBY_INC}/ruby`（mkxp-z 直接 `#include <ruby.h>`，
   Debian 把 ruby.h 平铺在版本目录根、iOS 没有）。已另加两个 include 根的子目录全量 glob 兜底。
   排查方法：本地 clone `mkxp-z/mkxp-z` 的 tag `v2.4.2`，grep 全部 `#include <...>`，逐一对照各 port 安装规则。
   已确认**不会**参与编译的：fluidsynth（`SHARED_FLUID` 未定义）、openssl/HTTPS（`MKXPZ_SSL` 未定义）、
   boost（sigslot 适配器无人引用）、X11/EGL（`GLES2_HEADER` 已定义走 GLES 路径）。
7. **`include/ruby` 不能进 `-I`（assert.h 截胡）**：mkxp-z 直接 `#include <ruby.h>`，曾把
   `include/ruby` 加进搜索路径 → Ruby 的 `ruby/assert.h` 截胡全部 26 处 `<assert.h>`
   （它只定义 `RUBY_ASSERT_*`，无标准 `assert` 宏）→ 满屏 `use of undeclared identifier 'assert'`。
   正解：build 脚本把 `ruby.h` + `defines.h`（ruby.h 内裸名引用）**平铺**到 include 根，
   对齐 homebrew ruby 布局；`<ruby/xxx.h>` 仍从 include 根的 `ruby/` 子目录解析。
8. **`__APPLE__` vs `MKXPZ_PLATFORM` 守卫错位**：iOS 上 `__APPLE__` 为真，但 `MKXPZ_PLATFORM`
   已被坑 #3 的 sed 改成 LINUX。`config.cpp` 三处 `__APPLE__` 守卫引用仅 macOS 存在的 Metal 逻辑
   （`isMetalSupported()` 仅 `MKXPZ_BUILD_XCODE` 下声明、Apple arm64 默认开 Metal、ANGLE 平台选择）
   → `undeclared identifier 'isMetalSupported'`。已 sed 收紧为 `MKXPZ_PLATFORM_MACOS` 专属（iOS 走 GLES）。
9. **SDL2_ttf ≥2.20 结构体改名**：vcpkg 现装 sdl2-ttf 2.24.0，2.20.0 起不透明结构体由
   `_TTF_Font` 改名 `TTF_Font`（`typedef struct TTF_Font TTF_Font;`）。mkxp-z v2.4.2 的
   `font.h/font.cpp` 按旧名 forward-declare/返回，`settingsmenu.cpp` 经 SDL_ttf.h 拿到新类型
   → `incompatible pointer types assigning to 'TTF_Font *' from '_TTF_Font *'`。
   已 sed 把这两个文件的 `_TTF_Font` 统一改成 `TTF_Font`（API 用法均跨版本兼容，无需其他改动）。
10. **`MKXPZ_CJK_FONT` 的字体漏嵌**：本工程 CMake 定义了 `MKXPZ_CJK_FONT`（Essentials 中文 UI
    兜底），此时 `font.cpp` 嵌的是 `assets/wqymicrohei.ttf`（4.5MB）而非 liberation → xxd 清单
    漏了它就炸 `'wqymicrohei.ttf.xxd' file not found`。排查法：grep 全部 `#include "*.xxd"`
    与 CMake 的 SHADERS/ASSETS 清单对账（shader 26 + icon/gamecontrollerdb/liberation/wqy）。
11. **`system()` 在 iOS  unavailable**：`binding-mri.cpp` 的「打开 URL」绑定用 `std::system`
    拼 `OPENCMD`（open/xdg-open/start）启外部程序 → `'system' is unavailable: not available on iOS`。
    已 sed 把调用点替换为 `0`（no-op 降级，返回 Qnil 不抛错）。steamshim 的 fork/execvp 不在编译清单，无需处理。
12. **binding 层按仓库根相对路径 include**：`binding/*.cpp` 有 4 处 `#include "src/..."`
    （util.h/config.h），需把 `${MKXP_SRC}` 本身加进 MKXP_INC（此前只有 src/ 各子目录）。
13. **缓存还原把 vcpkg 目录搞成「有内容无 .git」**：workflow 的 `restore-keys` 前缀回退会把
    旧（成功）运行的 `deps/vcpkg/installed` 还原出来，目录非空但无 `.git`，脚本的
    `[ ! -d $VCPKG/.git ]` 守卫漏判 → `git clone` 报 "already exists and is not an empty directory"。
    已改为：克隆前把还原内容挪到 `${VCPKG}.restore`，clone + checkout 钉死 commit 后再把
    `installed/` 挪回。另：vcpkg 已钉死 commit（`VCPKG_REF`），不钉则每次跑当天 master、
    缓存跨版本复用，构建不可复现。
14. **Ruby 汇编文件没吃 iOS flags（`Context.o` built for macOS）**：Ruby 的 coroutine `.S`
    汇编规则是 `$(CC) $(ASFLAGS) -c`，**不吃 CFLAGS**——`configure cflags=` 传的交叉 flags
    到不了汇编步骤，`Context.o` 按宿主编成 macOS 对象；`libtool -static` 又不校验平台，
    直到最终链进 App 才炸 `linking object file built for 'macOS'`。已改 `make ... ASFLAGS="$ARCH_FLAGS"`。
    另修：Ruby 缓存路径此前误写 `deps/ruby-ios`（与脚本 PREFIX 不一致）导致缓存从未生效，
    已改为 `deps/ruby-ios-3.3.12` 并去掉 restore-keys（脚本变更必须逼重建）。
15. **静态 framework pod 不传递依赖到 App 链接**：mkxp 插件含 Swift 必须 `static_framework = true`，
    而静态 framework 的 pod target 只归档自己的对象——podspec 的 `vendored_frameworks` 只让
    pod 编译期能 `import MKXP`，App 最终链接看不到框架 → `Undefined symbol: _mkxp_run`。
    已用 `scripts/ios-link-mkxp.rb`（CI 在 flutter build 前跑）把框架显式注入 Runner 的
    Link Binary With Libraries + force_load + 补齐系统框架/库。
16. **框架合并漏了自编 SDL2_sound + SDL2main 捣乱 + 缺 CoreMotion/Bluetooth**：合并列表原先只有
    libmkxp + vcpkg 的 `.a` + ruby，`libSDL2_sound.a` 在 vcpkg 外被漏掉 → App 链接期
    `Sound_Init/Sound_Decode` 齐 undefined；`libSDL2main.a` 在 iOS 上无意义且引用已改名的
    main → 排除 + `mkxp_framework.cpp` 里放 `SDL_main` 无害桩；SDL2 的 iOS sensor/joystick
    代码引用 CoreMotion/CoreBluetooth → 两个框架补进链接参数（ios-link-mkxp.rb 与 podspec）。
17. **workflow 竞态**：两 workflow 并行触发时，iOS 只能拿到上一个提交的框架，引擎修复晚一轮
    生效（`Context.o` 问题曾被这么掩埋）。`ios.yml` 已改 `workflow_run` 触发，用同次提交的产物。
18. **静态框架链接终解=核心 force_load + 依赖按需加载**：`-framework MKXP` 无论放
    OTHER_LDFLAGS 还是 frameworks 阶段都拉不到符号（疑似 Xcode/ld 对「框架壳+归档内核」
    的处理问题）；而整个框架 `-force_load` 全量载入会炸 duplicate symbols——nm 对账实锤
    libc++/fmt 的符号被嵌进 `libopenal.a`/`libfmt.a`/`libmkxp.a` 多个归档（454 个重复定义，
    fmt↔openal 59 + mkxp↔openal 36 + …）。终解：框架二进制只合并**核心**（libmkxp + 静态
    Ruby + SDL2_sound）并 `-force_load`（全量载入、无视顺序）；vcpkg 各依赖 `.a` 放进
    `MKXP.framework/Libs/`，在 `-force_load` **之后**逐个按需加载——按需加载天然去重
    （ld 只取第一个定义），且排在核心之后不会再有顺序问题。另：两个 workflow 的失败摘要
    要推不同分支（`ci-status` / `ci-status-ios`），都 `--force` 推同一分支会互相覆盖。
    诊断工具：`build_mkxp_ios.sh` 5b 节的 nm 跨归档对账（COLLISION 行）。
18. **静态框架链接的三难**（都在 App 最终链接期暴露）：① podspec `vendored_frameworks` 会被
    静态 framework 的 pod 并进 `Pods-mkxp.framework`，与 App 侧加载重复；② 仅 `-framework MKXP`
    放 OTHER_LDFLAGS 会排在 Pods 之前扫描，pod 归档里的引用方还没进场 → Undefined symbol；
    ③ `-force_load` 全量载入会把 Ruby `--with-static-linked-ext` 烘进的 zlib 等对象与 vcpkg 的
    libz/libpng 重叠符号一起载入 → 800+ duplicate symbols。**正解=按需加载 + 链接锚点**：
    podspec 只留编译期 FRAMEWORK_SEARCH_PATHS；`scripts/mkxp-link-anchor.m` 加入 Runner 编译源
    （Runner 自身引用 mkxp_run/mkxp_key/mkxp_quit，未决状态在链接最开始就存在，顺序无关）；
    MKXP.framework 经 frameworks 阶段按需链接。

19. **MKXPZ_IOS_EMBED 守卫（UIKit 崩溃）**：`EventThread::process` 后台线程跑，任何 SDL 窗口操作
   会碰 UIKit 视图 → 后台线程崩 `NSInternalInconsistencyException: Call must be made on main thread`。
   `eventthread.cpp` 的 SETFULLSCREEN/WINRESIZE/WINREPOSITION/WINCENTER/WINRENAME/标题设置 在
   `MKXPZ_IOS_EMBED` 下全部吞掉；窗口固定全屏，内部分辨率由 RGSS 线程调。
20. **GL 上下文必须主线程**：`SDL_GL_CreateContext` 在 rgssThread 创建会崩（崩溃栈 `...@rgssThread`），
   改回主线程（与 `MKXPZ_INIT_GL_LATER` 的处理配合，见 build 脚本/CMake）。
21. **zlib 静态扩展：运行时 `require 'zlib'` 必须主动登记 feature（根治经验，2026-10-17）**：
   C++ 侧 libz 解压（inflate）正常，但 Ruby 层 `require 'zlib'` 真机报 LoadError。根因：Ruby 的
   `require` **先按 `$LOAD_PATH` 找文件、找不到即抛 LoadError，根本不会先查 `$LOADED_FEATURES`**——
   所以往 `$LOADED_FEATURES` 塞裸字符串 `'zlib'` 挡不住。**正解**：在 `binding-mri.cpp` 的
   `mriBindingInit` 里、mkxp-z 自带 `require('zlib')` 之前，若 `!const_defined?(:Zlib)` 就
   `Init_zlib()`（定义 Zlib 模块）+ `rb_provide_feature(rb_str_new_cstr("zlib"))`（把 feature 正式
   登记为已加载，此后 `require 'zlib'` 直接成功）。两个符号都在 `libruby-static.a`（`-force_load`
   全量载入）。
   **两个大坑（2026-10-17 实踩，连红两次 CI）**：
   ① `extern "C"` 链接声明**不能写在函数体内部**——C++ 不允许块内 linkage-spec，报
      `error: expected unqualified-id`（`e7fb24c` 红，build-mkxp 编译错）。
   ② 即便声明提到文件作用域、改为**直接调用** `rb_provide_feature`，最终 iOS App 链接会报
      `Undefined symbol: _rb_provide_feature`——它没被 `used` 锚点引用、且 MKXP.framework 未必
      把它重导出，成了链接期未定义符号（`5370dcc` 红，build-mkxp 过但 build-ios 挂）。
   **最终修法**：`Init_zlib` 与 `rb_provide_feature` 都用 `dlsym(RTLD_DEFAULT, "...")` 在运行时解析
   再调用，**彻底消除链接期引用**。运行时两符号一定在进程里（`used` 锚点强制保留 `Init_zlib`；
   `rb_provide_feature` 是 libruby 核心函数、被 `require`/extinit 自身引用，必定在场）。`mkxp_framework.cpp`
   的 `used` 锚点 `zlib_ext_anchor` 仍保留（确保 `Init_zlib` 不被死剥离，dlsym 才找得到）。
22. **sdl2-image 需显式开 JPEG**：vcpkg 默认不编 JPEG 解码 → 真机 `'JPEG images are not supported'`，
   启用 sdl2-image 的 JPEG feature（`build-mkxp.yml` 的 vcpkg install 加 `--recurse`）。
23. **Ruby GC 在 iOS 无 JIT 下是启动慢主因**：默认阈值对 Essentials 量级触发海量 GC；`mkxp_run` 在
   `ruby_init` 前 setenv 放大堆/malloc 阈值（见 `mkxp_framework.cpp`）。
24. **framework-entry.patch 现已 4 个 hunk**（原 2 个）：input.cpp（反查表）+ main.cpp（线程拆分）+
   eventthread.cpp（`MKXPZ_IOS_EMBED` 守卫）+ binding-mri.cpp（zlib 兜底+打点）。改 mkxp-z 源码仍以
   patch 为准，勿直接改 clone；生成 patch 务必 `newline="\n"`（见接手须知 #4）。
25. **交叉编译静态 Ruby 的 Encoding 常量可能缺失（2026-10-17）**：zlib 修好后脚本 `exec` 阶段立刻报
   `uninitialized constant Encoding::UTF_8 (NameError)`（Section004:5，游戏脚本早期就引用）。
   根因待定（编码注册了但常量没定义，或 `enc` 对象根本没链进 libruby-static.a）。修法 =
   `binding-mri.cpp` 初始化里加**编码常量守卫**：对 UTF-8/US-ASCII/ASCII-8BIT/UTF-16LE/UTF-16BE/
   EUC-JP/Shift_JIS/Windows-31J 逐个 `rb_enc_find`，编码在但常量缺就 `rb_define_const` 补上
   （日志 `rgss: defined Encoding::X`）；编码本身没注册则打 WARNING（`rgss: WARNING encoding X
   not registered`）——若真机日志出 WARNING，说明构建缺 `enc` 对象，下一步要去 `build_mkxp_ios.sh`
   手工编 enc/encdb.c、enc/us_ascii.c、enc/utf_8.c 等合进静态库（同 zlib_ext.o 方案）。

## 下一步该做什么（2026-10-20 更新）

M2 已全部完成；M3 真机调通 + 九运行时修复（①BGM **已根治（f33e34b）**、③加载 已修，EventScriptError 已根治、**⑤退出闪退已根治（7e1e20b）**、**⑥运行中闪退 OOM jetsam 已根治（8548a7c）**、**⑦菜单光标不更新已根治（5e251a9）**、**⑧private 方法显式接收者 NoMethodError 已根治（33ab2b3）**、**⑨诊断包装每帧开销卡顿闪退已根治（934fdc0）**）；②撕裂已加 glFinish
修复（待真机验证）、④文本待定位上游、**byte order 撤回（c7e2f27）**。构建冲突已修通；当前最新 `934fdc0`（CI 双绿，artifact 已发布）。剩余真实待办：

1. **② 撕裂修复真机验证**：`d55c23d` 已在 ios_embed.mm 软呈现读回前加 glFinish()（强制整帧画完再读回，消除
   Metal 异步读回半帧）。侧载后到室外大地图跑几分钟验证；若仍裂，下一步给 UIImageView 上屏加 CADisplayLink
   对齐 vblank；若感觉掉帧，把 glFinish 换成更轻的 glFenceSync 精准同步。
2. **④ 消息框少字定位+根治**：已锤定「引擎不丢字、是上游脚本按字节/宽度切片丢整字」。需用**低开销**方式定位
   上游排版方法（勿在 draw_text/pbDrawTextPositions 热路径加 caller/inspect 重日志——两度引发红线/撕裂回归），
   或用户提供 `Scripts.rxdata` 直接读消息框排版源码；定位后用 `ios_hook.rb` 重定义该方法（码点安全版）修掉。
   装 `a93647d` 后查 mkxp.log 里 `mkxp-font: scanned path=` 与 `mkxp-font: FALLBACK requested=` 行确认 iOS
   字体 family 解析情况（已知 essentials 用了 `Fusion Pixel 12px Monospaced zh_hans` 但 TTF 内部
   name ID 1 实际是另一字符串——确认这条即可定位）。
3. ~~**退出崩溃（signal=5）**：已根治（`7e1e20b`）。每次退出都崩在 SDL_DestroyWindow -> UIKit_HideWindow 主线程断言；真机日志 15 次复现。修：dispatch_async 推主线程。详见下方 M3 修复条目。~~
4. ~~**运行中崩溃（OOM jetsam）**：已根治（`8548a7c`）。phys_footprint 1.3GB 触发 iOS jetsam 杀进程（无 crash 日志）。修：decode cache 192→96MB + 取消 tileset pin。详见下方 M3 修复条目。~~
5. **byte order 撤回（c7e2f27）**：之前 1f6230e 误把 `kCGBitmapByteOrder32Big` 改 `Little`——按 Apple 文档 8-bit 组件下两者等价；撤回后画面色彩是否恢复正常待用户验。
6. **可选打磨**：开 `UIFileSharingEnabled`；触感反馈；`mkxp.log` 实时刷新。

### M3 修复：BGM 获得物品后不继续播放（`f33e34b`，2026-10-20 真机验过）

**根因**：pristine mkxp-z v2.4.2 源码有 2 个 bug 同时作用，导致 ME 结束后 BGM 永远静默（不是重启/重复，是音量卡 0 + AL 源永远 STOPPED）：

1. **`src/audio/audio.cpp:218` meWatchFun MePlaying case state 覆盖**：`meWatch.state = MeNotPlaying;` 写在 for 循环体内，每轮 track 都把上面的 `meWatch.state = BgmFadingIn` 覆盖 → ME 结束后 BGM 永远走不到 BgmFadingIn 分支做音量 fade-in（被 BgmFadingOut 设为 0 后永远回不来）。**修**：把 MeNotPlaying 移到 for 循环外，仅在 `state != BgmFadingIn` 时设置。

2. **`src/audio/alstream.cpp:313-316` pauseStream preemptPause race**：`if (AL::Source::getState(alSrc) != AL_PLAYING) preemptPause = true;` —— pause 命中的瞬间 AL 源刚好 STOPPED，preemptPause=true，resumeStream 见 true 跳 play() → AL 源永远 STOPPED。**修**：pauseStream 不再 memo preemptPause；resumeStream 无条件 `AL::Source::play(alSrc)`（OpenAL 规范：PLAYING 上 play 是 no-op，不重启；从 PAUSED 是 resume；从 STOPPED 是 restart，从根消除 race，零回归风险）。

**关键诊断点**：之前的 `mkxp_2026-10-19T22-47-40.218013.log` 显示 `bgm heal attempt 1 alstate=4116 × 73` 反复出现，但**修了我自己之前的 checkStopped heal 也没用**——framework 自带的 heal 是症状放大器（每帧 stopStream+startStream 杀流线程），真因在 pristine 源码。看 `audio.cpp` meWatchFun 状态机和 `alstream.cpp` pauseStream/resumeStream 是唯一正解。

**真机验**：2026-10-20 用户确认"修好了"——获得物品 → ME 结束 → BGM 1 秒内 fade-in 回原音量（不是重启/重复），`bgm heal attempt` 计数不再反复 attempt1。

**副作用/下一轮**：
- framework 自带 `alstream.cpp checkStopped` 的 heal 太激进（每帧杀流线程）待清理：改成只调 AL::Source::play(alSrc) 不杀流线程；heartbeat 移到 `meWatch.state == MeNotPlaying` 才跑（避免 ME 中与 meWatch 抢时序）
- ~~`Tileset Outside 150ms 重解码 cache miss` 与 `文本缺字` 两项仍挂账，下一轮一次打包~~

### M3 修复：运行中闪退（OOM jetsam，用户感知"运行中崩"）（`8548a7c`，待真机验）

**根因**（由 `mkxp_2026-10-20T19-52-41.401223.log` 实锤，**注意与"退出时崩"是不同 bug**，参见上面"下一步 #3 已根治"的 signal=5 那条）：

内存序列（每 600 帧采样，iOS 引擎端通过 task_info(TASK_VM_INFO) 读 phys_footprint）：

```
L15    present#709  phys=1325.7 MB  ← 启动 700+ 帧时已 1.3GB
L28443 present#705  phys=1113.5 MB  ← 持续 1.1GB+
L30096 present#458  phys=1309.1 MB  ← 峰值 1.3GB
L31212 present#457  phys= 470.0 MB  ← **iOS jetsam 杀进程后重启**（无 Shutting down 日志）
L33687 present#692  phys=1045.5 MB  ← 重启后再次涨到 1GB+
L34751 present#418  phys= 378.3 MB  ← 又被 jetsam 杀
```

iPhone 给单 App 物理内存上限 1.5-2GB；phys_footprint 1.3GB 离阈值很近，资源加载瞬时超阈值 → iOS jetsam 杀进程。**没有 crash 日志，没有 Shutting down**——用户感知的"运行中崩"就是这个。

**真因**：
1. `framework-entry.patch` 的 `DecodedPixelCache` 上限 **192MB**
2. tileset **pin** 永不驱逐（Outside=38MB / Exterior1-7 各 1-2MB 等巨型 tileset 永远不被 LRU 替换）
3. 加上引擎/Ruby heap/iOS framework 分配，工作集稳定 1.1-1.3GB

pin 是早期为"Outdoor 地图重入有 150ms re-decode hitch"加的优化——**反模式**：占用 1GB+ 持久内存换 150ms 偶发卡顿，远不如让 LRU 正常工作 + 用户接受 150ms 重入卡顿。

**修法**（`scripts/mkxp-framework/framework-entry.patch`，本轮同步修了 patch hunk 链式偏移 bug，详见 `feedback_patch_hunk_alignment.md`）：

```cpp
static const int64_t CAP_BYTES = 96LL * 1024 * 1024;  // 192MB → 96MB
// 取消 tileset pin：
// while (totalBytes + add > CAP_BYTES && lru.size() > 0) {
//     auto oit = map.find(lru.back());
//     map.erase(oit); lru.pop_back();
// }
```

**真机验**（待用户装 `a93647d` 后）：
- mem@present#N 序列应在 600-800MB 稳定（之前 1.3GB）
- 跑 30 分钟以上不再 jetsam 杀
- 地图重入（室外↔室内）会有 ~150ms re-decode 卡顿（用户可接受，OOM 杀进程不可接受）

**关键诊断手段**：iOS 引擎端**直接读 task_info**——`ios_embed.mm:317` 的 `mkxp_logMemoryFootprint` 是无 Mac 调试 iOS OOM 的核心代偿。看 mem@present#N 序列定位峰值 + 跌幅（OOM kill 标志）+ 涨速（泄漏率）。

**附记**：日志里 82 次 `pixman_region_union_rect Invalid rectangle passed` 已**根治于 5e251a9**——是 iOS 菜单光标不更新真因，详见下一条目。

### M3 修复：菜单光标不更新（iOS 独有，PC 正常）（`5e251a9`，2026-10-20 待真机验）

**症状**：菜单上下键移动，光标视觉不更新（▶ 仍停在第一行），但按 C 实际命中不同选项——Ruby 端 `@index` 已移，**Sprite 视觉没跟**。**PC 跑同一游戏无此问题**。

**根因**（由 `mkxp_2026-10-20T19-52-41.401223.log` 实锤，82 次 `*** BUG *** Invalid rectangle passed`）：

mkxp-z iOS 软呈现路径：`Bitmap::addTaintedArea` → `pixman_region_union_rect` → GL sub-upload → `glReadPixels` → `CGImageCreate` → `UIImageView`。pristine mkxp-z v2.4.2 的 `addTaintedArea` 只做 `normalizedRect`（处理 w/h 负数），**不 clamp 到 bitmap 真实边界**。当 sprite 光标或其他 blit 触发的 destRect 出现 `x<0` / `y<0` / `x+w>bmpW` / `y+h>bmpH`：

1. pixman 报 `Invalid rectangle passed` BUG
2. tainted region 状态被污染
3. 后续 GL sub-upload 用错的 tainted rect → Sprite 内容没真上传到 GL 纹理
4. 软呈现 `glReadPixels` 拿到旧像素 → UIImage 不动 → 光标冻结

PC 端 GL framebuffer 直接渲染到 SDL 窗口，tainted region 只用于 fast-path 优化（`if (opacity == 255 && !touchesTaintedArea) GLMeta::blitBegin`），错了也只是性能损失，**不影响显示**。

**修法**（`scripts/build_mkxp_ios.sh:651` 3a-2 段，apply 在 pristine 上、`framework-entry.patch` 之前）：

```cpp
void addTaintedArea(const IntRect &rect) {
    IntRect norm = normalizedRect(rect);
    int bmpW = self->width();   // 考虑 megaSurface / animation
    int bmpH = self->height();
    if (norm.x < 0) { norm.w += norm.x; norm.x = 0; }
    if (norm.y < 0) { norm.h += norm.y; norm.y = 0; }
    if (norm.x >= bmpW || norm.y >= bmpH) { /* skip + log oob */ return; }
    if (norm.x + norm.w > bmpW) norm.w = bmpW - norm.x;
    if (norm.y + norm.h > bmpH) norm.h = bmpH - norm.y;
    if (norm.w <= 0 || norm.h <= 0) { /* skip + log */ return; }
    pixman_region_union_rect(&tainted, &tainted, norm.x, norm.y, norm.w, norm.h);
}
```

**真机验**（待用户装 `5e251a9` 后）：
1. 任意 Window_Command 菜单按上下键：视觉光标应**同步移动**
2. mkxp.log 应**不出现**新 `rgss: tainted oob` 行（说明光标走的是合法坐标路径）
3. `*** BUG *** Invalid rectangle passed` 在新包应从 82 次降到个位数（剩余的可能是真正的越界 cursor y）

**附记**：`substractTaintedArea` 现有守护只防 `w<=0 / h<=0`，**没守越界**——同样需要 `self->width()/height()` clamp。下一轮补（5e251a9 暂未包含）。

### M3 修复：退出闪退 `signal=5` 根治（`7e1e20b`，2026-10-20 真机验过）

**根因**（由 `mkxp_2026-10-20T19-52-41.401223.log` 实锤，15 次复现调用栈完全一致）：
```
EventThread termination requested
RGSS thread ack'd request after 0 ms
Shutting down.
[crash-sig] signal=5 addr=0x1b63a1ae8 backtrace:
11  Runner   UIKit_HideWindow + 52
12  Runner   SDL_HideWindow + 144
13  Runner   SDL_DestroyWindow + 124
14  Runner   __thread_proxy ... mkxp_z_main::$_0 + 1276   ← RGSS pthread 后台线程
15  libsystem_pthread.dylib  _pthread_start
```

iOS 26 起 `UIKit_HideWindow` 抛 `NSInternalInconsistencyException 'Call must be made on main thread'`，
但 `SDL_DestroyWindow` 是 RGSS 后台线程调的后置清理——撞 UIKit 主线程断言 → `SIGTRAP(5)` 杀进程。

**修法**（`scripts/build_mkxp_ios.sh:934`）：
```cpp
#if defined(__APPLE__)  // 守护：Mach-O 二进制必定义；非 Apple 平台走原路径
    __block SDL_Window *winToDestroy = rtData->window;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (winToDestroy) SDL_DestroyWindow(winToDestroy);
    });
#else
    alcCloseDevice(rtData->alcDev);
    SDL_DestroyWindow(rtData->window);
#endif
```
dispatch_async 把销毁推 UIKit 主线程队列，下次主线程 loop 释放——满足 iOS 主线程约束。

**dc5dba4 守卫误用 bug（已修）**：第一版用 `#if defined(__APPLE__)` 包裹 dispatch.h include，注入点落在
`#ifdef MKXPZ_BUILD_XCODE` 块**内部**。但我们的 CMake（手搓 mkxp-cmake）定义的是
**`MKXPZ_IOS_EMBED`**，不是 `MKXPZ_BUILD_XCODE`（Xcode 工程模板用的）。结果整块 `#ifdef` 在 iOS build 里
是关闭的，dispatch.h 没被包含 → CI `undeclared identifier dispatch_get_main_queue`。
本轮修：注入点改到无条件 include 区（紧跟 `#include <SDL_ttf.h>`），守卫改 `#if MKXPZ_IOS_EMBED`。
dispatch_async 块仍用 `#if defined(__APPLE__)`（独立且必然定义），二者解耦。

**真机验**（待你装 `7e1e20b` 后）：
- 退出游戏 → mkxp.log 末尾应见 `Shutting down.` 而后**无 `[crash-sig]`**
- 重复 5 次进出游戏确认稳定
- `mkxp-font: scanned path=` 与 `mkxp-font: FALLBACK requested=` 同时上 log → 拿到 iOS 端
  TTF_FontFaceFamilyName 实际返回值，下一轮精准修少字

## M1 后续必做（`libmkxp.a` 编通后，A/B/C 均已实现，仅作决策留档）

**A. 重构 `src/main.cpp` 的 `int main()` → `mkxp_run(const char* gamePath)`**
- 去掉 `uiView` 参数（浮层方案：SDL 自建全屏窗口，不需要 Flutter 给 UIView）；
- 必须在**后台线程**跑（原 `eventThread.process()` 阻塞）；
- 同时提供 `mkxp_key(int rgssKey, int down)`（向引擎推按键事件）与 `mkxp_quit()`；
- `mkxp/ios/MKXP.framework/Headers/MKXP.h` 里的 `mkxp_run` 签名已同步去掉 `uiView`。

**B. Flutter 桥接改成「透明浮层」**
- `ios/Runner/MkxpPlatformView.swift` 不再走 `UiKitView` 内嵌 SDL 视图，
  改为调用 `mkxp_run` 在后台线程启动引擎；
- `lib/widgets/game_view.dart` 去掉 `UiKitView`，改透明 `Stack` + `touch_pad` 叠加；
- 取消 `mkxp/ios/mkxp.podspec` 第 17 行注释以链接框架。

**C. 两个 workflow 的串接（重要缺口）**
- `build-mkxp.yml` 把 `MKXP.framework` 只上传成 artifact，`ios.yml` 既没 `needs` 也没
  `download-artifact`，二者完全独立、不传产物。解决二选一：
  ① `build-mkxp.yml` 构建成功后 `git commit` 回 framework（重，二进制入库）；
  ② `ios.yml` 加 `needs: build-mkxp` + `download-artifact` 取 `MKXP-framework`。
- 没解决前，`ios.yml` 只能编 M0（不含引擎）。

## 嵌入方案（已定，勿回退到 UiKitView）

**SDL 全屏窗 + Flutter 透明浮层**。理由：mkxp-z 是独立 app、永远自己 `SDL_CreateWindow`，
无 `SDL_CreateWindowFrom` / `SDL_WINDOW_EXTERNAL`，也无 iOS UIView 嵌入代码，只导出标准
`int main()`。详见 README「嵌入方式决策」一节。

## 接手须知 / 协作约定（来自 AI 记忆，跨电脑保留）

> 换电脑后 AI 记忆不随仓库走，这几条是踩过坑才定下的，务必遵守：

1. **进度汇报要给「里程碑表」，不是只报当前单步**。每次 CI 出结果或被人问进度，先甩一张
   整体进度表（M0/M1/M2 各子项 完成/进行中/未开始），再讲细节。用户连续两次追问
   "现在到哪一步了" 才意识到单步汇报不够用。
2. **本仓库 commit message 绝对不能出现 `[skip ci]`（正文也不行）**。GitHub 只要在 HEAD
   提交信息**任意位置**看到这串就跳过 workflow，白等一轮 16 分钟。需要提"跳过机制"时写成
   `skip 标记` / `skip-ci`（去掉方括号）。若推送后 CI 没触发，第一反应查 HEAD 提交信息。
3. **免登录轮询 `api.github.com` 限额 60 次/小时**，CI 轮询要节制；配了 token 自动升到 5000。
   查失败摘要优先读 `ci-status` / `ci-status-ios` 分支的 `last-failure.md`（公开仓库免登录）。
4. **给 CI `git apply` 用的 patch 千万别带 CRLF**。在本机（Windows）用 Python 生成 patch 时，
   写文件必须 `open(path, "w", encoding="utf-8", newline="\n")`——否则 Windows 默认把 `\n`
   转 `\r\n`，patch 在 Linux 的 `git apply` 行尾对不上（CI 大多能容错，但本机校验会假失败、
   误以为 patch 写错）。本会话的 `framework-entry.patch` 已因此重生成过，切记。
5. **框架化改动只动两处**：`scripts/mkxp-framework/framework-entry.patch`（作用于 mkxp-z
   v2.4.2 源码：input.cpp 的 rgssKey→scancode 反查表 + main.cpp 的线程拆分）+ 
   `scripts/mkxp-framework/mkxp_framework.cpp`（引擎入口 `mkxp_run`/`mkxp_key`/`mkxp_quit`
   与 `g_engineRunning` 标志）。**改 mkxp-z 源码一律走 patch，不要直接改 clone**——CI 每次
   重新 clone mkxp-z 再 apply，直接改本地 clone 不会进仓库。
6. **线程模型（2026-10-16 定型）**：SDL_Init / 建窗 / 起 RGSS 线程在主线程（UIKit 安全，
   后台线程 `SDL_Init(VIDEO)`/`SDL_CreateWindow` 直接崩）；`EventThread.process()` 这个阻塞
   事件循环由 `mkxp_z_main` 内部甩到后台 `std::thread`，`mkxp_z_main` 立即返回，主线程 run loop
   不被占死 → Core Animation 才上得了屏。`MKXPZ_INIT_GL_LATER` 已在 CMake 定义，GL 上下文在
   rgssThread 创建，与事件循环线程无关。`g_engineRunning` 由后台线程在引擎真正退出时复位，
   框架层 `mkxp_run` 用它防重入（去掉了原 `static` 以便 main.cpp `extern` 引用）。

## 关键文件速查

| 文件 | 作用 |
|---|---|
| `scripts/build_mkxp_ios.sh` | 主构建脚本（Ruby / vcpkg / SDL2_sound / mkxp / framework） |
| `scripts/mkxp-cmake/CMakeLists.txt` | 手搓 CMake（源清单 / 宏 / xxd / find 库 / 链接） |
| `scripts/vcpkg-triplets/arm64-ios-static.cmake` | 静态 triplet |
| `mkxp/ios/Classes/*.swift` | Flutter 桥接骨架（M0，待改浮层） |
| `mkxp/ios/mkxp.podspec` | 链接框架处（第 17 行）待 uncomment |
| `.github/workflows/build-mkxp.yml` | 编 framework |
| `.github/workflows/ios.yml` | 编 App IPA |
| `README.md` | 进度 / 决策 / 路线图 |


## M3 运行时修复（2026-10-19，CI 待真机验）

> 一次性处理四个真机运行时问题；所有 mkxp-z C++ 改动进 `framework-entry.patch`，
> iOS 音频会话进 `ios_embed.mm`，文本防御进 `ios_hook.rb`。目标：装一次 IPA 验证全部。

### ① BGM 间歇性停止
- 根因：流式解码出错即永久 Stopped 无自愈（`alstream.cpp` checkStopped）；`vorbissource.cpp` ov_read<0 / OV_HOLE 致死；
  iOS 缺 `AVAudioSession` 中断/路由处理 -> 设备失效后 BGM 永久静音（"音频真空态"）。
- 修复：
  - `vorbissource.cpp`：`ov_read<0` 有限次（8）跳过重试，不再直接判死；
  - `alstream.cpp`：checkStopped 在 state==Playing 且 AL source 非 AL_PLAYING 时**有界自愈重启**（<=30 次、2s 节流），
    超限退化为原永久停止；
  - `audio.cpp`：MeNotPlaying 加 BGM 心跳（周期 queryState 触发自愈）；
  - `ios_embed.mm`：注册 `AVAudioSessionInterruptionNotification` / `RouteChangeNotification`，
    复用 `eventthread.cpp` 的 alcDevicePause+haltThreads / resume 逻辑（新增 `mkxp_ios_audioInterruptBegin/End`）；
    中断结束/路由变更后 `AVAudioSession setActive:YES` 重新激活会话。
- 真机验证：长时间播放不中断、循环不猝死、插拔耳机/来电后 BGM 自动恢复；日志 `rgss: bgm heal attempt`。

### ② 室外横向撕裂（横线/裂痕）
- 根因：VSync 默认关（`main.cpp` SetSwapInterval(0)），双缓冲不防无 VSync 翻面撕裂；室内帧差小不可见，室外明显。
- 修复：`main.cpp` iOS（`MKXPZ_IOS_EMBED`）强制 `SDL_GL_SetSwapInterval(1)`；日志打印 `swapInterval`。
- 真机验证：室外横线消失。

### ③ 室内->室外加载慢
- 根因：`Bitmap` 构造完全同步（RGSSAD 解密 + PNG 解码 + GPU 上传），无解码像素缓存；
  战斗返回/重进地图重复冷解码。
- 修复：`bitmap.cpp` 加**解码像素 LRU 缓存**（容量 64MB，按路径缓存解密后 ABGR8888 像素；
  命中即直接 `TEX::uploadImage`，不经过 SDL surface，**字节级等价于原上传，不串色**）；
  逐 Bitmap 各自拷贝上传，缓存只持不可变像素，绝不被 blt 改坏。
- 真机验证：日志 `rgss: decode-cache hits=... miss=...`；室内->室外/战斗返回耗时下降、cache hit 占多数。

### ④ 文本时不时少一两个字
- 根因（探查结论）：mkxp-z C++ `drawText` 对 UTF-8 正确，缺字几乎必然在**上游游戏脚本按字节切片多字节字符**
  （游戏脚本不在本仓，无法直改根因）。
- 修复（安全不回归）：`ios_hook.rb` 包装 `Bitmap#draw_text` / `draw_text_ex` ——
  诊断（bytes vs chars + 上游调用栈前几帧，定位切片方法）+ 防御（对不完整 UTF-8 尾部安全剥离，合法字符串不受影响）；
  hook 版本升至 v9。
- 真机验证：日志 `mkxp-text` 若出现 `INCOMPLETE UTF-8` 或 `draw_text bytes=...` 即定位到上游方法；
  文本尾部不再因不完整 UTF-8 乱码。

## CI 链复盘 + 全项目根因总表（2026-10-20 终版，接手先读）

### A. CI 链复盘（10-19～10-20，16 次：11 成功 / 5 失败）

| 时间(CST) | commit | 构建 | 真机表现 | 阶段/教训 |
|---|---|---|---|---|
| 12:18 | ffbbc26 | 成功 | 撕裂修好，其余待验 | 四修复首版 |
| 13:41 | cbf64c5 | 成功 | — | BGM 每帧自愈 + 缓存 key 归一化 |
| 14:05 | 8beee82 | 成功 | **标题红线** | 诊断回归①：pbDrawTextPositions 无节流 + caller 重日志 |
| 14:21 | 282ef3e | 成功 | 恢复 | revert 红线 |
| 14:43 | 485ea9b | 成功 | **撕裂复发** | 诊断回归②：draw_text caller[0..12] + str + 节流 300 |
| 17:43 | 29764ab | 成功 | 恢复 | revert 撕裂 |
| 20:41 | f91a992 | 成功 | 室外裂 | 另一 session：BGM gate + tileset 缓存 + 文本 trace |
| 21:43 | c6147a2 | 失败 | — | 构建失败 |
| 22:04 | 8f899b1 | 失败 | — | text-clip 锚点缩进错 → 签名 FATAL |
| 22:16 | 6bc3691 | 失败 | — | fprintf 格式串 \n 未闭合 |
| 22:22 | ccc340d | 成功 | 室外裂 | 修 fprintf |
| 23:06 | 297dedc | 成功 | 室外裂 | Bitmap 缺文件 → 1×1 fallback |
| 23:35 | e3deb9f | 失败 | — | showExc 签名在 binding/，校验只 grep src/ → 假 FATAL |
| 09:22(+1) | c59d575 | 失败 | — | bitmap.cpp 构造函数三处补丁冲突 → 丢 hunk → FATAL |
| 09:40(+1) | 4c3af4a | 成功 | 恢复正常 | 签名校验 grep 整棵树 → 首次出包 |
| 10:05(+1) | 32918a4 | 成功 | 正常（当前版） | has_follower 改 public → EventScriptError 根治 |

**链条规律**：① 两次真机回归都是"诊断代码"造成（热路径重日志）；② 5 次构建失败全是补丁/构建脚本问题（锚点/转义/grep 路径/冲突），非业务代码；③ 另一 session 的 C++ 改动因构建卡在签名校验，**从未被编译过**，直到 4c3af4a 才第一次真正编译。

### B. 全项目 Bug 根因总表（★已锤定 ◇疑似未验证）

**启动/画面（早期）**

| 现象 | 根因 | 修复 |
|---|---|---|
| 点启动闪退 | 引擎跑后台线程，SDL iOS 后端(UIWindow/CAEAGLLayer/UIKit)只认主线程 | dispatch_async 回主线程(625cbd5) |
| 无画面/卡启动 | EventThread.process() 占死主线程 run loop → CA 无法上屏 | 阻塞循环挪后台 thread、mkxp_z_main 立即返回(15ab649/baa3646) |
| zlib LoadError | 静态 Ruby zlib 扩展没初始化 | Init_zlib + rb_provide_feature(f41c059) |
| Encoding::* 缺失 | 静态 Ruby 没定义常量 | 常量守卫 |
| JPEG | sdl2-image | — |
| ★ ?-sprite | 解析器缓存**字符串所有权**：游戏 gsub! 原地改缓存共享对象 → 污染 → 解析失败 | 缓存/返回一律 dup(21e9c0e) |
| UIKit 崩溃 | — | MKXPZ_IOS_EMBED 守卫 |

**M3 运行时（10-19/20）**

| 现象 | 根因 | 修复 |
|---|---|---|
| ★ ① BGM 间歇停 | 解码错(ov_read<0/OV_HOLE/seek 失败)或 iOS 设备失效无自愈 | vorbissource 有限重试 + alstream checkStopped 自愈 + meWatchFun 每帧心跳 + ios_embed AVAudioSession 中断/路由；**自愈必须 gate(state==Playing && !sourceExhausted)**，否则误重启 SE/ME(实测 124 次) |
| ★ ② 室外撕裂(基础) | VSync 默认关 | main.cpp 强制 SDL_GL_SetSwapInterval(1) |
| ◇ ② 撕裂复发 | **真因（2026-10-20 查明）：iOS 走软呈现**（swz_presentRenderbuffer → mkxp_softPresent：glReadPixels 读回帧→UIImage→主线程 UIImageView 上屏，盖在 GL 视图上）；**VSync 只作用 EAGL swap，管不到软呈现的读回+UIImageView 上屏**；高负载下 Metal 异步读回半渲染帧→半帧呈现→撕裂（间歇/负载相关/与 commit 无关，实测没改代码也复现）。**旧"L599 导致复发"归因已否定** | **已实现待真机验证（d55c23d）**：ios_embed.mm 读回前加 glFinish() 强制整帧画完再读回；若未根治再上 CADisplayLink 对齐 vblank |
| ★ ③ 加载慢 | Bitmap 构造同步解码无缓存 | 解码像素 LRU 缓存(key 归一化、直接上传像素、勿整份 surface 拷贝、勿重复) |
| ★ ④ 消息框少 1-2 字 | **非引擎**：drawText 用 squeeze 压缩不裁切不丢字，传入字符串都合法完整；少字是**上游脚本按字节/宽度切片丢整字** | 须定位上游排版方法再用 ios_hook.rb 重定义(码点安全版)；引擎无法还原已丢字符 |
| ★ EventScriptError 弹窗 | [Following Pokemon EX] 显式接收者调 Game_Player 私有 has_follower → Ruby3.3 严禁"私有 + 显式接收者" → NoMethodError → rescue 包成 EventScriptError → SDL 弹窗 | ios_hook.rb 惰性 Game_Player.send(:public,:has_follower) + showExc 落日志不弹框 |

### C. 渲染热路径铁律（红线 + 撕裂同一根因，已锤定）
pbDrawTextPositions 与 Bitmap#draw_text 都是每帧热路径。在上面加日志必须：**(a) 硬节流(~40 次即停) (b) 不用 caller(caller[N] 每帧生成栈回溯很贵) (c) 不用大 inspect**。
- 反例(都已 revert)：8beee82 pbDrawTextPositions 无节流 + caller[0..7] + texts.inspect → 标题红线；485ea9b draw_text caller[0..12] + str + 节流 300 → 撕裂。
- 正例(32918a4 安全在跑)：pbDrawTextPositions 节流 40 + 无 caller；draw_text caller[0..3] + 节流 120。
- **撕裂真因是软呈现缺帧同步（见 B⑨），不是渲染被拖慢**：VSync 只减轻（管 EAGL swap），管不到软呈现的读回+UIImageView 上屏；高负载下半帧呈现→裂。**已实现修复（d55c23d，待真机验证）：读回前 glFinish() 强制整帧画完**。热路径铁律防的是另一类"拖慢渲染的 artifact"，两者别混。

### D. 构建/CI 铁律

| 现象 | 根因 | 修复 |
|---|---|---|
| FATAL(bitmap.cpp) | 构建脚本补丁(L599/L712)与 framework-entry.patch 都改 Bitmap 构造函数 → 冲突 → patch -f 静默丢 hunk → 签名缺失 | 删 L599/L712，缓存 + fallback 并入 framework-entry.patch 独管构造函数 |
| 假 FATAL(showExc) | 签名校验 grep 只搜 src/，签名在 binding/binding-mri.cpp | grep 改整棵 $MKXP_SRC |
| CI git apply 失败 | framework-entry.patch 带 CRLF | 必须 open(...,newline="n") 写 LF |
| 没 IPA 可装 | 只有 CI conclusion=success 才出 artifact | 装前先查 Actions conclusion |

### M3 修复：private 方法显式接收者 NoMethodError 根治（`33ab2b3`，待真机验）

**症状**：战斗/事件时弹 `NoMethodError: private method 'X' called for ...`（被
`execute_script` rescue 包成 `EventScriptError` 弹窗）。已逐个遇过
`Game_Player#has_follower`（Following Pokemon EX）、
`Battle::AI#calculate_entry_hazard_damage`（Gen 9 Pack + Deluxe Battle Kit）。

**根因**：RPG Maker XP / Essentials 生态大量「显式接收者调用 private 方法」。
PC 上老 RGSS Ruby 不报（同一游戏 PC 正常），但 iOS mkxp-z 的 MRI 3.x 严格禁止
「private 方法 + 显式接收者」→ NoMethodError。

**为何不能逐个打补丁**：这类 private 调用散落 Gen 9 Pack / Deluxe Battle Kit /
Following Pokemon EX 等各插件，逐个加定向补丁不可持续（用户原话「既然很多地方
都有这个 private 问题，有没有办法根治」）。

**根治**（`scripts/mkxp-framework/ios_hook.rb` 顶部，游戏脚本加载前 eval）：把
`Module#private` / `Module#private_class_method` 重定义为 no-op——所有方法保持
public，所有显式接收者调用都合法。

```ruby
class Module
  alias_method :__mkxp_orig_private, :private
  def private(*args, &blk); end
  alias_method :__mkxp_orig_private_class_method, :private_class_method
  def private_class_method(*args, &blk); end
end
```

**Why 安全**：private 仅是访问控制，不改变任何逻辑；Ruby stdlib 与 MKXP C++ 绑定
（`rb_define_private_method` 走 C 层 API，不经过 Ruby 的 `Module#private`）已在
ios_hook 注入**之前**加载完，不受重定义影响。本地 Ruby 验证：`private def secret`
与 `private; def secret2` 两种形式 no-op 后均变 public，`f.secret` 调用成功。
注意 `Module` 是 class 不是 module，重开必须 `class Module`（否则
`Module is not a module` TypeError）。

**真机验**：装 `33ab2b3` 后所有「private method called」类 NoMethodError 应一次性
消失；mkxp.log 打 `Module#private neutered` 确认生效。`has_follower` /
`ai_hazard` 定向补丁保留作双保险（no-op 后等于 no-op）。

### M3 修复：诊断包装每帧开销导致卡顿+闪退（`934fdc0`，2026-10-20 待真机验）

**症状**：装 `33ab2b3` 后「app 很卡 + 运行日志打不开 + 闪退」。

**根因**（代码审查定位，非日志）：`scripts/mkxp-framework/ios_hook.rb` 为查
「文本缺字/？精灵」包装了三个**每帧热路径**方法——
`Bitmap#draw_text` / `draw_text_ex`（`__mkxp_wrap_text_method`）、
`Object#pbDrawTextPositions`（`method_added` 分支）。游戏每帧渲染 `draw_text`
几百次，每次包装都执行 `args.index` + `String#dup` + `force_encoding(UTF_8)` +
`valid_encoding?`（`pbDrawTextPositions` 还有 `textpos.map{...}.join` +
`force_encoding`）。在 iPhone 上累积成显著 CPU 开销 → 卡顿 → 每帧临时字符串分配
推高 GC + 软呈现 `glReadPixels` 大纹理 → 内存压力 → **iOS jetsam 闪退**；App 卡死
后日志页也打不开。

注意：诊断**日志**本身有流控（dtp ≤40 / text ≤120），但**包装逻辑每帧执行**，
日志限流掩盖不了 CPU 开销——与 OOM（8548a7c）是不同类性能根因。

**修法**（`ios_hook.rb` 顶部加编译期常量 `$__mkxp_diag = false`）：
- 非诊断期 `pbDrawTextPositions` 分支不重定义 → 走原 MKXP 实现（零 Ruby 开销）
- `__mkxp_wrap_text_method` 开头 `return unless $__mkxp_diag` → draw_text/draw_text_ex 不包装
- ？精灵/BGM 等**功能性修复**（`pbGetFileChar`/`pbTryString`/`pbResolveBitmap`/
  `ow_sprite_filename`/`getPlayTime`，非每帧）**不受开关影响**，始终生效
- `private` no-op 根治（33ab2b3）已让 `has_follower`/`ai_hazard` 是 public，定向补丁
  冗余，非诊断期去掉其热路径触发无副作用

**Why 编译期常量而非 env**：iOS 沙盒进程取不到自定义 `MKXP_DIAG` env（需原生侧
`setenv`）。需重新诊断文本/精灵时把 `$__mkxp_diag` 改 `true` 重 CI。

**真机验**：装 `934fdc0` 后应明显流畅、不再闪退、日志页可正常打开。若仍闪退 →
查 mkxp.log 的 `mem@present#N` 峰值是否 OOM 回归（8548a7c 类），或仍有新每帧包装。

### E. 未修
- 退出时 signal=5 崩 SDL_DestroyWindow/UIKit_HideWindow：**间歇性**；修复 has_follower 后（RGSS 线程能干净退出）近期未复现，但根因（后台线程销毁窗口碰 UIKit 断言）未根治，待观察；若复现需把退出时窗口销毁挪主线程。
