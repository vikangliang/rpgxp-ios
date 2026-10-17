// ios_embed.mm — iOS 嵌入（SDL 官方路径 + 画面 letterbox 修正）。
//
// 2026-10-17 诊断结论链（已坐实）：
//   - SDL 自建 UIWindow 在 Flutter 场景里能合成：延迟置顶的绿块满屏可见 => 窗口在合成链。
//   - renderbufferStorage: drawable bounds={0,0,414,896} scale=2.0 => drawable=828x1792 正常；
//     present 100% 成功；无 shader 报错；引擎跑到 6 万+ 帧无重启（BGM 在放）。
//   - 根因：mkxp 把游戏以 defScreen=512x384 的**小视口**画到默认帧缓冲的左下角
//     （日志：pre-present viewport={0,0,512,384}，drawable 却是 828x1792）
//     => 游戏缩在屏幕左下角一个小方块里，其余全黑，看起来就是"黑屏"。
//
// 修法：无法用符号拦截改写 glViewport（iOS 两级命名空间，mkxp/SDL 的引用直连
// OpenGLES 框架，dlsym(RTLD_NEXT) 拦截不到，实测 expand 日志从未出现）。改为
// 在 UIKit 层做修正：把 SDL 窗口的根视图整体**缩放+平移**，让左下角那块游戏内容
// 按自身宽高比 letterbox 居中铺满屏幕。与 mkxp 内部实现无关，横竖屏自适应。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <stdio.h>
#import <objc/runtime.h>

static UIView *g_hostView = nil;
static SDL_Window *g_win = NULL;
static UIWindow *g_sdlWin = nil;             // SDL 自建窗口（用于 UIKit 层缩放画面）
static int g_drawW = 0, g_drawH = 0;         // renderbufferStorage 时记录的 drawable 像素尺寸

// ---- 诊断 hook（模块加载即装，早于 SDL initGL 的 renderbufferStorage） ----
static void (*g_origRBS)(id, SEL, NSUInteger, id);
static BOOL (*g_origPresent)(id, SEL, NSUInteger);
static bool g_rbsLogged = false;
static uint64_t g_presentTotal = 0, g_presentOK = 0;

static void swz_renderbufferStorage(id self, SEL _cmd, NSUInteger target, id drawable) {
    if (!g_rbsLogged && drawable != nil) {
        CALayer *layer = (CALayer *)drawable;
        CGRect b = layer.bounds;
        g_drawW = (int)(b.size.width * layer.contentsScale);
        g_drawH = (int)(b.size.height * layer.contentsScale);
        fprintf(stderr,
            "[ios-embed] renderbufferStorage: drawable=%s bounds={%.0f,%.0f,%.0f,%.0f} "
            "scale=%.2f drawablePx=%dx%d opaque=%d\n",
            NSStringFromClass([drawable class]).UTF8String,
            b.origin.x, b.origin.y, b.size.width, b.size.height,
            (double)layer.contentsScale, g_drawW, g_drawH, (int)layer.opaque);
        g_rbsLogged = true;
    }
    g_origRBS(self, _cmd, target, drawable);
}

// 把 mkxp 实际渲染区域（GL 视口，原点在左下）映射到屏幕居中的 letterbox：
// 对 SDL 窗口的根视图施加 缩放 s + 平移，使该区域按自身宽高比居中铺满。
// 坐标换算：GL 像素 -> UIKit 点（除以 contentsScale），GL 左下原点 -> UIKit 左上原点。
static void mkxp_applyLetterbox(UIWindow *win, GLint vp[4]) {
    if (!win || g_drawW <= 0 || g_drawH <= 0 || vp[2] <= 0 || vp[3] <= 0) return;
    if (vp[2] >= g_drawW && vp[3] >= g_drawH) return;   // 已是整屏，无需放大

    CGFloat cs = win.screen.scale ?: [UIScreen mainScreen].scale;
    if (cs <= 0) cs = 2.0;
    CGFloat dw = (CGFloat)g_drawW / cs;                          // 窗口宽（点）
    CGFloat dh = (CGFloat)g_drawH / cs;                          // 窗口高（点）
    CGFloat cw = (CGFloat)vp[2] / cs;                            // 游戏内容宽（点）
    CGFloat ch = (CGFloat)vp[3] / cs;                            // 游戏内容高（点）
    CGFloat cx = (CGFloat)vp[0] / cs;                            // 内容左上角 x（点）
    CGFloat cy = dh - ((CGFloat)vp[1] + (CGFloat)vp[3]) / cs;    // 内容左上角 y（点）

    CGFloat aspect = cw / ch;                                    // 游戏自身宽高比(4:3)
    CGFloat tw, th;
    if (dw / dh > aspect) { th = dh; tw = dh * aspect; }         // 左右留边
    else                  { tw = dw; th = dw / aspect; }         // 上下留边
    CGFloat tx = (dw - tw) / 2.0, ty = (dh - th) / 2.0;
    CGFloat s  = tw / cw;
    CGFloat dx = tx - s * cx;
    CGFloat dy = ty - s * cy;

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *v = win.rootViewController.view;
        if (!v) v = win.subviews.firstObject;
        if (!v) v = win;
        fprintf(stderr,
            "[ios-embed] letterbox view: class=%s frame=%s layer=%s bounds=%s\n",
            NSStringFromClass([v class]).UTF8String,
            NSStringFromCGRect(v.frame).UTF8String,
            NSStringFromClass([v.layer class]).UTF8String,
            NSStringFromCGRect(v.layer.bounds).UTF8String);
        @try {
            // 以左上角为锚点，令变换等价于 p -> s*p + (dx,dy)
            v.layer.anchorPoint = CGPointZero;
            v.layer.position = CGPointZero;
            CGAffineTransform t = CGAffineTransformMakeScale(s, s);
            t = CGAffineTransformTranslate(t, dx, dy);
            v.transform = t;
            fprintf(stderr,
                "[ios-embed] letterbox: content={%.1f,%.1f,%.1f,%.1f} -> "
                "target={%.1f,%.1f,%.1f,%.1f} scale=%.3f offset={%.1f,%.1f}\n",
                (double)cx, (double)cy, (double)cw, (double)ch,
                (double)tx, (double)ty, (double)tw, (double)th,
                (double)s, (double)dx, (double)dy);
        } @catch (NSException *e) {
            fprintf(stderr, "[ios-embed] letterbox exception: %s\n", e.reason.UTF8String);
        }
    });
}

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t n = ++g_presentTotal;
    if (n <= 5 || n % 600 == 1) {
        fprintf(stderr, "[ios-embed] present #%llu (drawablePx=%dx%d)\n",
                (unsigned long long)n, g_drawW, g_drawH);
    }

    // 读 mkxp 在 present 前实际留下的视口；若它小于整屏（即游戏被画在左下角小方块），
    // 施加 letterbox 变换把那块内容放大居中。仅在视口变化时应用一次。
    {
        GLint vp[4] = {0,0,0,0};
        glGetIntegerv(GL_VIEWPORT, vp);
        static GLint lastVP[4] = {-1,-1,-1,-1};
        static int vpLogged = 0;
        bool changed = (vp[0]!=lastVP[0]||vp[1]!=lastVP[1]||vp[2]!=lastVP[2]||vp[3]!=lastVP[3]);
        if (vpLogged < 10 || changed) {
            fprintf(stderr,
                "[ios-embed] mkxp pre-present: viewport={%d,%d,%d,%d} drawablePx=%dx%d\n",
                (int)vp[0],(int)vp[1],(int)vp[2],(int)vp[3], g_drawW, g_drawH);
            vpLogged++;
        }
        // 直读"游戏框内部"的像素：若框内也是黑 => 游戏根本没被画出来（FBO/场景问题），
        // 单靠 letterbox 放大是没用的；若框内有颜色 => 内容存在，只是被挤在角落。
        {
            static int insideLogged = 0;
            if (insideLogged < 5 && vp[2] > 0 && vp[3] > 0) {
                GLubyte px[4] = {0,0,0,0};
                // 框中心（GL 左下原点）
                glReadPixels(vp[0] + vp[2] / 2, vp[1] + vp[3] / 2, 1, 1,
                             GL_RGBA, GL_UNSIGNED_BYTE, px);
                GLubyte corner[4] = {0,0,0,0};
                glReadPixels(vp[0] + 4, vp[1] + 4, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
                GLubyte outside[4] = {0,0,0,0};
                glReadPixels(g_drawW / 2, g_drawH / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, outside);
                fprintf(stderr,
                    "[ios-embed] inside-box center={%d,%d,%d,%d} corner={%d,%d,%d,%d} "
                    "outside={%d,%d,%d,%d} (vp={%d,%d,%d,%d})\n",
                    px[0],px[1],px[2],px[3], corner[0],corner[1],corner[2],corner[3],
                    outside[0],outside[1],outside[2],outside[3],
                    (int)vp[0],(int)vp[1],(int)vp[2],(int)vp[3]);
                insideLogged++;
            }
        }

        if (changed) {
            for (int i=0;i<4;i++) lastVP[i] = vp[i];
            mkxp_applyLetterbox(g_sdlWin, vp);
        }
    }

    BOOL r = g_origPresent(self, _cmd, target);
    if (r) ++g_presentOK;
    return r;
}

__attribute__((constructor))
static void mkxp_installHooksEarly() {
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
    g_sdlWin = sdlWin;   // 供 present hook 做 letterbox 缩放
    fprintf(stderr, "[ios-embed] embedIntoView: win=%p scene=%p\n", (void *)sdlWin, (void *)sdlWin.windowScene);

    if ([NSThread isMainThread]) mkxp_show(sdlWin);
    else dispatch_async(dispatch_get_main_queue(), ^{ mkxp_show(sdlWin); });

    for (NSNumber *d in @[ @2.0, @5.0 ]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue*NSEC_PER_SEC)),
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
