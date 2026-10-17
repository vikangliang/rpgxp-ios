// ios_embed.mm — iOS 嵌入所需的 UIKit 窗口操作（Objective-C++）。
//
// 必须独立成 .mm：src/main.cpp 被 iOS 工具链按 C 编译，不能碰 objc 构造；
// SDL 自建 UIWindow 的 scene/level/hidden/makeKeyAndVisible 都是 ObjC 方法。
//
// mkxp_ios_raiseWindow 由 main.cpp（MKXPZ_IOS_EMBED 分支）调用。注意三个 iOS 13+ 的坑：
//  1) 该调用来自 SDL 事件线程（非主线程），UIKit 操作必须派发到主线程，否则静默不生效；
//  2) SDL 自建的 UIWindow 若未关联 UIWindowScene，永远不会上屏（黑屏且无任何警告）；
//  3) SDL/Flutter 随后可能重排窗口层级，需要延时再抬一次兜底。
// 所有诊断信息走 stderr → mkxp.log，无 Xcode 控制台也能定位卡点。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <stdio.h>

static void mkxp_logWin(const char *tag, UIWindow *w) {
    if (!w) { fprintf(stderr, "[ios-embed] %s: window=nil\n", tag); return; }
    const char *layer = w.rootViewController.view.layer
        ? NSStringFromClass([w.rootViewController.view.layer class]).UTF8String : "(nil)";
    fprintf(stderr,
        "[ios-embed] %s: win=%p hidden=%d level=%.0f frame=%s scene=%p rootVC=%p layer=%s onMain=%d\n",
        tag, (void *)w, w.hidden, (double)w.windowLevel,
        NSStringFromCGRect(w.frame).UTF8String,
        (void *)w.windowScene, (void *)w.rootViewController,
        layer, [NSThread isMainThread]);
}

static void mkxp_doRaise(UIWindow *sdlWin) {
    @try {
        if (!sdlWin.windowScene) {
            for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]] &&
                    s.activationState == UISceneActivationStateForegroundActive) {
                    sdlWin.windowScene = (UIWindowScene *)s;
                    fprintf(stderr, "[ios-embed] attached missing windowScene=%p\n", (void *)s);
                    break;
                }
            }
        }
        sdlWin.hidden = NO;
        sdlWin.windowLevel = 1500.0;
        [sdlWin makeKeyAndVisible];
        mkxp_logWin("after-raise", sdlWin);
    } @catch (NSException *e) {
        fprintf(stderr, "[ios-embed] raise exception: %s\n", e.reason.UTF8String);
    }
}

extern "C" void mkxp_ios_raiseWindow(SDL_Window *win) {
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
    mkxp_logWin("pre-raise", sdlWin);
    if (!sdlWin) return;

    if ([NSThread isMainThread]) {
        mkxp_doRaise(sdlWin);
    } else {
        // dispatch_async 而非 sync：避免与主线程互相等待造成死锁
        dispatch_async(dispatch_get_main_queue(), ^{ mkxp_doRaise(sdlWin); });
    }
    // 0.6s 后再抬一次，兜底 SDL/Flutter 的窗口重排
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ mkxp_doRaise(sdlWin); });
}
