// ios_embed.mm — iOS 嵌入（终版架构：SDL 官方路径）。
//
// 2026-10-17 一天实测结论：把 SDL 的 view 搬进 Flutter 宿主 / 隐藏 SDL 窗口等
// “搬运视图”路线全部失败——引擎 present 每帧成功、canary 直接写默认帧缓冲也不上屏，
// 证明被剥离的 view/layer 已脱离真实合成链。且搬走 view 同时折断 SDL 的触摸链。
//
// 终版：完全不动 SDL 的视图树。SDL 自建 UIWindow 保持官方行为——自己可见、自己
// makeKeyAndVisible、自己 present、自己收事件（虚拟摇杆经 SDL_PushEvent 入队即通）。
// iOS 13+ 下 SDL 自建 window 偶发Scene 未挂载导致不上屏，本文件只补这一件事：
//   1) windowScene 为空则挂到前台活跃 scene；
//   2) makeKeyAndVisible；
//   3) windowLevel 抬到 1999（低于 MkxpTouchOverlay 的 alert+2=2002，高于 Flutter
//      主 window 的 normal=0），保证游戏画面盖在 Flutter 界面之上、又不挡原生浮层。
//
// main.cpp（MKXPZ_IOS_EMBED 分支）建窗后调用 mkxp_ios_embedIntoView。
// 另附 UIKit canary：往 SDL 窗口塞一个 4 秒纯绿块——侧载时看到绿屏即证明
// “SDL 窗口真在屏上”（与 GL 无关），随后恢复。诊断走 stderr → mkxp.log。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <stdio.h>

static void mkxp_doShow(UIWindow *sdlWin) {
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
        // 层级：盖过 Flutter（normal=0），低于原生触摸浮层（alert+2=2002）
        sdlWin.windowLevel = 1999.0;
        sdlWin.hidden = NO;
        [sdlWin makeKeyAndVisible];

        fprintf(stderr,
            "[ios-embed] show ok: win=%p hidden=%d level=%.0f frame=%s scene=%p "
            "rootVC=%p rootViewLayer=%s\n",
            (void *)sdlWin, sdlWin.hidden, (double)sdlWin.windowLevel,
            NSStringFromCGRect(sdlWin.frame).UTF8String, (void *)sdlWin.windowScene,
            (void *)sdlWin.rootViewController,
            NSStringFromClass(sdlWin.rootViewController.view.layer.class).UTF8String);

        // UIKit canary：4 秒纯绿块，验证 SDL 窗口真在屏上（与引擎 GL 无关）
        UIView *marker = [[UIView alloc] initWithFrame:sdlWin.rootViewController.view.bounds];
        marker.backgroundColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.2 alpha:1.0];
        marker.translatesAutoresizingMaskIntoConstraints = NO;
        [sdlWin.rootViewController.view addSubview:marker];
        [NSLayoutConstraint activateConstraints:@[
            [marker.leadingAnchor  constraintEqualToAnchor:sdlWin.rootViewController.view.leadingAnchor],
            [marker.trailingAnchor constraintEqualToAnchor:sdlWin.rootViewController.view.trailingAnchor],
            [marker.topAnchor      constraintEqualToAnchor:sdlWin.rootViewController.view.topAnchor],
            [marker.bottomAnchor   constraintEqualToAnchor:sdlWin.rootViewController.view.bottomAnchor],
        ]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [marker removeFromSuperview]; });
    } @catch (NSException *e) {
        fprintf(stderr, "[ios-embed] show exception: %s\n", e.reason.UTF8String);
    }
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
    fprintf(stderr, "[ios-embed] embedIntoView(show path): win=%p\n", (void *)sdlWin);
    if ([NSThread isMainThread]) mkxp_doShow(sdlWin);
    else dispatch_async(dispatch_get_main_queue(), ^{ mkxp_doShow(sdlWin); });
}

// 宿主注入已废弃（官方路径不需要搬视图），保留空实现防止旧 IPA 链接报 undefined。
extern "C" void mkxp_ios_setHostView(void *view) {
    (void)view;
    fprintf(stderr, "[ios-embed] setHostView ignored (官方路径)\n");
}
