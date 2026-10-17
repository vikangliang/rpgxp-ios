// ios_embed.mm — iOS 嵌入（SDL 官方路径 + 窗口上屏修复）。
//
// 2026-10-17 结论链：搬视图路线全死（present 成功但不上屏、折断触摸链）→ 回到 SDL
// 官方路径；但官方路径下连 UIKit canary 绿块都不显示 → SDL 自建 UIWindow 就没在屏上。
// iOS 13+ UIWindow 必须挂在【前台活跃 UIWindowScene】上才显示；SDL 自建 window 的
// scene 可能为空或挂错场景。本文件：
//   1) 从可见窗口（Flutter 主窗口）取 scene，强制覆盖 SDL window 的 windowScene；
//   2) hidden=NO + level 1999（盖 Flutter、低于原生浮层 2002）+ makeKeyAndVisible；
//   3) 0.5s 后二次 makeKeyAndVisible（防 Flutter/浮层抢 key 后未再上屏），并打
//      canary 绿块 4 秒（验证窗口真在屏上）；
//   4) 全部状态（scene 对比、bounds、level）打日志 → mkxp.log。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <objc/runtime.h>
#import <OpenGLES/ES2/gl.h>

static void mkxp_glCanary(void);
static void (*g_origPresent)(id, SEL, NSUInteger);
static bool g_canaryArmed = false;

static void swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    if (g_canaryArmed) mkxp_glCanary();
    g_origPresent(self, _cmd, target);
}

static void mkxp_installPresentHook() {
    Method m = class_getInstanceMethod([EAGLContext class], @selector(presentRenderbuffer:));
    g_origPresent = (void (*)(id, SEL, NSUInteger))method_getImplementation(m);
    method_setImplementation(m, (IMP)swz_presentRenderbuffer);
    fprintf(stderr, "[ios-embed] present hook installed\n");
}

/// 找当前可见的前台窗口（优先 Flutter 的），用于取其 scene 与做对比日志。
static UIWindow *mkxp_findVisibleWindow() {
    NSArray<UIWindow *> *wins = UIApplication.sharedApplication.windows;
    for (UIWindow *w in wins) {
        if (!w.isHidden && w.windowScene != nil &&
            w.windowScene.activationState == UISceneActivationStateForegroundActive)
            return w;
    }
    return wins.firstObject;
}

static void mkxp_show(UIWindow *sdlWin, int pass) {
    @try {
        UIWindow *ref = mkxp_findVisibleWindow();
        UIWindowScene *refScene = (UIWindowScene *)ref.windowScene;

        // 若 SDL window 没挂 scene、或挂的不是前台 scene → 强制覆盖为参考窗口的 scene
        if (refScene && sdlWin.windowScene != refScene) {
            sdlWin.windowScene = refScene;
            fprintf(stderr, "[ios-embed] scene override -> %p (was)\n", (void *)refScene);
        }

        sdlWin.windowLevel = 1999.0;
        sdlWin.hidden = NO;
        [sdlWin layoutIfNeeded];
        [sdlWin makeKeyAndVisible];

        fprintf(stderr,
            "[ios-embed] show(pass=%d): win=%p hidden=%d level=%.0f frame=%s "
            "scene=%p (refScene=%p same=%d) rootViewBounds=%s key=%d\n",
            pass, (void *)sdlWin, sdlWin.hidden, (double)sdlWin.windowLevel,
            NSStringFromCGRect(sdlWin.frame).UTF8String,
            (void *)sdlWin.windowScene, (void *)refScene,
            (int)(sdlWin.windowScene == refScene),
            NSStringFromCGRect(sdlWin.rootViewController.view.bounds).UTF8String,
            (int)sdlWin.isKeyWindow);

        // canary 绿块（与引擎 GL 无关）：验证 SDL window 真在屏上。
        // 注意：直接加到 UIWindow 本身——SDL 的 UIKit 后端可能把 GL view 直接挂到
        // window 上，rootVC.view 根本不在视图树里（此时加到 rootVC.view 会不可见）。
        if (pass == 0) {
            UIView *marker = [[UIView alloc] initWithFrame:sdlWin.bounds];
            marker.backgroundColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.2 alpha:1.0];
            marker.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [sdlWin addSubview:marker];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ [marker removeFromSuperview]; });
        }

        // 诊断：rootVC.view 是否真在树上；sdlWin 的子视图层级；所有 window 的 level
        UIView *rv = sdlWin.rootViewController.view;
        fprintf(stderr, "[ios-embed] diag: rv.superview=%p rv.window=%p rvIsHidden=%d\n",
                (void *)rv.superview, (void *)rv.window, rv.isHidden);
        int depth = 0;
        UIView *cur = rv;
        while (cur && depth < 12) {
            fprintf(stderr, "[ios-embed]   tree[%d]: %s frame=%s hidden=%d\n",
                    depth, NSStringFromClass(cur.class).UTF8String,
                    NSStringFromCGRect(cur.frame).UTF8String, cur.isHidden);
            cur = cur.superview; depth++;
        }
        int idx = 0;
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            fprintf(stderr, "[ios-embed]   win[%d]: %p level=%.0f hidden=%d frame=%s\n",
                    idx++, (void *)w, (double)w.windowLevel, w.isHidden,
                    NSStringFromCGRect(w.frame).UTF8String);
        }
    } @catch (NSException *e) {
        fprintf(stderr, "[ios-embed] show exception: %s\n", e.reason.UTF8String);
    }
}

// =============================================================================
// DEBUG：present 前用引擎当前上下文向默认帧缓冲写红/蓝相间色（前 40 帧每 4 帧切换）。
// 本次是【SDL 官方路径、零视图搬运】，若此色仍不上屏 → 引擎/GL 侧问题；
// 若上屏 → 之前所有黑屏都源于搬运视图损坏了合成链。同时打 viewport/FBO/error。
// =============================================================================
static uint64_t g_canaryFrame = 0;

static void mkxp_glCanary() {
    // 只在前 40 个 present 内生效（避免长期干扰引擎渲染）
    if (g_canaryFrame >= 40) return;
    ++g_canaryFrame;
    int phase = (int)(g_canaryFrame / 4) % 2;
    GLint fb = 0, vp[4] = {0,0,0,0}, err = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &fb);
    glGetIntegerv(GL_VIEWPORT, vp);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glViewport(0, 0, 896, 414);
    glClearColor(phase ? 0.0f : 1.0f, 0.0f, phase ? 1.0f : 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    err = glGetError();
    fprintf(stderr, "[ios-embed] glcanary: frame=%llu phase=%s fb=%d vp=%dx%d err=%d\n",
            (unsigned long long)g_canaryFrame, phase ? "BLUE" : "RED",
            fb, vp[2], vp[3], err);
}

extern "C" void mkxp_ios_embedIntoView(SDL_Window *win) {
    if (!win) return;
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(win, &wm)) {
        fprintf(stderr, "[ios-embed] SDL_GetWindowWMInfo failed: %s\n", SDL_GetError());
        return;
    }
    if (wm.subsystem != SDL_SYSWM_UIKIT) {
        fprintf(stderr, "[ios-embed] subsystem=%d not UIKit\n", (int)wm.subsystem);
        return;
    }
    UIWindow *sdlWin = (UIWindow *)wm.info.uikit.window;
    if (!sdlWin) { fprintf(stderr, "[ios-embed] sdlWin nil\n"); return; }
    fprintf(stderr, "[ios-embed] embedIntoView(show path): win=%p scene=%p\n",
            (void *)sdlWin, (void *)sdlWin.windowScene);
    mkxp_installPresentHook();
    // canary 在 initGL 之后才有效（GL 上下文已建）——推迟 1s 武装，避开建窗前的 present
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ g_canaryArmed = true; });
    if ([NSThread isMainThread]) {
        mkxp_show(sdlWin, 0);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ mkxp_show(sdlWin, 0); });
    }
    // 遮挡关系可视化：给每个可见 window 贴不同色块（6s），截图即可看出谁挡住了谁。
    //   SDL 窗口=绿(0.9) / level≈10 的 Flutter 辅助窗口=红 / level>2000 浮层=黄
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in UIApplication.sharedApplication.windows) {
            if (w.isHidden) continue;
            BOOL isSDL = (w == sdlWin);
            BOOL isOver = (w.windowLevel > 2000);
            UIColor *col = isSDL ? [UIColor colorWithRed:0 green:0.9 blue:0.2 alpha:0.9]
                         : isOver ? [UIColor colorWithRed:1 green:0.85 blue:0 alpha:0.9]
                         : [UIColor colorWithRed:1 green:0 blue:0 alpha:0.9];
            UIView *m = [[UIView alloc] initWithFrame:w.bounds];
            m.backgroundColor = col;
            m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            m.tag = 0x5ADE;
            [w addSubview:m];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                for (UIView *s in [w.subviews copy]) {
                    if (s.tag == 0x5ADE) [s removeFromSuperview];
                }
            });
        }
    });
    // 0.5s 后二次上屏（等 SDL 内部对 window 的后续处理与 key 竞争稳定下来）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ mkxp_show(sdlWin, 1); });
}

// 宿主注入已废弃（官方路径不需要搬视图），保留空实现防止旧 IPA 链接报 undefined。
extern "C" void mkxp_ios_setHostView(void *view) {
    (void)view;
    fprintf(stderr, "[ios-embed] setHostView ignored (官方路径)\n");
}
