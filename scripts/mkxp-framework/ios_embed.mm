// ios_embed.mm — iOS 嵌入：把 SDL 真正用来渲染的 GL view 搬进 Flutter 宿主 UIView。
//
// 必须独立成 .mm：src/main.cpp 被 iOS 工具链按 C 编译，不能碰 objc 构造。
//
// 关键事实（2026-10-17 实测日志得出）：SDL 在 initGL 创建 EAGL context 时调
// renderbufferStorage:fromDrawable:，绑定的 drawable 并非 SDL 窗口 rootVC.view 的
// layer，而是 SDL 自建的专用 GL view（SDL_uikitopenglview）的 layer。所以只搬
// rootVC.view 无效——真正出像素的 view 必须搬。本文件 hook renderbufferStorage:
// 拿到该 layer 的 owner view，再把它搬进 Flutter 的 PlatformView 宿主并等比缩放。
//
// 时序：main.cpp 建窗后调 mkxp_ios_embedIntoView（装 hook）；Dart 的 UiKitView 首帧
// 调 mkxp_ios_setHostView 注入宿主；RGSS 线程 initGL 时 hook 抓 GL view。三者先后
// 不定，故用“谁后到谁触发搬运”的幂等设计。
//
// 诊断走 stderr → mkxp.log（无 Xcode 控制台也能定位）。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <objc/runtime.h>
#import <OpenGLES/ES2/gl.h>

// ---- 全局状态 ----
// 注意：本文件被 mkxp-z 以 -fno-objc-arc（手动引用计数）编译，不能用 __weak/__strong
// 等 ARC 限定符。宿主 UIView 由 Flutter 的 MkxpPlatformView 强持有，引擎运行期有效，
// 这里只存裸指针即可。
static UIView *g_hostView = nil;        // Flutter PlatformView 宿主
static CALayer *g_drawableLayer = nil;   // GL renderbuffer 绑定的 layer
static SDL_Window *g_win = NULL;         // main.cpp 建窗时传入
static bool g_repinDone = false;

static void mkxp_doRepin(void);
static void mkxp_requestRepin(void) {
    // UIKit 只能在主线程操作；调用方可能是 RGSS 线程
    if ([NSThread isMainThread]) mkxp_doRepin();
    else dispatch_async(dispatch_get_main_queue(), ^{ mkxp_doRepin(); });
}

// ---- GL 上屏 hook：统计 present + 抓 renderbuffer 绑定的 layer ----
static BOOL (*g_origPresent)(id, SEL, NSUInteger);
static void (*g_origRBS)(id, SEL, NSUInteger, id);
static uint64_t g_presentOK = 0, g_presentFail = 0, g_presentTotal = 0;
static bool g_reportedDrawable = false;

// CALayer 没有 .view；UIView 根 layer 的 delegate 就是该 UIView。
// delegate 是 unsafe_unretained，取用时需判类型（drawable 刚绑定，view 必存活）。
static UIView *mkxp_layerOwner(CALayer *layer) {
    if (!layer) return nil;
    id d = layer.delegate;
    if ([d isKindOfClass:[UIView class]]) return (UIView *)d;
    return nil;
}

static void swz_renderbufferStorage(id self, SEL _cmd, NSUInteger target, id drawable) {
    CALayer *layer = (CALayer *)drawable;
    if (layer != nil) {
        bool rebound = (layer != g_drawableLayer);
        if (!g_reportedDrawable) {
            fprintf(stderr, "[ios-embed] GL drawable bound: layer=%p ownerView=%p\n",
                    (void *)layer, (void *)mkxp_layerOwner(layer));
            g_reportedDrawable = true;
        } else if (rebound) {
            fprintf(stderr, "[ios-embed] GL drawable REBOUND: layer=%p ownerView=%p (was %p)\n",
                    (void *)layer, (void *)mkxp_layerOwner(layer), (void *)g_drawableLayer);
        }
        g_drawableLayer = layer;
        if (g_hostView && mkxp_layerOwner(layer) && rebound) {
            g_repinDone = false;   // 绑定真变了才允许重新搬运（否则 frame 会被重复 transform 畸变）
            mkxp_requestRepin();
        }
    }
    g_origRBS(self, _cmd, target, drawable);
}

// 读当前 FBO 中心与角落像素，判断引擎到底画没画出内容（每 120 帧一次）。
// present 之前调用：此时内容完整；调用的 rgss 线程上下文是 current。
static void mkxp_probePixels() {
    GLint fb = 0, vp[4] = {0,0,0,0};
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    glGetIntegerv(GL_VIEWPORT, vp);
    GLint w = vp[2], h = vp[3];
    if (w < 8 || h < 8) return;
    GLubyte c[4] = {0,0,0,0}, e[4] = {0,0,0,0};
    glReadPixels(w/2, h/2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, c);
    glReadPixels(w/8, h/8, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, e);
    fprintf(stderr, "[ios-embed] pxprobe: fb=%d vp=%dx%d center=%d,%d,%d,%d corner=%d,%d,%d,%d\n",
            fb, w, h, c[0], c[1], c[2], c[3], e[0], e[1], e[2], e[3]);
}

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    // present 前读（双缓冲下 present 后 back buffer 内容即失效）
    ++g_presentTotal;
    if (g_presentTotal % 120 == 1) mkxp_probePixels();
    // 金丝雀：第 2~13 帧直接给默认帧缓冲写会变色的内容（红→绿→蓝→白），
    // 与引擎无关。屏幕出现循环变色 → GL/合成链是通的（引擎不画才是问题）；
    // 屏幕全黑不变 → GL/合成链本身断。
    if (g_presentTotal >= 2 && g_presentTotal <= 13) {
        int phase = (int)((g_presentTotal - 2) / 3);
        float r = (phase % 2 == 0) ? 1.0f : 0.0f;
        float gg = (phase == 1) ? 1.0f : 0.0f;
        float b = (phase == 2) ? 1.0f : 0.0f;
        if (phase >= 3) { r = 1.0f; gg = 1.0f; b = 1.0f; }
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        glClearColor(r, gg, b, 1.0f);
        glClear(GL_COLOR_BUFFER_BIT);
    }
    BOOL r = g_origPresent(self, _cmd, target);
    if (r) ++g_presentOK; else ++g_presentFail;
    if (g_presentTotal % 300 == 1 || !r) {
        fprintf(stderr, "[ios-embed] present #%llu r=%d ok=%llu fail=%llu\n",
                (unsigned long long)g_presentTotal, (int)r,
                (unsigned long long)g_presentOK, (unsigned long long)g_presentFail);
    }
    return r;
}

static void mkxp_installHooks() {
    static bool done = false;
    if (done) return;
    done = true;
    Method m = class_getInstanceMethod([EAGLContext class], @selector(presentRenderbuffer:));
    g_origPresent = (BOOL (*)(id, SEL, NSUInteger))method_getImplementation(m);
    method_setImplementation(m, (IMP)swz_presentRenderbuffer);
    Method mr = class_getInstanceMethod([EAGLContext class],
                                        @selector(renderbufferStorage:fromDrawable:));
    g_origRBS = (void (*)(id, SEL, NSUInteger, id))method_getImplementation(mr);
    method_setImplementation(mr, (IMP)swz_renderbufferStorage);
    fprintf(stderr, "[ios-embed] GL hooks installed\n");
}

// 递归查找 layer 的 owner view（layer.view 为 nil 时的兜底）
static UIView *mkxp_findViewWithLayer(UIView *root, CALayer *layer) {
    if (!root || !layer) return nil;
    if (root.layer == layer) return root;
    for (UIView *sub in root.subviews) {
        UIView *r = mkxp_findViewWithLayer(sub, layer);
        if (r) return r;
    }
    return nil;
}

// 把真正出像素的 GL view 搬进宿主并等比居中缩放。
// 注意：保持 GL view 原始 bounds 不动（CAEAGLLayer 的 renderbuffer storage 按
// bounds×contentsScale 分配，改 bounds 会失配——Metal-backed GLES 下表现为
// present 全成功但画面全黑）；缩放用 transform（CA 层几何变换，不触发重建）。
static void mkxp_doRepin() {
    @try {
        if (g_repinDone) return;
        if (!g_hostView) { fprintf(stderr, "[ios-embed] repin: host nil\n"); return; }
        if (!g_drawableLayer) { fprintf(stderr, "[ios-embed] repin: no drawable yet\n"); return; }

        UIView *glView = mkxp_layerOwner(g_drawableLayer);
        if (!glView) {
            // layer.view 拿不到时，从 SDL 窗口树里递归找
            SDL_SysWMinfo wm;
            SDL_VERSION(&wm.version);
            if (SDL_GetWindowWMInfo(g_win, &wm) && wm.info.uikit.window) {
                UIWindow *sdlWin = (UIWindow *)wm.info.uikit.window;
                glView = mkxp_findViewWithLayer(sdlWin.rootViewController.view, g_drawableLayer);
                if (!glView) glView = mkxp_findViewWithLayer(sdlWin, g_drawableLayer);
            }
        }
        if (!glView) { fprintf(stderr, "[ios-embed] repin: GL view not found\n"); return; }

        CGRect orig = glView.frame;
        if (orig.size.width < 1 || orig.size.height < 1)
            orig = CGRectMake(0, 0, 896, 414);
        CGSize hostSize = g_hostView.bounds.size;
        CGFloat scale = MIN(hostSize.width / CGRectGetWidth(orig),
                            hostSize.height / CGRectGetHeight(orig));

        g_hostView.hidden = NO;
        [g_hostView layoutIfNeeded];
        [g_hostView addSubview:glView];
        glView.center = CGPointMake(hostSize.width / 2, hostSize.height / 2);
        glView.transform = CGAffineTransformMakeScale(scale, scale);
        [g_hostView bringSubviewToFront:glView];
        g_repinDone = true;

        // SDL 自建窗口压到最低层、保持可见（layer 附着完整，drawable 有效）
        SDL_SysWMinfo wm2;
        SDL_VERSION(&wm2.version);
        UIWindow *sdlWin = nil;
        if (SDL_GetWindowWMInfo(g_win, &wm2)) sdlWin = (UIWindow *)wm2.info.uikit.window;
        if (sdlWin) {
            sdlWin.windowLevel = -1000.0;
            sdlWin.hidden = NO;
        }

        fprintf(stderr,
            "[ios-embed] repin ok: glView=%p layer=%p bounds=%s scale=%.3f "
            "center=%s hostFrame=%s sdlWinLevel=%.0f\n",
            (void *)glView, (void *)glView.layer,
            NSStringFromCGRect(glView.bounds).UTF8String, (double)scale,
            NSStringFromCGPoint(glView.center).UTF8String,
            NSStringFromCGRect(g_hostView.bounds).UTF8String,
            sdlWin ? (double)sdlWin.windowLevel : -1.0);
    } @catch (NSException *e) {
        fprintf(stderr, "[ios-embed] repin exception: %s\n", e.reason.UTF8String);
    }
}

// ================= C 接口（由 main.cpp / Swift 调用） =================

extern "C" void mkxp_ios_embedIntoView(SDL_Window *win) {
    g_win = win;
    mkxp_installHooks();
    // 若宿主与 drawable 都已就绪（少见），立即搬运；否则等后到的一方触发
    if (g_hostView && g_drawableLayer) mkxp_requestRepin();
    else fprintf(stderr, "[ios-embed] embedIntoView: win=%p host=%p drawable=%p (wait)\n",
                 (void *)win, (void *)g_hostView, (void *)g_drawableLayer);
}

extern "C" void mkxp_ios_setHostView(void *view) {
    g_hostView = (__bridge UIView *)(view);
    // 宿主重建（PlatformView 被回收再创建）时允许重新搬运
    g_repinDone = false;
    fprintf(stderr, "[ios-embed] setHostView=%p win=%p\n", view, (void *)g_hostView.window);
    if (g_hostView && g_drawableLayer) mkxp_requestRepin();
}
