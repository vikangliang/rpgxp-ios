// ios_embed.mm — iOS 嵌入（SDL 官方路径 + 诊断）。
//
// 2026-10-17 结论链：
//   - SDL 自建 UIWindow 在 Flutter 场景里能合成（recheck 显示 key=1/hidden=0/alpha=1，
//     且"全黑但有摇杆"说明 SDL 窗口位于浮层之下、Flutter 之上，正在被合成，只是 GL 内容黑）。
//   - 引擎每帧 present 成功，但 GL 探针（glClear/glReadPixels）在 "OpenGL ES 2.0 Metal - 101"
//     （Apple 的 OpenGL-on-Metal 转译层）下不可靠（readback 恒为 0），故不再依赖 GL 探针。
//   - 本文件改为：① 模块加载时抢装 EAGLContext hook，抓 initGL 阶段的
//     renderbufferStorage:fromDrawable:，打 drawable 的 bounds/contentsScale（若 bounds 为 0
//     → renderbuffer storage 0×0 → 全黑根因）；② 一个延迟置顶的绿块判定窗口是否真在合成链。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <objc/runtime.h>

static UIView *g_hostView = nil;
static SDL_Window *g_win = NULL;

// ---- 诊断：模块加载即抢装 EAGLContext hook（早于 SDL initGL 的 renderbufferStorage） ----
static void (*g_origRBS)(id, SEL, NSUInteger, id);
static BOOL (*g_origPresent)(id, SEL, NSUInteger);
static bool g_rbsLogged = false;
static uint64_t g_presentTotal = 0, g_presentOK = 0;

static void swz_renderbufferStorage(id self, SEL _cmd, NSUInteger target, id drawable) {
    if (!g_rbsLogged && drawable != nil) {
        CALayer *layer = (CALayer *)drawable;
        CGRect b = layer.bounds;
        fprintf(stderr,
            "[ios-embed] renderbufferStorage: drawable=%s bounds={%.0f,%.0f,%.0f,%.0f} "
            "contentsScale=%.2f opaque=%d\n",
            NSStringFromClass([drawable class]).UTF8String,
            b.origin.x, b.origin.y, b.size.width, b.size.height,
            (double)layer.contentsScale, (int)layer.opaque);
        g_rbsLogged = true;
    }
    g_origRBS(self, _cmd, target, drawable);
}

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    BOOL r = g_origPresent(self, _cmd, target);
    ++g_presentTotal;
    if (r) ++g_presentOK;
    if (g_presentTotal <= 5 || g_presentTotal % 600 == 1) {
        fprintf(stderr, "[ios-embed] present #%llu r=%d ok=%llu\n",
                (unsigned long long)g_presentTotal, (int)r,
                (unsigned long long)g_presentOK);
    }
    return r;
}

__attribute__((constructor))
static void mkxp_installHooksEarly() {
    Class cls = [EAGLContext class];
    Method m = class_getInstanceMethod(cls, @selector(renderbufferStorage:fromDrawable:));
    if (m) {
        g_origRBS = (void (*)(id, SEL, NSUInteger, id))method_getImplementation(m);
        method_setImplementation(m, (IMP)swz_renderbufferStorage);
    }
    Method mp = class_getInstanceMethod(cls, @selector(presentRenderbuffer:));
    if (mp) {
        g_origPresent = (BOOL (*)(id, SEL, NSUInteger))method_getImplementation(mp);
        method_setImplementation(mp, (IMP)swz_presentRenderbuffer);
    }
    fprintf(stderr, "[ios-embed] EAGLContext hooks installed (constructor)\n");
}

static void mkxp_show(UIWindow *sdlWin) {
    @try {
        UIWindow *ref = nil;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (!w.isHidden && w.windowScene &&
                w.windowScene.activationState == UISceneActivationStateForegroundActive) {
                ref = w; break;
            }
        }
        UIWindowScene *refScene = (UIWindowScene *)ref.windowScene;
        if (refScene && sdlWin.windowScene != refScene)
            sdlWin.windowScene = refScene;
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
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(win, &wm) || wm.subsystem != SDL_SYSWM_UIKIT) {
        fprintf(stderr, "[ios-embed] embedIntoView: not UIKit subsystem\n");
        return;
    }
    UIWindow *sdlWin = (UIWindow *)wm.info.uikit.window;
    if (!sdlWin) { fprintf(stderr, "[ios-embed] sdlWin nil\n"); return; }
    g_win = win;
    fprintf(stderr, "[ios-embed] embedIntoView: win=%p scene=%p\n",
            (void *)sdlWin, (void *)sdlWin.windowScene);

    if ([NSThread isMainThread]) mkxp_show(sdlWin);
    else dispatch_async(dispatch_get_main_queue(), ^{ mkxp_show(sdlWin); });

    // 延迟置顶绿块：0.8s 后 SDL 的 GL view 已挂上，把绿块置顶——若窗口在合成链上必可见，
    // 否则说明 SDL 窗口根本没被合成（被 Flutter 黑底盖住）。4s 后移除。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *m = [[UIView alloc] initWithFrame:sdlWin.bounds];
        m.backgroundColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.2 alpha:1.0];
        m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [sdlWin addSubview:m];
        [sdlWin bringSubviewToFront:m];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [m removeFromSuperview]; });
    });

    // 2s/5s 复查：SDL 事件循环是否事后隐藏窗口
    for (NSNumber *d in @[ @2.0, @5.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            fprintf(stderr, "[ios-embed] recheck@%.0fs: hidden=%d key=%d frame=%s alpha=%.2f\n",
                    d.doubleValue, sdlWin.isHidden, sdlWin.isKeyWindow,
                    NSStringFromCGRect(sdlWin.frame).UTF8String, (double)sdlWin.alpha);
        });
    }
}

extern "C" void mkxp_ios_setHostView(void *view) {
    g_hostView = (__bridge UIView *)(view);
    fprintf(stderr, "[ios-embed] setHostView=%p\n", view);
}
