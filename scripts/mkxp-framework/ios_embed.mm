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
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <signal.h>
#import <execinfo.h>
#import <mach/mach.h>
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
static int g_softW = 0, g_softH = 0;
static uint64_t g_softFrames = 0;

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
    GLuint tex = 0, fbo = 0;
    int sw = 0, sh = 0, ox = 0, oy = 0, ww = 0, wh = 0;
    mkxp_ios_getScene(&tex, &fbo, &sw, &sh, &ox, &oy, &ww, &wh);
    if (!fbo || sw <= 0 || sh <= 0) return;

    /* 每 3 帧更新一次（约 20fps 显示），降低 glReadPixels 给引擎线程的
     * 开销——读回过频会让游戏逻辑变慢（画面“速度不对”），并加剧内存压力。
     * 游戏逻辑仍以 mkxp 自身帧率跑，仅显示层降频。 */
    if ((++g_softFrames % 3) != 0) return;

    if (sw != g_softW || sh != g_softH) {
        free(g_softBuf);
        g_softW = sw;
        g_softH = sh;
        g_softBuf = (uint8_t *)malloc((size_t)sw * sh * 4);
    }
    if (!g_softBuf) return;

    GLint prevFbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prevFbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
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

    /* 场景快照（不受跳过逻辑影响，保证准时落盘） */
    CGImageRef dumpImg = NULL;
    {
        CFDataRef dd = CFDataCreate(NULL, g_softBuf, (CFIndex)(stride * (size_t)sh));
        if (dd) {
            CGDataProviderRef dp = CGDataProviderCreateWithCFData(dd);
            CFRelease(dd);
            if (dp) {
                CGColorSpaceRef c = CGColorSpaceCreateDeviceRGB();
                dumpImg = CGImageCreate(sw, sh, 8, 32, stride, c,
                                        kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
                                        dp, NULL, false, kCGRenderingIntentDefault);
                CGColorSpaceRelease(c);
                CGDataProviderRelease(dp);
            }
        }
    }
    if (dumpImg) {
        mkxp_dumpSceneToDoc(dumpImg, g_softFrames);
        CFRelease(dumpImg);
    }

    /* 内容没变就不重建 CGImage / 不上屏（画面几乎全是静态时显著降负载） */
    static uint32_t s_lastHash = 0;
    uint32_t hsh = mkxp_hashScene(g_softBuf, sw, sh);
    if (hsh == s_lastHash) return;
    s_lastHash = hsh;

    /* 用 CFData 拷贝一份，避免后续复用 g_softBuf 影响正在显示的图像 */
    CFDataRef data = CFDataCreate(NULL, g_softBuf, (CFIndex)(stride * (size_t)sh));
    if (!data) return;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
    CFRelease(data);
    if (!provider) return;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(sw, sh, 8, 32, (size_t)sw * 4, cs,
                                  kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipLast,
                                  provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    if (!cg) return;

    /* CFRetain/CFRelease 与 ARC/MRR 无关，可在线程间安全交接 */
    CFRetain(cg);
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (g_softView) {
                UIImage *img = [UIImage imageWithCGImage:cg];
                g_softView.image = img;
            }
            CFRelease(cg);
        }
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
    uint64_t n = ++g_presentTotal;
    if (n <= 3 || n % 600 == 1) {
        fprintf(stderr, "[ios-embed] present #%llu (drawablePx=%dx%d)\n",
                (unsigned long long)n, g_drawW, g_drawH);
    }
    if (n % 600 == 1)
        mkxp_logMemoryFootprint(n);

    /* 软呈现：把场景 FBO 的内容交给 UIImageView 显示（唯一有效的出图路径） */
    mkxp_softPresent();

    return g_origPresent(self, _cmd, target);
}

__attribute__((constructor))
static void mkxp_installHooksEarly() {
    mkxp_installCrashSignalHandlers();
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
