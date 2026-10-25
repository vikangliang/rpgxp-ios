// ios_embed.mm — iOS 嵌入（SDL 官方路径 + 软呈现）。
//
// 诊断结论链（2026-10-18 坐实）：
//   - mkxp 场景 FBO 渲染正常（probe nonBlack=56/64 max=255）；
//   - EAGL 默认帧缓冲呈现链路不可用：present 后颜色缓冲被作废，FBO 0 不完整，
//     之后所有往它的绘制都被驱动以 GL_INVALID_OPERATION(0x502) 拒绝；
//   - 因此画面走【软呈现】：present 钩子里从场景 FBO glReadPixels 读回像素，
//     包成 CGImage 交给满屏 UIImageView(ScaleAspectFit) 显示 —— 实测已出画面。
//
// 注意：不要往默认帧缓冲(FBO 0)上做任何绘制/回读实验，会污染 mkxp 的 GL 状态
// 且全部无效（见上面的 0x502）。EAGL 只保留 SDL 原生的 present 动作。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <stdio.h>
#import <sys/stat.h>
#import <stdlib.h>
#import <unistd.h>
#import <signal.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <stdatomic.h>
#import <objc/runtime.h>

static UIView *g_hostView = nil;
static SDL_Window *g_win = NULL;
static Uint32 g_iosWinId = 0;   // mkxp_ios_embedIntoView 取 SDL 窗口 ID，鼠标注入事件用
static UIWindow *g_sdlWin = nil;
static int g_drawW = 0, g_drawH = 0;   // renderbufferStorage 时记录的 drawable 像素尺寸

// ---- EAGL hook（模块加载即装，早于 SDL initGL） ----
static void (*g_origRBS)(id, SEL, NSUInteger, id);
static BOOL (*g_origPresent)(id, SEL, NSUInteger);
static uint64_t g_presentTotal = 0;

/* 由 mkxp 的 graphics.cpp 提供：当前合成结果纹理/FBO + letterbox 几何 */
extern "C" void mkxp_ios_getScene(GLuint *tex, GLuint *fbo, int *sw, int *sh,
                                  int *ox, int *oy, int *ww, int *wh);

/* ===================== 软呈现 =====================
 *   1) 从场景 FBO 用 glReadPixels 读回像素（FBO 回读实测可用）；
 *   2) 直接管原始行序包成 CGImage（CFData 拷贝一份，避免缓冲复用导致撕裂）。
 *      注意【不做行翻转】：mkxp 渲染进 FBO 时已用翻转投影补偿 RGSS 左上角
 *      坐标系（它自己上屏时由 metaBlitBufferFlippedScaled 再翻一次），
 *      所以 readback 的行序恰好就是显示行序；真机实测再翻一次会上下颠倒。 */
static UIImageView *g_softView = nil;

/* ---- 软呈现布局 + 最近邻上采样 ----
 * 【为什么自己做上采样，而不是靠 layer.magnificationFilter】
 * 画面是 512x384 的帧经 glReadPixels 读回后包成 CGImage 交给 UIImageView。
 * retina 屏上 UIImageView 把 512x384 放大到 ~1572x1179 物理像素是 3x 放大，
 * CoreAnimation 用双线性插值把精灵图/文字抹糊——比 PC(1.5x)糊。
 * 之前试过直接设 layer.magnificationFilter=kCAFilterNearest，但 UIImageView 从
 * 小尺寸源放大时并不吃这个过滤(实测仍糊)，故改为【自己用最近邻把帧放大到屏幕
 * 实际像素分辨率】，再由 UIImageView 1:1 呈现(CoreAnimation 不做任何重采样)，
 * 必然锐利、像素网格均匀。 */
static uint8_t *g_upBuf[2] = {NULL, NULL};  // 上采样乒乓缓冲，避免显示侧异步读时写冲突
static int g_upW = 0, g_upH = 0;
static int g_upIdx = 0;
static int g_softW = 0, g_softH = 0;        // 场景尺寸(读回缓冲宽高)，布局按 AspectFit 计算用

/* 最近邻上采样：手写逐像素最近邻拷贝到 dw x dh，再包成 CGImage 交给 UIImageView
 * 1:1 呈现(CoreAnimation 不再做任何重采样)。
 * 【为什么不用 CGContextDrawImage + kCGInterpolationNone】
 * iOS 上 CoreGraphics 对 CGContextDrawImage 的插值质量常被静默忽略、回退双线性——
 * 这正是 54fa1be(CA magnificationFilter) 与 e702867(CG DrawImage) 两次“最近邻”都仍糊
 * 的统一根因。这里直接逐像素取源像素 = floor(dst*src/dst)，100% 最近邻，不依赖任何
 * CG 插值设置。乒乓缓冲(2块)避免显示侧异步读时写冲突；x/y 映射表按尺寸缓存避免每帧重算。 */
static int *g_mapX = NULL, *g_mapY = NULL;
static int g_mapW = 0, g_mapH = 0;

static CGImageRef mkxp_upscaleNearest(CGImageRef src, int sw, int sh, int dw, int dh) {
    if (dw <= 0 || dh <= 0 || !src) return NULL;
    int idx = g_upIdx;
    if (g_upW != dw || g_upH != dh) {
        free(g_upBuf[0]); g_upBuf[0] = NULL;
        free(g_upBuf[1]); g_upBuf[1] = NULL;
        g_upW = dw; g_upH = dh;
        free(g_mapX); free(g_mapY);
        g_mapX = (int *)malloc((size_t)dw * sizeof(int));
        g_mapY = (int *)malloc((size_t)dh * sizeof(int));
        if (g_mapX && g_mapY) {
            for (int x = 0; x < dw; ++x) g_mapX[x] = (int)((long long)x * sw / dw);
            for (int y = 0; y < dh; ++y) g_mapY[y] = (int)((long long)y * sh / dh);
        }
        g_mapW = dw; g_mapH = dh;
    }
    if (!g_upBuf[idx]) g_upBuf[idx] = (uint8_t *)malloc((size_t)dw * (size_t)dh * 4);
    if (!g_upBuf[idx] || !g_mapX || !g_mapY) return NULL;

    /* 取源像素(RGBA, 4 字节/像素; stride 用 CGImageGetBytesPerRow 含对齐) */
    CGDataProviderRef dp = CGImageGetDataProvider(src);
    CFDataRef data = dp ? CGDataProviderCopyData(dp) : NULL;
    if (!data) return NULL;
    const uint8_t *sp = CFDataGetBytePtr(data);
    size_t sbpr = CGImageGetBytesPerRow(src);
    uint8_t *dpix = g_upBuf[idx];
    for (int y = 0; y < dh; ++y) {
        const uint8_t *srow = sp + (size_t)g_mapY[y] * sbpr;
        uint8_t *drow = dpix + (size_t)y * (size_t)dw * 4;
        for (int x = 0; x < dw; ++x) {
            const uint8_t *s = srow + (size_t)g_mapX[x] * 4;
            size_t o = (size_t)x * 4;
            drow[o]   = s[0];
            drow[o+1] = s[1];
            drow[o+2] = s[2];
            drow[o+3] = s[3];
        }
    }
    CFRelease(data);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(g_upBuf[idx], dw, dh, 8, (size_t)dw * 4, cs,
                                             kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast);
    CGImageRef out = NULL;
    if (ctx) {
        out = CGBitmapContextCreateImage(ctx);   /* 引用 g_upBuf[idx]，显示侧隔帧才复用 -> 安全 */
        CGContextRelease(ctx);
    }
    CGColorSpaceRelease(cs);
    g_upIdx = idx ^ 1;
    return out;
}

/* 按 AspectFit 把软呈现视图定位到屏幕中心(4:3 居中留黑边)；配合上面的最近邻
 * 上采样，视图尺寸 == 上采样后的图像尺寸，UIImageView 以 ScaleToFill 1:1 呈现，
 * CoreAnimation 不做重采样。尺寸未知时兜底 AspectFit。 */
static void mkxp_layoutSoftView(void) {
    if (!g_softView) return;
    UIView *parent = g_softView.superview;
    if (!parent) return;
    CGRect b = parent.bounds;
    if (b.size.width < 1.0 || b.size.height < 1.0) return;
    int sw = g_softW, sh = g_softH;
    if (sw > 0 && sh > 0) {
        CGFloat kw = b.size.width / (CGFloat)sw;
        CGFloat kh = b.size.height / (CGFloat)sh;
        CGFloat k = (kw < kh) ? kw : kh;
        CGFloat fw = (CGFloat)sw * k, fh = (CGFloat)sh * k;
        g_softView.frame = CGRectMake((b.size.width - fw) * 0.5,
                                      (b.size.height - fh) * 0.5, fw, fh);
        g_softView.contentMode = UIViewContentModeScaleToFill;
        g_softView.autoresizingMask = UIViewAutoresizingNone;
        g_softView.layer.magnificationFilter = kCAFilterNearest;
    } else {
        g_softView.contentMode = UIViewContentModeScaleAspectFit;
        g_softView.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                                      UIViewAutoresizingFlexibleHeight;
    }
}
static uint8_t *g_softBuf = NULL;    // 读回缓冲（行序 = 显示行序，见上）
/* 双缓冲乒乓：显示侧 CA 光栅化是【异步】的——pending 清零只代表 image 已设置，
 * render server 可能仍在读上一块缓冲的像素。若引擎线程立刻往同一块 memcpy
 * 下一帧，就会出现横向断纹（撕裂）。两块缓冲交替写，被引用的那块隔帧才复用。 */
static uint8_t *g_softDisp[2] = {NULL, NULL};
static int g_dispIdx = 0;
static uint64_t g_softFrames = 0;
/* 主线程上屏合并标志：避免主线程被 Flutter 浮层占满时，dispatch_async 的
 * UIImage 更新 block 堆积（每个持 ~786KB → 几秒内存爆掉被系统 jetsam 杀）。
 * 主线程没处理完上一帧就不发新帧（丢弃），把上屏节奏交给主线程自身。 */
static atomic_int g_softPending = 0;
/* 首帧已上屏标志（供 Flutter 加载提示轮询：>0 = 引擎已出画面） */
static atomic_int g_firstFrameShown = 0;
/* 生命周期：App 进后台时为 1，软呈现据此跳过 GL 工作 */
static volatile sig_atomic_t g_appBackgrounded = 0;

/* 供桥接层查询（MkxpPlugin "engineReady"）。extern "C"：本文件是 ObjC++，
 * 不加会被 C++ 改名，Swift 按纯 C 符号链接会报 Undefined symbol。 */
extern "C" int mkxp_ios_firstFrameShown(void) { return atomic_load(&g_firstFrameShown); }

/* FPS 角标：每帧 EAGL present 钩子(swz_presentRenderbuffer)自增 g_presentTotal，
 * 这里按 ~0.5s 窗口算平均帧率，供 MkxpTouchOverlay 原生角标显示。
 * 复用既有 g_presentTotal（presentRenderbuffer: 每帧必触发），无需改 graphics.cpp。 */
extern "C" double mkxp_get_avg_fps(void) {
    static uint64_t lastCount = 0;
    static double lastTime = 0;
    uint64_t now = g_presentTotal;
    double t = [[NSDate date] timeIntervalSince1970];
    if (lastTime == 0) { lastCount = now; lastTime = t; return 0.0; }
    double dt = t - lastTime;
    if (dt < 0.5) return 0.0;
    double fps = (double)(now - lastCount) / dt;
    lastCount = now; lastTime = t;
    return fps;
}

/* 音频会话中断/路由桥接：由 eventthread.cpp 提供，复用其暂停-恢复逻辑，
 * 让 OpenAL 设备在 iOS 中断/路由变更后保持有效，BGM 可自愈而非永久静音。 */
extern "C" void mkxp_ios_audioInterruptBegin(void);
extern "C" void mkxp_ios_audioInterruptEnd(void);

/* ---- spng A/B 开关（无需文件共享）----
 *   默认【关闭】spng（走旧 libpng 路径 = 控制组）；游戏画面上【三指轻点】
 *   实时开启 spng 快速路径。用于真机归因“颜色块闪烁”是 spng 解码还是
 *   软呈现读回。切换会清空解码缓存，后续 bitmap 用新设置重新解码；
 *   观察颜色块是否随切换变化即可。 */
static void mkxp_toggleSpng(void);
extern "C" void mkxp_ios_clear_decoded_cache(void);
@interface MkxpSpngToggle : NSObject
+ (void)onSpngTap:(UITapGestureRecognizer *)g;
@end
@implementation MkxpSpngToggle
+ (void)onSpngTap:(UITapGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateEnded) mkxp_toggleSpng();
}
@end

static volatile int g_spngOverride = -1;   /* -1=未手动切换(默认关), 0=开, 1=关 */
extern "C" int mkxp_ios_spng_disabled(void) {
    /* 默认关闭 spng（走旧 libpng 路径 = 控制组），三指轻点再开启做 A/B。
     * 这样无需文件共享即可真机归因“颜色块闪烁”是 spng 还是软呈现。 */
    if (g_spngOverride != -1) return g_spngOverride;
    return 1;
}
extern "C" void mkxp_ios_clear_decoded_cache(void);  /* 实现于 bitmap.cpp */
static void mkxp_toggleSpng(void) {
    g_spngOverride = (g_spngOverride == 1) ? 0 : 1;
    fprintf(stderr, "[ios-embed] spng override -> %s\n",
            g_spngOverride ? "DISABLED(libpng path)" : "ENABLED(spng path)");
    mkxp_ios_clear_decoded_cache();
    fprintf(stderr,
        "[ios-embed] spng A/B: 三指轻点再次切换；观察画面颜色块是否随切换变化\n");
}

/* iOS 触摸→鼠标注入：原生浮层(MkxpPassthroughView)在空白区捕获触摸后调用，
 * 把触摸转成 SDL 鼠标事件推入队列，驱动 RGSS Mouse 模块
 * （Pokémon Amie 等依赖鼠标的插件在 iOS 上才能用触摸）。
 * 位置用 SDL_WarpMouseInWindow：既更新 SDL 内部鼠标状态（覆盖事件驱动与轮询两种
 * 消费方式），又自动合成 SDL_MOUSEMOTION 事件；按键用 SDL_PushEvent 推
 * SDL_MOUSEBUTTONDOWN/UP（按钮状态 mkxp-z 走事件）。坐标用 UIKit 点(与 UITouch 一致)，
 * SDL UIKit 后端窗口尺寸即点，1:1 对应。 */
extern "C" void mkxp_ios_inject_mouse(float nx, float ny, int down) {
    static int g_down = 0;
    // nx,ny 为触摸在浮层(全屏)内的归一化坐标 0..1。SDL 窗口在 iOS 上按像素(retina)计，
    // 直接用 UIKit 点当坐标会整体缩到 ~1/3，小目标(如食物格)点不中。乘 SDL 窗口尺寸
    // 得到正确窗口坐标，point/pixel 两种单位都兼容。
    int winW = 0, winH = 0;
    if (g_win) SDL_GetWindowSize(g_win, &winW, &winH);
    int mx = (int)(nx * (float)winW);
    int my = (int)(ny * (float)winH);
    // 位置：warp 更新 SDL 内部鼠标状态（覆盖轮询消费）并合成 SDL_MOUSEMOTION；
    // 同时显式再推一条【带正确按键掩码(state)】的 SDL_MOUSEMOTION——
    // mkxp-z 的 Mouse 模块从 motion.state 读按键状态，若拖动时只靠 warp 合成的
    // motion(state=0) 会把按键复位成抬起，导致"按住拖动"(如拿食物)失效。真实鼠标
    // 按住拖动时 motion 也带 state，这里照做，按键状态在拖动全程保持。
    if (g_win) SDL_WarpMouseInWindow(g_win, (float)mx, (float)my);
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = SDL_MOUSEMOTION;
    ev.motion.x = mx;
    ev.motion.y = my;
    ev.motion.xrel = 0;
    ev.motion.yrel = 0;
    ev.motion.state = down ? SDL_BUTTON_LMASK : 0;
    ev.motion.windowID = g_iosWinId;
    SDL_PushEvent(&ev);
    if (down != g_down) {
        SDL_zero(ev);
        ev.type = down ? SDL_MOUSEBUTTONDOWN : SDL_MOUSEBUTTONUP;
        ev.button.button = SDL_BUTTON_LEFT;
        ev.button.state = down ? SDL_PRESSED : SDL_RELEASED;
        ev.button.x = mx;
        ev.button.y = my;
        ev.button.windowID = g_iosWinId;
        SDL_PushEvent(&ev);
        g_down = down;
    }
}

/* 三指截屏(spng 快速路径)切换：mkxp_toggleSpng 是 static，包一层 extern "C"
 * 供 Swift 浮层在接管空白区触摸后转发。 */
extern "C" void mkxp_ios_toggle_spng(void) { mkxp_toggleSpng(); }

/* 场景快照落盘：无 Mac 环境下定位“画面内容对不对”的铁证。
 * 在 Documents/scene_dump_N.png 生成 PNG，Flutter 日志页可直接查看/分享。 */
static void mkxp_dumpSceneToDoc(CGImageRef cg, uint64_t frameNo)
{
    /* Bug1/Bug2 取证：原实现只在 42/600/3600/10800 四个帧点落盘，几乎必然错过
     * "消息框少字 / 室外横线"的现场。改为【环形持续快照】：约 1 秒一张、文件名
     * 复用最近 kRing 个槽位 —— 玩家不需要掐时间，只要在有问题的画面停 1~2 秒，
     * Documents 里按修改时间排序最新的那几张 scene_dump_r*.png 就是现场证据。
     * 二分判据（决定下一步到底改哪一层）：
     *   - dump 里字完整 -> 少字在【上屏缩放/软呈现层】(与 Bug2 同源);
     *   - dump 里字就少 -> 少字在【游戏渲染层 bitmap 绘制】, 继续往 draw_text 下挖。 */
    /* 环形：文件名复用最近 kRing 个槽位，文件数恒定，不会随时间撑爆存储。
     * 配合外层约 1 秒的调用频率，等于保留"最近约 20 秒"的连续画面快照。 */
    static const int kRing = 20;
    static int seq = 0;
    int idx = seq % kRing;
    int no = seq;
    ++seq;

    @autoreleasepool {
        UIImage *img = [UIImage imageWithCGImage:cg];
        if (!img) return;
        NSData *png = UIImagePNGRepresentation(img);
        if (!png) return;
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        NSString *path = [docs stringByAppendingFormat:
            @"/scene_dump_r%02d.png", idx];
        [png writeToFile:path atomically:YES];
        if ((no % 5) == 0)
            fprintf(stderr, "[ios-embed] scene dump #%d frame=%llu -> %s (%dx%d)\n",
                    no, (unsigned long long)frameNo, path.UTF8String,
                    (int)CGImageGetWidth(cg), (int)CGImageGetHeight(cg));
    }
}

/* 内容哈希：内容没变就跳过软呈现，省 CPU/内存抖动（标题页静止时几乎全跳）。
 * 【必须全量】旧实现是抽样（每 h/24 行抽 1 行、每行每 97 字节≈24px 抽 1 字节），
 * 对稀疏小变化（消息框逐字出现的文字、单行 tile 变化）漏检率极高——
 * 内容变了却哈希相同 -> 跳过上屏 -> 屏幕停留在旧帧。这正是真机二分
 * （512x384 的 scene dump 里文字完整、屏幕上却"少字"）定位出的根因；
 * Bug2 的区域残留（横线）同理：局部小变化被抽样漏掉。
 * 全量 FNV-1a 遍历 786KB(512x384x4) 在现代 ARM 上约 0.03-0.1ms，开销可忽略；
 * 任何像素变化都必然改变哈希，漏检归零，"静止帧跳过上屏"的优化保留。 */
static uint32_t mkxp_hashScene(const uint8_t *flip, int w, int h)
{
    uint32_t hsh = 2166136261u;
    size_t bytes = (size_t)w * 4 * (size_t)h;
    for (size_t i = 0; i < bytes; ++i)
        hsh = (hsh ^ flip[i]) * 16777619u;
    return hsh;
}

static void mkxp_softPresent()
{
    /* 后台时跳过一切 GL 读回/显示（避免后台 GPU 提交 + 省内存） */
    if (g_appBackgrounded) return;

    GLuint tex = 0, fbo = 0;
    int sw = 0, sh = 0, ox = 0, oy = 0, ww = 0, wh = 0;
    mkxp_ios_getScene(&tex, &fbo, &sw, &sh, &ox, &oy, &ww, &wh);
    if (!fbo || sw <= 0 || sh <= 0) return;

    /* 每帧都尝试上屏：静止帧由下方 hash 跳过（几乎零成本），动画帧以引擎满帧率
     * 显示，避免之前“每 3 帧才上屏→显示仅 ~20fps→动画看着速度不对/卡顿”。
     * 内存泄漏已通过零拷贝复用缓冲根治，无需再用降频压内存。 */
    ++g_softFrames;

    /* 引擎重启探测器：软呈现帧计数器只增不减；若它回退，说明引擎被重新
     * launch（mkxp_run 再次调用）→ “bgm+画面隔几秒重启”的定性铁证。 */
    {
        static uint64_t s_prev = 0;
        if (g_softFrames < s_prev)
            fprintf(stderr,
                    "[ios-embed] *** ENGINE RESTARTED (frame %llu -> %llu) ***\n",
                    (unsigned long long)s_prev, (unsigned long long)g_softFrames);
        s_prev = g_softFrames;
    }

    if (sw != g_softW || sh != g_softH) {
        free(g_softBuf);
        free(g_softDisp[0]);
        free(g_softDisp[1]);
        g_softW = sw;
        g_softH = sh;
        g_softBuf = (uint8_t *)malloc((size_t)sw * sh * 4);
        g_softDisp[0] = (uint8_t *)malloc((size_t)sw * sh * 4);
        g_softDisp[1] = (uint8_t *)malloc((size_t)sw * sh * 4);
    }
    if (!g_softBuf || !g_softDisp[0] || !g_softDisp[1]) return;

    GLint prevFbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    /* 撕裂根治：iOS(Metal 后端)下 glReadPixels 不保证等 GPU 画完，高负载时会读回
     * 半渲染帧 → UIImageView 呈现半帧 → 横向撕裂（PC 的 SDL swap 由驱动保证原子
     * +VSync，无此问题）。glFinish() 强制本帧 GL 命令全部完成后再读回，确保读到
     * 完整一整帧。代价是每帧多等一次 GPU，换取不裂。 */
    glFinish();
    /* 清掉此前积压的 GL 错误（如启动首帧的 0x502）：glGetError 返回的是全局
     * 错误标志，不清就会把"历史错误"误判成本次 readback 失败 -> 整帧 return
     * 丢帧。清空后，只有本次 readback 真正出错才会触发下面的 return。 */
    while (glGetError() != GL_NO_ERROR) {}
    glReadPixels(0, 0, sw, sh, GL_RGBA, GL_UNSIGNED_BYTE, g_softBuf);
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);

    GLenum e = glGetError();
    if (e != GL_NO_ERROR) {
        /* 取证增强（不改行为，仍 return）：readback 失败会让【整帧完全不上屏】，
         * 是"少字/横线"这类局部缺失的共同嫌疑。原日志限频仅 3 次且不带帧号，
         * 无法判断它是否持续发生；这里放开到 30 次并补上帧号/readback 尺寸。 */
        static int errLogged = 0;
        if (errLogged < 30) {
            ++errLogged;
            fprintf(stderr, "[ios-embed] softPresent readback err=0x%x prevFbo=%d "
                            "read=%dx%d (frame #%llu)\n",
                    (unsigned)e, (int)prevFbo, (int)sw, (int)sh,
                    (unsigned long long)g_softFrames);
        }
        return;
    }

    /* 不翻转：readback 行序即显示行序（见文件头说明） */
    size_t stride = (size_t)sw * 4;
    size_t bytes = stride * (size_t)sh;

    /* 场景快照（不受跳过逻辑影响，保证准时落盘）。
     * 用零拷贝 provider 引用 g_softBuf，避免 CFDataCreate 的 786KB 拷贝泄漏。 */
    CGImageRef dumpImg = NULL;
    {
        CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, g_softBuf, (CFIndex)bytes, NULL);
        if (dp) {
            CGColorSpaceRef c = CGColorSpaceCreateDeviceRGB();
            dumpImg = CGImageCreate(sw, sh, 8, 32, stride, c,
                                    kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
                                    dp, NULL, false, kCGRenderingIntentDefault);
            CGColorSpaceRelease(c);
            CGDataProviderRelease(dp);
        }
    }
    /* 红线诊断只在快照时刻统计（与 dump 同帧号门控），避免每帧全图扫描。
     * 原门控是固定的 42/600/3600/10800 四个帧点 —— 它才真正决定 dump 的触发时机，
     * 若只改 mkxp_dumpSceneToDoc 内部会被这里架空（几乎必然错过"消息框少字"现场）。
     * 现改为约每 1 秒一次、长期持续；内层用环形槽位使文件数恒定（20 个），
     * 等于常驻保留"最近约 20 秒"的画面快照，随时可取证而不必掐时间。 */
    static const int dumpEvery = 60;   // ≈1s；配合内层环形槽位，文件数恒定可长期持续
    static int dumpNext = 0;
    bool dumpNow = (int)g_softFrames >= dumpEvery * (dumpNext + 1);
    if (dumpImg && dumpNow) {
        ++dumpNext;
        /* 红色统计低频化（约每 600 帧一次）：原本与 dump 同频，改成每秒一次后
         * 会导致每秒一次全图扫描 + 每秒一行日志，属无用开销。 */
        static int redNext = 0;
        if ((int)g_softFrames >= 600 * (redNext + 1)) {
            ++redNext;
            /* 统计“偏红”像素（R>180 且 R-G>80 且 R-B>80），量化红线体量 */
            uint32_t reddish = 0;
            for (int y = 0; y < sh; ++y) {
                const uint8_t *row = g_softBuf + (size_t)y * stride;
                for (int x = 0; x < sw; ++x) {
                    uint8_t R = row[x * 4], G = row[x * 4 + 1], B = row[x * 4 + 2];
                    if (R > 180 && (int)R - G > 80 && (int)R - B > 80) ++reddish;
                }
            }
            fprintf(stderr, "[ios-embed] red-ish px=%u / %d  (frame #%llu)\n",
                    reddish, sw * sh, (unsigned long long)g_softFrames);

            /* ---- Bug2 取证：让引擎自己算出"横线"的 y 坐标 ----
             * 已确认横线在 512x384 渲染层(scene dump)里，但本机无法打开玩家截图，
             * 故改为【引擎内自测】：逐行计算该行与上一行的平均绝对亮度差，
             * 差异显著的行就是视觉上的"横线/错位行"。
             * 打印 y、y%%32(=0 说明横线落在 tile 行边界 -> 指向 TilemapRenderer 行复用
             * 或 autotile 展开错位；非 0 则指向采样/缩放)、以及差异值。
             * 与 red-ish 同频(约每 600 帧一次)，512x384 遍历约 0.1ms，开销可忽略。 */
            static double rowDiff[1024];
            double sum = 0.0;
            int n = 0;
            for (int y = 1; y < sh && y < 1024; ++y) {
                const uint8_t *r0 = g_softBuf + (size_t)(y - 1) * stride;
                const uint8_t *r1 = g_softBuf + (size_t)y * stride;
                uint64_t acc = 0;
                for (int x = 0; x < sw; ++x) {
                    int l0 = (r0[x * 4] + r0[x * 4 + 1] + r0[x * 4 + 2]) / 3;
                    int l1 = (r1[x * 4] + r1[x * 4 + 1] + r1[x * 4 + 2]) / 3;
                    acc += (uint64_t)((l0 > l1) ? (l0 - l1) : (l1 - l0));
                }
                rowDiff[y] = (double)acc / (double)sw;
                sum += rowDiff[y];
                ++n;
            }
            if (n > 0) {
                double mean = sum / (double)n;
                double mx = 0.0;
                for (int y = 1; y < sh && y < 1024; ++y)
                    if (rowDiff[y] > mx) mx = rowDiff[y];
                /* 不用 sqrt：本文件未 include math.h（只用除法/比较），避免编译失败。
                 * 改用"相对均值的倍数"作阈值，同样能挑出显著异常行。 */
                double thr = mean * 2.5;
                int printed = 0;
                for (int y = 1; y < sh && y < 1024 && printed < 15; ++y) {
                    if (rowDiff[y] > thr) {
                        fprintf(stderr, "[ios-embed] ROWLINES y=%d diff=%.1f y%%32=%d "
                                        "(frame #%llu, mean=%.1f max=%.1f thr=%.1f)\n",
                                y, rowDiff[y], y % 32,
                                (unsigned long long)g_softFrames, mean, mx, thr);
                        /* 附加该行像素采样（8 个像素 RGB + 行内是否单色）。
                         * 必要性：仅看行间差异无法区分——16px 子块边界的地形纹理
                         * 本身就是颜色跳变(开/关 CPU 路径两版尖峰位置完全相同,
                         * 证明那些尖峰是正常纹理)。必须看到像素内容才能判定：
                         *   单色(same=1) -> 纯色遮挡/overlay 类横线;
                         *   与邻行同色但错位 -> 复制错位;
                         *   纹理多样 -> 正常地形, 该行不是 bug 现场。 */
                        if (printed < 3) {
                            const uint8_t *rr = g_softBuf + (size_t)y * stride;
                            int same = 1;
                            for (int k = 1; k < sw && k < 64; ++k) {
                                if (rr[k * 4] != rr[0] || rr[k * 4 + 1] != rr[1] ||
                                    rr[k * 4 + 2] != rr[2]) { same = 0; break; }
                            }
                            fprintf(stderr, "[ios-embed] ROWSAMP y=%d monocolor=%d px=", y, same);
                            for (int k = 0; k < 8; ++k)
                                fprintf(stderr, "(%d,%d,%d)",
                                        rr[k * 4], rr[k * 4 + 1], rr[k * 4 + 2]);
                            fprintf(stderr, "\n");
                        }
                        ++printed;
                    }
                }
                if (printed == 0)
                    fprintf(stderr, "[ios-embed] ROWLINES none (frame #%llu, mean=%.1f max=%.1f)\n",
                            (unsigned long long)g_softFrames, mean, mx);
            }

            /* ---- 用户确认：横线是【纯色线】且相对地图固定(随地图滚动) ----
             * ROWSAMP 已否证原检测目标：ROWLINES 抓到的 top 行 monocolor=0(有纹理,
             * 实测是草地 tile 上/下 16px 子块的正常交界, 暗绿->亮绿), 说明
             * "行间差异最大"抓的是正常地形边界, 根本不是 bug 现场。
             * 故改为直接检测【整行近乎单色】= 用户亲眼看到的纯色横线。
             * 判据: y%32 接近 0/31 -> tile 之间的缝隙(透出底色);
             *       y%16 接近 0/15 -> autotile 16px 子块之间的缝隙。
             * 与 ROWLINES 同频(约每 600 帧一次), 开销 ~0.1ms。 */
            {
                int monoPrinted = 0;
                for (int y = 0; y < sh && y < 1024 && monoPrinted < 12; ++y) {
                    const uint8_t *rr = g_softBuf + (size_t)y * stride;
                    int r0 = rr[0], g0 = rr[1], b0 = rr[2];
                    int same = 1;
                    for (int x = 1; x < sw; ++x) {
                        int dr = rr[x * 4] - r0, dg = rr[x * 4 + 1] - g0, db = rr[x * 4 + 2] - b0;
                        if (dr < 0) dr = -dr;
                        if (dg < 0) dg = -dg;
                        if (db < 0) db = -db;
                        if (dr <= 10 && dg <= 10 && db <= 10) ++same;
                    }
                    if (same * 10 > sw * 8) {
                        fprintf(stderr, "[ios-embed] MONOLINE y=%d rgb=(%d,%d,%d) "
                                        "same=%d/%d y%%32=%d y%%16=%d (frame #%llu)\n",
                                y, r0, g0, b0, same, sw, y % 32, y % 16,
                                (unsigned long long)g_softFrames);
                        ++monoPrinted;
                    }
                }
                if (monoPrinted == 0)
                    fprintf(stderr, "[ios-embed] MONOLINE none (frame #%llu)\n",
                            (unsigned long long)g_softFrames);
            }

            /* ---- 局部水平纯色段检测(SEGLINE) ----
             * MONOLINE(整行单色)在地图帧均为 none -> 用户看到的"纯色线"不是全屏单色行,
             * 而是某 tile 行内沿 x 延伸的【局部纯色段】(整行不全纯, 故整行检测漏掉)。
             * 这正符合 'autotile 16x16 子块取错 / tile 边缘露出纯色' 的画像。
             * 对每行扫描连续同色(相邻像素差<=8)的最长段, 段长>=64(>=2 tile)即打印:
             * 段长/起始x/段颜色/y%%32。全图限 12 行; 段长=512 即全屏宽线。 */
            {
                int segPrinted = 0;
                for (int y = 0; y < sh && y < 1024 && segPrinted < 12; ++y) {
                    const uint8_t *rr = g_softBuf + (size_t)y * stride;
                    int longest = 1, bestStart = 0, cur = 1, curStart = 0;
                    for (int x = 1; x < sw; ++x) {
                        int dr = rr[x * 4] - rr[(x - 1) * 4];
                        int dg = rr[x * 4 + 1] - rr[(x - 1) * 4 + 1];
                        int db = rr[x * 4 + 2] - rr[(x - 1) * 4 + 2];
                        if (dr < 0) dr = -dr;
                        if (dg < 0) dg = -dg;
                        if (db < 0) db = -db;
                        if (dr <= 8 && dg <= 8 && db <= 8) { if (cur == 1) curStart = x - 1; ++cur; }
                        else { if (cur > longest) { longest = cur; bestStart = curStart; } cur = 1; }
                    }
                    if (cur > longest) { longest = cur; bestStart = curStart; }
                    if (longest >= 64) {
                        int bx = bestStart * 4;
                        fprintf(stderr, "[ios-embed] SEGLINE y=%d len=%d startx=%d rgb=(%d,%d,%d) "
                                        "y%%32=%d (frame #%llu)\n",
                                y, longest, bestStart, rr[bx], rr[bx + 1], rr[bx + 2], y % 32,
                                (unsigned long long)g_softFrames);
                        ++segPrinted;
                    }
                }
            }

            /* ---- 行复制检测(COPYLINE2) ----
             * 修正: red-ish 确认 dump = 512x384(游戏逻辑分辨率, sw*sh=196608)。
             * 原 COPYLINE 抓到 y=1,3,5..全奇数行与上行几乎相同 -> 渲染层
             * 【垂直相邻行相同】(每 2 行一组重复), 这是全屏性行复制, 不是单条 bug 线。
             * 为排除"每 2 行复制"全屏条纹, 改测【偶数行 y 与隔一行 y-2】是否几乎相同:
             * 若某偶数行与 y-2(真实上一行)相同 -> 真正的隔行复制错位
             * (tone 路径 1px 偏差使某 tile 行复制上行内容)。
             * 对齐 y%%64==0/63(tile 行边界) 或 y%%32==0/31(16px 子块边界) 即坐实。 */
            {
                int copyPrinted = 0;
                for (int y = 2; y < sh && y < 1024 && copyPrinted < 12; y += 2) {
                    const uint8_t *r0 = g_softBuf + (size_t)(y - 2) * stride;
                    const uint8_t *r1 = g_softBuf + (size_t)y * stride;
                    uint64_t acc = 0;
                    for (int x = 0; x < sw; ++x) {
                        int l0 = (r0[x * 4] + r0[x * 4 + 1] + r0[x * 4 + 2]) / 3;
                        int l1 = (r1[x * 4] + r1[x * 4 + 1] + r1[x * 4 + 2]) / 3;
                        acc += (uint64_t)((l0 > l1) ? (l0 - l1) : (l1 - l0));
                    }
                    double d = (double)acc / (double)sw;
                    if (d < 2.5) {
                        fprintf(stderr, "[ios-embed] COPYLINE2 y=%d diffVSup2=%.2f "
                                        "y%%64=%d y%%32=%d (frame #%llu)\n",
                                y, d, y % 64, y % 32, (unsigned long long)g_softFrames);
                        ++copyPrinted;
                    }
                }
                if (copyPrinted == 0)
                    fprintf(stderr, "[ios-embed] COPYLINE2 none (frame #%llu)\n",
                            (unsigned long long)g_softFrames);
            }

            /* ---- 垂直 2x 复制覆盖率(VREP) ----
             * COPYLINE2(#600) 已抓到连续偶数行隔行复制, y=96(y%%32=0) diff=0.00。
             * 为区分【全屏每2行条纹】(屏幕固定, 不可能随地图滚动/tone 变)
             * 与【局部 tile 行错位】(随地图滚动, 能解释 tone 时出现),
             * 统计偶数行 y 与上行(y-1)几乎相同(diff<2)的比例。
             * 高比例(>50%) -> 全屏性垂直 2x 复制; 低比例 -> 局部错位。 */
            {
                int sameCnt = 0, tot = 0;
                for (int y = 2; y < sh && y < 1024; y += 2) {
                    const uint8_t *r0 = g_softBuf + (size_t)(y - 1) * stride;
                    const uint8_t *r1 = g_softBuf + (size_t)y * stride;
                    uint64_t acc = 0;
                    for (int x = 0; x < sw; ++x) {
                        int l0 = (r0[x * 4] + r0[x * 4 + 1] + r0[x * 4 + 2]) / 3;
                        int l1 = (r1[x * 4] + r1[x * 4 + 1] + r1[x * 4 + 2]) / 3;
                        acc += (uint64_t)((l0 > l1) ? (l0 - l1) : (l1 - l0));
                    }
                    ++tot;
                    if ((double)acc / (double)sw < 2.0) ++sameCnt;
                }
                fprintf(stderr, "[ios-embed] VREP evenRowsSame=%.1f%% (%d/%d) (frame #%llu)\n",
                        tot ? 100.0 * sameCnt / tot : 0.0, sameCnt, tot,
                        (unsigned long long)g_softFrames);
            }
        }
        mkxp_dumpSceneToDoc(dumpImg, g_softFrames);
        CFRelease(dumpImg);
    } else if (dumpImg) {
        CFRelease(dumpImg);
    }

    /* 内容没变就不重建 CGImage / 不上屏（画面几乎全是静态时显著降负载） */
    static uint32_t s_lastHash = 0;
    uint32_t hsh = mkxp_hashScene(g_softBuf, sw, sh);
    if (hsh == s_lastHash) return;
    s_lastHash = hsh;

    /* 合并：若上一帧还在主线程排队，跳过本帧（不碰 g_softDisp，避免覆盖在途帧）。
     * 这一步必须在 memcpy 之前，保证在途帧引用的 g_softDisp 不被改写。 */
    if (atomic_exchange(&g_softPending, 1) == 1) return;
    atomic_store(&g_firstFrameShown, 1);   // 引擎已出画面（供加载提示收起）

    /* 复用显示缓冲（乒乓）：把读回像素拷进当前未引用的那块，再用零拷贝 provider
     * 引用它。全程不每帧分配 786KB，从根本上消除 phys_footprint 持续增长。 */
    g_dispIdx ^= 1;
    memcpy(g_softDisp[g_dispIdx], g_softBuf, bytes);

    CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, g_softDisp[g_dispIdx], (CFIndex)bytes, NULL);
    if (!provider) { atomic_store(&g_softPending, 0); return; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(sw, sh, 8, 32, (size_t)sw * 4, cs,
                                  /* 2026-10-20 reverted: byte order flag should be 32Big
                                   * on iOS Metal; previous Little fix caused all scenes
                                   * to render uniformly red (was speccing wrong). The
                                   * SkipLast + 32Big combo is the historic pre-fix state
                                   * and matches what the scene-dump PNGs (saved via the
                                   * same flag at line ~190) were using successfully.
                                   * 2026-10-20 still unconfirmed whether actual root
                                   * cause is byte order or glReadPixels returning BGRA
                                   * bytes on Metal (would need PremultipliedFirst +
                                   * 32Little for that). For now revert. */
                                  kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
                                  provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);   // cg 仍持有 g_softDisp（provider 用 NULL 释放回调，不会 free 它）
    if (!cg) { atomic_store(&g_softPending, 0); return; }

    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            CFTimeInterval t0 = CFAbsoluteTimeGetCurrent();
            if (g_softView) {
                /* 自己用最近邻把 512x384 的帧放大到屏幕实际像素分辨率，再 1:1 呈现，
                 * 绕过 UIImageView 不吃 layer.magnificationFilter 的问题，保证锐利。 */
                CGFloat dscale = (CGFloat)[UIScreen mainScreen].scale;
                CGRect pb = g_softView.superview.bounds;
                CGFloat kw = (pb.size.width > 0) ? (pb.size.width / (CGFloat)sw) : 1e9;
                CGFloat kh = (pb.size.height > 0) ? (pb.size.height / (CGFloat)sh) : 1e9;
                CGFloat k = (kw < kh) ? kw : kh;
                int dispW = (int)((CGFloat)sw * k * dscale);
                int dispH = (int)((CGFloat)sh * k * dscale);
                CGImageRef up = mkxp_upscaleNearest(cg, sw, sh, dispW, dispH);
                if (up) {
                    UIImage *img = [UIImage imageWithCGImage:up];
                    g_softView.image = img;
                    CGImageRelease(up);
                    mkxp_layoutSoftView();   /* 按 AspectFit 居中定位(1:1 呈现) */
                }
            }
            CGImageRelease(cg);
            /* 主线程显示开销（CGImage 解码 + UIKit 侧成本），卡顿定位数据 */
            static double s_acc = 0;
            static int s_n = 0;
            s_acc += CFAbsoluteTimeGetCurrent() - t0;
            if (++s_n >= 600) {
                fprintf(stderr, "[ios-embed] main-display avg %.2f ms (n=600)\n",
                        s_acc / s_n * 1000.0);
                s_acc = 0;
                s_n = 0;
            }
        }
        atomic_store(&g_softPending, 0);
    });

    static int logged = 0;
    if (logged < 3) {
        ++logged;
        fprintf(stderr, "[ios-embed] softPresent %dx%d (view=%p)\n",
                sw, sh, (void *)g_softView);
    }
}

/* ---- 崩溃信号捕获：SIGSEGV/SIGABRT 等致死信号在进程终止前把 backtrace
 *      写到 stderr（= mkxp.log）。jetsam(OOM) 杀进程无法捕获，靠内存水位日志定位。 ---- */
static void mkxp_crashSigHandler(int sig, siginfo_t *info, void *ctx)
{
    char buf[128];
    int n = snprintf(buf, sizeof buf,
                     "\n[crash-sig] signal=%d addr=%p backtrace:\n",
                     sig, info ? info->si_addr : NULL);
    write(2, buf, (size_t)n);
    void *bt[64];
    int nbt = backtrace(bt, 64);
    backtrace_symbols_fd(bt, nbt, 2);
    struct sigaction sa;
    sa.sa_handler = SIG_DFL;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(sig, &sa, NULL);
    raise(sig);
}

static void mkxp_installCrashSignalHandlers()
{
    static const int sigs[] = {SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP};
    struct sigaction sa;
    sa.sa_sigaction = mkxp_crashSigHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); ++i)
        sigaction(sigs[i], &sa, NULL);
    fprintf(stderr, "[ios-embed] crash signal handlers installed\n");
}

/* ---- 内存水位：每隔一段时间记录 phys_footprint，若持续上涨→闪退，即 jetsam OOM ---- */
static void mkxp_logMemoryFootprint(uint64_t presentNo)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO,
                  (task_info_t)&info, &cnt) == KERN_SUCCESS) {
        fprintf(stderr,
                "[ios-embed] mem@present#%llu phys_footprint=%.1fMB resident=%.1fMB\n",
                (unsigned long long)presentNo,
                info.phys_footprint / 1048576.0,
                info.resident_size / 1048576.0);
    }
}

static void swz_renderbufferStorage(id self, SEL _cmd, NSUInteger target, id drawable) {
    if (drawable != nil) {
        CALayer *layer = (CALayer *)drawable;
        CGRect b = layer.bounds;
        int w = (int)(b.size.width * layer.contentsScale);
        int h = (int)(b.size.height * layer.contentsScale);
        g_drawW = w;
        g_drawH = h;

        static uint64_t n = 0;
        ++n;
        if (n <= 3 || n % 600 == 0)
            fprintf(stderr, "[ios-embed] renderbufferStorage #%llu (%dx%d)\n",
                    (unsigned long long)n, w, h);
    }
    g_origRBS(self, _cmd, target, drawable);
}

/* 日志轮转：mkxp.log 经 freopen 持续 append，历史/长会话会无限增长；
 * 文件过大时 Flutter 日志页整文件读内存会 OOM 闪退。超过上限时截断保留末尾。
 * 用纯 C 实现（避免 std::string / MAX 宏等潜在坑）；忽略返回值的 stdio 调用加
 * (void) 以兼容 -Werror（freopen 等标了 warn_unused_result）。 */
extern "C" void mkxp_ios_trim_log(void) {
    const char *home = getenv("HOME");
    if (!home || !home[0]) return;
    char path[1024];
    (void)snprintf(path, sizeof(path), "%s/Documents/mkxp.log", home);
    struct stat st;
    if (stat(path, &st) != 0) return;
    static const long long kMaxLogBytes = 4LL * 1024 * 1024;  // 4MB 上限
    static const long long kKeepLogBytes = 1LL * 1024 * 1024; // 保留末尾 1MB
    if (st.st_size <= kMaxLogBytes) return;
    long start = (long)st.st_size - (long)kKeepLogBytes;
    if (start < 0) start = 0;
    FILE *f = fopen(path, "rb");
    if (!f) return;
    (void)fseek(f, start, SEEK_SET);
    long remain = (long)st.st_size - start;
    char *buf = (char *)malloc((size_t)remain);
    if (!buf) { (void)fclose(f); return; }
    size_t got = fread(buf, 1, (size_t)remain, f);
    (void)fclose(f);
    if (got == 0) { free(buf); return; }
    FILE *w = fopen(path, "wb");
    if (!w) { free(buf); return; }
    (void)fwrite(buf, 1, got, w);
    (void)fclose(w);
    free(buf);
    /* stdout/stderr 句柄重新指向新文件(append)，否则还停在旧 inode 偏移 */
    (void)freopen(path, "a", stdout);
    (void)freopen(path, "a", stderr);
    (void)setvbuf(stdout, nullptr, _IOLBF, 0);
    (void)setvbuf(stderr, nullptr, _IONBF, 0);
    fprintf(stderr, "\n[log] rotated: was %lld bytes, kept last %lld\n",
            (long long)st.st_size, (long long)got);
}

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    /* 后台禁止一切 GPU 提交：iOS 会拒绝（kIOGPUCommandBufferCallbackError
     * BackgroundExecutionNotPermitted），实测退后台瞬间刷出数百条
     * GLDRendererMetal completion error 且伴随引擎清理期崩溃。 */
    if (g_appBackgrounded) return YES;

    uint64_t n = ++g_presentTotal;
    CFTimeInterval hookT0 = CFAbsoluteTimeGetCurrent();
    if (n <= 3 || n % 600 == 1) {
        fprintf(stderr, "[ios-embed] present #%llu (drawablePx=%dx%d)\n",
                (unsigned long long)n, g_drawW, g_drawH);
    }
    if (n % 600 == 1) {
        mkxp_logMemoryFootprint(n);
        mkxp_ios_trim_log();   // 长会话中持续限制 mkxp.log 体积，避免日志页 OOM 闪退
    }

    /* 旋转当帧（drawable 尺寸与上帧不同）跳过读回，让 EAGL 重建 drawable 后先稳定 */
    static int s_lastW = 0, s_lastH = 0;
    int dw = g_drawW, dh = g_drawH;
    BOOL rotateFrame = (dw != s_lastW || dh != s_lastH);
    s_lastW = dw;
    s_lastH = dh;

    /* 先让 EAGL 完成它自己的提交（present），【之后】再做软呈现读回。
     * 之前读回插在 present 之前，会把 EAGL( Metal 后端)的 encoder 周期搅乱，
     * 旋转时触发 'commit command buffer with uncommitted encoder' SIGABRT
     * （= 来回旋转闪退 / BGM+画面突然重启，2026-10-18 日志两次同址崩溃实锤）。 */
    BOOL ok = g_origPresent(self, _cmd, target);
    double presentMs = CFAbsoluteTimeGetCurrent() - hookT0;

    /* 旋转后窗口 bounds 变化 → 软呈现视图需按新的 AspectFit 重新布局(旋转当帧
     * 读回被跳过，画面不更新；这里延迟一点等 UIKit 完成旋转)。 */
    if (rotateFrame) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (g_softView) mkxp_layoutSoftView();
        });
    }

    double softMs = 0;
    if (!rotateFrame) {
        double t1 = CFAbsoluteTimeGetCurrent();
        mkxp_softPresent();
        softMs = CFAbsoluteTimeGetCurrent() - t1;
    }

    /* 帧耗时统计：avg 看占用，max 看尖峰；present 与软呈现分开归因
     * （尖峰 >16.6ms = 真掉帧；present 尖峰= EAGL/CA 争用，soft 尖峰= 读回停顿）。 */
    {
        static double s_acc = 0, s_max = 0, s_pmax = 0, s_smax = 0;
        static int s_n = 0;
        double dt = CFAbsoluteTimeGetCurrent() - hookT0;
        s_acc += dt;
        if (dt > s_max) s_max = dt;
        if (presentMs > s_pmax) s_pmax = presentMs;
        if (softMs > s_smax) s_smax = softMs;
        if (++s_n >= 600) {
            fprintf(stderr,
                    "[ios-embed] hook avg %.2f max %.2f | present max %.2f | soft max %.2f ms (n=600)\n",
                    s_acc / s_n * 1000.0, s_max * 1000.0, s_pmax * 1000.0, s_smax * 1000.0);
            s_acc = 0; s_max = 0; s_pmax = 0; s_smax = 0;
            s_n = 0;
        }
    }

    return ok;
}

/* 生命周期：App 进后台时跳过我们的 GL 读回/显示（mkxp 自身也会 haltThreads，
 * 但双保险；同时记录事件，便于日志里判断“崩溃是不是后台被杀”）。 */
static void mkxp_onAppLifecycle(NSNotificationName name) {
    if ([name isEqualToString:UIApplicationDidEnterBackgroundNotification]) {
        g_appBackgrounded = 1;
        fprintf(stderr, "[ios-embed] lifecycle: didEnterBackground (停止软呈现 GPU 工作)\n");
    } else if ([name isEqualToString:UIApplicationWillEnterForegroundNotification]) {
        g_appBackgrounded = 0;
        fprintf(stderr, "[ios-embed] lifecycle: willEnterForeground (恢复软呈现)\n");
        fprintf(stderr, "[ios-embed] lifecycle: willEnterForeground (恢复软呈现)\n");
    }
}

/* UIWindow setHidden 保护：引擎清理期调 SDL_DestroyWindow ->
 * UIKit_HideWindow -> [UIWindow setHidden:YES]，iOS 的 FrontBoardServices 直接
 * assert（SIGTRAP，2026-10-18 日志 signal=5 实锤）。SDL_uikitviewcontroller 在
 * 启动时 appearance transition 未配平，exit 时 setHidden:YES 触发断言（前台/后台
 * 退出都会触发）。mkxp 的 SDL 窗口只在启动 show(setHidden:NO)、退出 hide
 * (setHidden:YES)，运行期不会 hide，故直接忽略所有 setHidden:YES 即可避开断言，
 * show 不受影响（显示正常）。 */
static void (*g_origUIWinSetHidden)(id, SEL, BOOL);
static void mkxp_uiwinSetHidden(id self, SEL _cmd, BOOL hidden)
{
    if (hidden) {
        fprintf(stderr, "[ios-embed] setHidden:YES skipped (appBg=%d)\n", (int)g_appBackgrounded);
        return;
    }
    g_origUIWinSetHidden(self, _cmd, hidden);
}

/// ProMotion 空心跳：RGSS 引擎逻辑固定 40fps，60Hz 屏上帧间隔 15/30ms 交替
/// （= 走路/卷动时固有 judder）；120Hz 下 40 整除（3×8.3ms 均匀）。
/// 挂一个 120Hz 的空 CADisplayLink 促使 ProMotion 设备整帧率跑 120；
/// 60Hz 设备系统自动钳制到 60，无副作用。
@interface MkxpPerfTick : NSObject
+ (void)tick:(CADisplayLink *)dl;
@end
@implementation MkxpPerfTick
+ (void)tick:(CADisplayLink *)dl { (void)dl; }
@end

__attribute__((constructor))
static void mkxp_installHooksEarly() {
    mkxp_installCrashSignalHandlers();

    Method uiwinHidden = class_getInstanceMethod([UIWindow class], @selector(setHidden:));
    if (uiwinHidden) {
        g_origUIWinSetHidden = (void (*)(id, SEL, BOOL))method_getImplementation(uiwinHidden);
        method_setImplementation(uiwinHidden, (IMP)mkxp_uiwinSetHidden);
    }

    /* ProMotion 120Hz 心跳（见 MkxpPerfTick 注释） */
    if (@available(iOS 15.0, *)) {
        static CADisplayLink *s_promoLink = nil;
        if (!s_promoLink && [UIScreen mainScreen].maximumFramesPerSecond > 60) {
            s_promoLink = [CADisplayLink displayLinkWithTarget:[MkxpPerfTick class]
                                                      selector:@selector(tick:)];
            s_promoLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 120);
            [s_promoLink addToRunLoop:[NSRunLoop mainRunLoop]
                              forMode:NSRunLoopCommonModes];
            fprintf(stderr, "[ios-embed] ProMotion 120Hz tick installed (max fps=%d)\n",
                    (int)[UIScreen mainScreen].maximumFramesPerSecond);
        }
    }
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidEnterBackgroundNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *note){ mkxp_onAppLifecycle(note.name); }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationWillEnterForegroundNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification *note){ mkxp_onAppLifecycle(note.name); }];

    /* iOS 音频会话：中断(来电/其他 App 抢占)/路由变更(AirPods 切换/拔耳机)
     * 会让 OpenAL 设备失效、BGM 永久静音。复用 eventthread 的暂停-恢复逻辑
     * 自愈；中断结束/路由变更后重新激活会话。 */
    [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioSessionInterruptionNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note){
        NSNumber *t = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (t.integerValue == AVAudioSessionInterruptionTypeBegan) {
            fprintf(stderr, "[ios-embed] AVAudioSession interruption BEGAN\n");
            mkxp_ios_audioInterruptBegin();
        } else {
            fprintf(stderr, "[ios-embed] AVAudioSession interruption ENDED\n");
            NSError *e = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&e];
            if (e) fprintf(stderr, "[ios-embed] AVAudioSession setActive err=%s\n",
                           e.localizedDescription.UTF8String);
            mkxp_ios_audioInterruptEnd();
        }
    }];
    [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioSessionRouteChangeNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note){
        NSNumber *r = note.userInfo[AVAudioSessionRouteChangeReasonKey];
        fprintf(stderr, "[ios-embed] AVAudioSession routeChange reason=%ld\n",
                (long)r.integerValue);
        NSError *e = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&e];
        if (e) fprintf(stderr, "[ios-embed] AVAudioSession setActive err=%s\n",
                       e.localizedDescription.UTF8String);
        mkxp_ios_audioInterruptEnd();
    }];

    Class cls = [EAGLContext class];
    Method m = class_getInstanceMethod(cls, @selector(renderbufferStorage:fromDrawable:));
    if (m) { g_origRBS = (void(*)(id,SEL,NSUInteger,id))method_getImplementation(m);
            method_setImplementation(m, (IMP)swz_renderbufferStorage); }
    Method mp = class_getInstanceMethod(cls, @selector(presentRenderbuffer:));
    if (mp) { g_origPresent = (BOOL(*)(id,SEL,NSUInteger))method_getImplementation(mp);
             method_setImplementation(mp, (IMP)swz_presentRenderbuffer); }
    fprintf(stderr, "[ios-embed] EAGLContext hooks installed (constructor)\n");
}

static void mkxp_show(UIWindow *sdlWin) {
    @try {
        UIWindow *ref = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isHidden && w.windowScene &&
                w.windowScene.activationState == UISceneActivationStateForegroundActive) { ref = w; break; }
        }
        UIWindowScene *refScene = (UIWindowScene *)ref.windowScene;
        if (refScene && sdlWin.windowScene != refScene) sdlWin.windowScene = refScene;
        sdlWin.windowLevel = 1999.0;
        sdlWin.hidden = NO;
        [sdlWin layoutIfNeeded];
        [sdlWin makeKeyAndVisible];
        fprintf(stderr,
            "[ios-embed] show: win=%p hidden=%d level=%.0f frame=%s scene=%p key=%d\n",
            (void *)sdlWin, sdlWin.hidden, (double)sdlWin.windowLevel,
            NSStringFromCGRect(sdlWin.frame).UTF8String, (void *)sdlWin.windowScene,
            (int)sdlWin.isKeyWindow);
    } @catch (NSException *e) {
        fprintf(stderr, "[ios-embed] show exception: %s\n", e.reason.UTF8String);
    }
}

extern "C" void mkxp_ios_embedIntoView(SDL_Window *win) {
    if (!win) return;
    SDL_SysWMinfo wm; SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(win, &wm) || wm.subsystem != SDL_SYSWM_UIKIT) {
        fprintf(stderr, "[ios-embed] embedIntoView: not UIKit subsystem\n"); return;
    }
    UIWindow *sdlWin = (UIWindow *)wm.info.uikit.window;
    if (!sdlWin) { fprintf(stderr, "[ios-embed] sdlWin nil\n"); return; }
    g_win = win;
    g_iosWinId = SDL_GetWindowID(g_win);
    g_sdlWin = sdlWin;
    fprintf(stderr, "[ios-embed] embedIntoView: win=%p scene=%p\n", (void *)sdlWin, (void *)sdlWin.windowScene);

    if ([NSThread isMainThread]) mkxp_show(sdlWin);
    else dispatch_async(dispatch_get_main_queue(), ^{ mkxp_show(sdlWin); });

    /* 软呈现：创建承载图像的 UIImageView，盖在 GL 视图之上。
     * ScaleAspectFit + 黑底 => 自动 4:3 居中留黑边。 */
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_softView) return;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:sdlWin.bounds];
        iv.backgroundColor = [UIColor blackColor];
        /* 整数倍缩放 + 居中(见 mkxp_layoutSoftView): 不用 ScaleAspectFit 填满,
         * 那会得到非整数缩放(2.156x), 使 autotile 16px 子块硬边被放大成参差不齐
         * 的粗横带(用户报的"横线")。 */
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth |
                              UIViewAutoresizingFlexibleHeight;
        iv.opaque = YES;
        iv.userInteractionEnabled = YES;
        {
            UITapGestureRecognizer *spngTap = [[UITapGestureRecognizer alloc]
                initWithTarget:[MkxpSpngToggle class] action:@selector(onSpngTap:)];
            spngTap.numberOfTouchesRequired = 3;
            spngTap.numberOfTapsRequired = 1;
            [iv addGestureRecognizer:spngTap];
        }
        [sdlWin addSubview:iv];
        g_softView = iv;   /* 生命期与 App 一致，故意不释放 */
        mkxp_layoutSoftView();   /* 立即按整数倍居中(autoresizingMask=None, 需手动布局) */
        fprintf(stderr, "[ios-embed] soft view created frame=%s\n",
                NSStringFromCGRect(sdlWin.bounds).UTF8String);
    });
}

extern "C" void mkxp_ios_setHostView(void *view) {
    g_hostView = (__bridge UIView *)(view);
    fprintf(stderr, "[ios-embed] setHostView=%p\n", view);
}
