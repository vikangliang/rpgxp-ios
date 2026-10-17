// ios_embed.mm — iOS 嵌入：把 SDL 的渲染视图搬进 Flutter 提供的可见 UIView。
//
// 必须独立成 .mm：src/main.cpp 被 iOS 工具链按 C 编译，不能碰 objc 构造；
// SDL 自建 UIWindow 的 view、UIKit 的 addSubview/约束/层级都是 ObjC 方法。
//
// 为什么是“搬 view”而不是“抬 SDL 窗口盖过 Flutter”：
//   之前的 raise 方案把 SDL 自建 UIWindow 提到 level 1500 盖屏，但 SDL 实际把像素
//   画进了那个独立窗口——它是否上屏受 iOS 窗口系统摆布，实测就是盖住了 Flutter 却
//   不出画面（一片空窗）。正确做法是让 SDL 的 view 直接成为【可见的 PlatformView 子视图】，
//   渲染图层(CAEAGLLayer)挂进 Flutter 真正显示出来的容器，画面才出得来。
//
// 流程：MkxpPlatformView 创建时调用 mkxp_ios_setHostView 注入宿主 UIView；
//      main.cpp（MKXPZ_IOS_EMBED 分支）建窗后调用 mkxp_ios_embedIntoView，
//      本文件在【主线程】把 SDL 的 rootVC.view 加进宿主并填充满，再隐藏 SDL 自建窗口。
// 所有诊断走 stderr → mkxp.log（无 Xcode 控制台也能定位）。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <stdio.h>

// 注意：本文件被 mkxp-z 以 -fno-objc-arc（手动引用计数）编译，不能用 __weak/__strong
// 等 ARC 限定符。宿主 UIView 由 Flutter 的 MkxpPlatformView 强持有，引擎运行期有效，
// 这里只存裸指针即可。
static UIView *g_hostView = nil;
// 引擎建窗时存下 SDL_Window*：Flutter 的 UiKitView 首帧才注入宿主（晚于 launchGame），
// 届时用已存的 window 补做 embed，解决“启动先于 PlatformView”的时序竞态。
static SDL_Window *g_win = NULL;
static void mkxp_doEmbed(SDL_Window *win, UIView *host);

extern "C" void mkxp_ios_setHostView(void *view) {
    g_hostView = (__bridge UIView *)(view);
    fprintf(stderr, "[ios-embed] setHostView=%p\n", view);
    if (g_win) {
        // 宿主晚到：立刻把已建好的 SDL 窗口视图搬进来（主线程）
        dispatch_async(dispatch_get_main_queue(), ^{ mkxp_doEmbed(g_win, g_hostView); });
    }
}

static void mkxp_doEmbed(SDL_Window *win, UIView *host) {
    @try {
        if (!host) { fprintf(stderr, "[ios-embed] embed: host nil\n"); return; }
        SDL_SysWMinfo wm;
        SDL_VERSION(&wm.version);
        if (!SDL_GetWindowWMInfo(win, &wm)) {
            fprintf(stderr, "[ios-embed] embed: SDL_GetWindowWMInfo failed: %s\n", SDL_GetError());
            return;
        }
        if (wm.subsystem != SDL_SYSWM_UIKIT) {
            fprintf(stderr, "[ios-embed] embed: subsystem=%d not UIKit\n", (int)wm.subsystem);
            return;
        }
        UIWindow *sdlWin = (UIWindow *)wm.info.uikit.window;
        if (!sdlWin) { fprintf(stderr, "[ios-embed] embed: sdlWin nil\n"); return; }
        UIViewController *vc = sdlWin.rootViewController;
        UIView *sdlView = vc.view;
        if (!sdlView) { fprintf(stderr, "[ios-embed] embed: sdlView nil\n"); return; }

        host.hidden = NO;
        [host layoutIfNeeded];

        // 解除 SDL 自带约束/变换，改由我们约束填满宿主
        sdlView.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:sdlView];
        [NSLayoutConstraint activateConstraints:@[
            [sdlView.leadingAnchor  constraintEqualToAnchor:host.leadingAnchor],
            [sdlView.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [sdlView.topAnchor      constraintEqualToAnchor:host.topAnchor],
            [sdlView.bottomAnchor   constraintEqualToAnchor:host.bottomAnchor],
        ]];
        sdlView.frame = host.bounds;
        [host bringSubviewToFront:sdlView];

        // SDL 自建窗口不再需要显示（避免盖屏/空窗），但保留其存在供 SDL 内部引用
        sdlWin.hidden = YES;

        fprintf(stderr,
            "[ios-embed] embed ok: sdlView=%p host=%p hostFrame=%s hostWin=%p "
            "sdlFrame=%s screen=%s statusBar=%ld winScene=%ld sdlViewContentsScale=%f\n",
            (void *)sdlView, (void *)host,
            NSStringFromCGRect(host.bounds).UTF8String, (void *)host.window,
            NSStringFromCGRect(sdlWin.frame).UTF8String,
            NSStringFromCGRect(UIScreen.mainScreen.bounds).UTF8String,
            (long)[UIApplication sharedApplication].statusBarOrientation,
            (long)host.window.windowScene.interfaceOrientation,
            (double)sdlView.layer.contentsScale);

        // DEBUG 判定实验：在宿主顶层叠一块洋红标记（5 秒后自动移除）。
        // 侧载后看到洋红块 → 宿主可见、布局正确，黑屏根因在引擎 GL 呈现；
        // 完全看不到洋红 → 宿主/PlatformView 没真正上屏（朝向/层级问题）。
        UIView *marker = [[UIView alloc] init];
        marker.backgroundColor = [UIColor colorWithRed:1.0 green:0.0 blue:1.0 alpha:0.85];
        marker.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:marker];
        [NSLayoutConstraint activateConstraints:@[
            [marker.leadingAnchor  constraintEqualToAnchor:host.leadingAnchor],
            [marker.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
            [marker.topAnchor      constraintEqualToAnchor:host.topAnchor],
            [marker.bottomAnchor   constraintEqualToAnchor:host.bottomAnchor],
        ]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [marker removeFromSuperview]; });
    } @catch (NSException *e) {
        fprintf(stderr, "[ios-embed] embed exception: %s\n", e.reason.UTF8String);
    }
}

extern "C" void mkxp_ios_embedIntoView(SDL_Window *win) {
    g_win = win;
    UIView *host = g_hostView;
    if (!host) {
        // 宿主尚未注入（UiKitView 首帧晚于 launchGame）：window 已存，等 setHostView 再补 embed
        fprintf(stderr, "[ios-embed] embed: window ready but host not set yet (deferring until PlatformView injects)\n");
        return;
    }
    if ([NSThread isMainThread]) {
        mkxp_doEmbed(win, host);
    } else {
        // UIKit 视图操作必须在主线程；dispatch_async 避免与主线程互锁
        dispatch_async(dispatch_get_main_queue(), ^{ mkxp_doEmbed(win, host); });
    }
}
