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
#import <stdlib.h>
#import <unistd.h>
#import <signal.h>
#import <execinfo.h>
#import <mach/mach.h>
#import <stdatomic.h>
#import <objc/runtime.h>

static UIView *g_hostView = nil;
static SDL_Window *g_win = NULL;
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
static uint8_t *g_softBuf = NULL;    // 读回缓冲（行序 = 显示行序，见上）
/* 双缓冲乒乓：显示侧 CA 光栅化是【异步】的——pending 清零只代表 image 已设置，
 * render server 可能仍在读上一块缓冲的像素。若引擎线程立刻往同一块 memcpy
 * 下一帧，就会出现横向断纹（撕裂）。两块缓冲交替写，被引用的那块隔帧才复用。 */
static uint8_t *g_softDisp[2] = {NULL, NULL};
static int g_dispIdx = 0;
static int g_softW = 0, g_softH = 0;
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

/* 音频会话中断/路由桥接：由 eventthread.cpp 提供，复用其暂停-恢复逻辑，
 * 让 OpenAL 设备在 iOS 中断/路由变更后保持有效，BGM 可自愈而非永久静音。 */
extern "C" void mkxp_ios_audioInterruptBegin(void);
extern "C" void mkxp_ios_audioInterruptEnd(void);

/* ---- spng A/B 开关（无需文件共享）----
 *   游戏画面上【三指轻点】实时切换 spng 快速路径开/关，用于真机归因
 *   “颜色块闪烁”是 spng 解码还是软呈现读回。切换会清空解码缓存，
 *   后续 bitmap 用新设置重新解码；观察颜色块是否随切换变化即可。
 *   默认仍支持 Documents/disable_spng 文件（存在=关），与手势二选一。 */
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

static volatile int g_spngOverride = -1;   /* -1=未手动切换, 0=开, 1=关 */
static int mkxp_readDisableFlagFile(void) {
    const char *home = getenv("HOME");
    char p[512];
    snprintf(p, sizeof(p), "%s/Documents/disable_spng", home ? home : "");
    FILE *f = fopen(p, "rb");
    if (f) { fclose(f); return 1; }
    return 0;
}
extern "C" int mkxp_ios_spng_disabled(void) {
    if (g_spngOverride != -1) return g_spngOverride;
    return mkxp_readDisableFlagFile();
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

/* 场景快照落盘：无 Mac 环境下定位“画面内容对不对”的铁证。
 * 在 Documents/scene_dump_N.png 生成 PNG，Flutter 日志页可直接查看/分享。 */
static void mkxp_dumpSceneToDoc(CGImageRef cg, uint64_t frameNo)
{
    static const int marks[] = {42, 600, 3600, 10800};  // ≈0.7s/10s/60s/180s（对齐 %3 节流）
    static const int nMarks = sizeof(marks) / sizeof(marks[0]);
    static int next = 0;
    if (next >= nMarks) return;
    if ((int)frameNo < marks[next]) return;
    int idx = next;
    next = idx + 1;

    @autoreleasepool {
        UIImage *img = [UIImage imageWithCGImage:cg];
        if (!img) return;
        NSData *png = UIImagePNGRepresentation(img);
        if (!png) return;
        NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        if (!docs) return;
        NSString *path = [docs stringByAppendingFormat:
            @"/scene_dump_%d_f%d.png", idx + 1, marks[idx]];
        [png writeToFile:path atomically:YES];
        fprintf(stderr, "[ios-embed] scene dump #%d (%dx%d) -> %s\n",
                idx + 1, (int)CGImageGetWidth(cg), (int)CGImageGetHeight(cg),
                path.UTF8String);
    }
}

/* 采样哈希：内容没变就跳过软呈现，省 CPU/内存抖动（标题页静止时几乎全跳） */
static uint32_t mkxp_hashScene(const uint8_t *flip, int w, int h)
{
    uint32_t hsh = 2166136261u;
    size_t stride = (size_t)w * 4;
    int rowStep = h / 24 + 1;
    for (int y = 0; y < h; y += rowStep) {
        const uint8_t *row = flip + (size_t)y * stride;
        for (size_t x = 0; x + 3 < stride; x += 97) {
            hsh = (hsh ^ row[x]) * 16777619u;
        }
    }
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
    glReadPixels(0, 0, sw, sh, GL_RGBA, GL_UNSIGNED_BYTE, g_softBuf);
    glBindFramebuffer(GL_FRAMEBUFFER, prevFbo);

    GLenum e = glGetError();
    if (e != GL_NO_ERROR) {
        static int errLogged = 0;
        if (errLogged < 3) {
            ++errLogged;
            fprintf(stderr, "[ios-embed] softPresent readback err=0x%x\n", (unsigned)e);
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
    /* 红线诊断只在快照时刻统计（与 dump 同帧号门控），避免每帧全图扫描 */
    static const int dumpMarks[] = {42, 600, 3600, 10800};
    static int dumpNext = 0;
    bool dumpNow = (dumpNext < 4) && (int)g_softFrames >= dumpMarks[dumpNext];
    if (dumpImg && dumpNow) {
        /* 统计“偏红”像素（R>180 且 R-G>80 且 R-B>80），量化红线体量 */
        uint32_t reddish = 0;
        for (int y = 0; y < sh; ++y) {
            const uint8_t *row = g_softBuf + (size_t)y * stride;
            for (int x = 0; x < sw; ++x) {
                uint8_t R = row[x * 4], G = row[x * 4 + 1], B = row[x * 4 + 2];
                if (R > 180 && (int)R - G > 80 && (int)R - B > 80) ++reddish;
            }
        }
        ++dumpNext;
        fprintf(stderr, "[ios-embed] red-ish px=%u / %d  (frame #%llu)\n",
                reddish, sw * sh, (unsigned long long)g_softFrames);
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
                UIImage *img = [UIImage imageWithCGImage:cg];
                g_softView.image = img;
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
    if (n % 600 == 1)
        mkxp_logMemoryFootprint(n);

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

/* UIWindow setHidden 后台保护：引擎清理期在后台调 SDL_DestroyWindow ->
 * UIKit_HideWindow -> [UIWindow setHidden:YES]，iOS 的 FrontBoardServices 直接
 * assert（SIGTRAP，2026-10-18 日志 signal=5 实锤）。后台时忽略藏窗请求即可。 */
static void (*g_origUIWinSetHidden)(id, SEL, BOOL);
static void mkxp_uiwinSetHidden(id self, SEL _cmd, BOOL hidden)
{
    if (hidden && g_appBackgrounded) return;
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
        fprintf(stderr, "[ios-embed] soft view created frame=%s\n",
                NSStringFromCGRect(sdlWin.bounds).UTF8String);
    });
}

extern "C" void mkxp_ios_setHostView(void *view) {
    g_hostView = (__bridge UIView *)(view);
    fprintf(stderr, "[ios-embed] setHostView=%p\n", view);
}
