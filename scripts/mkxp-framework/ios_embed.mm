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
#import <objc/runtime.h>

// ---- DEBUG：hook EAGLContext，统计引擎是否真正每帧上屏、绑定的 drawable 是哪个 layer ----
static BOOL (*g_origPresent)(id, SEL, NSUInteger);
static void (*g_origRBS)(id, SEL, NSUInteger, id);
static CALayer *g_visibleLayer = NULL;   // embed 后可见的 sdlView.layer
static uint64_t g_presentOK = 0, g_presentFail = 0;
static uint64_t g_presentTotal = 0;
static bool g_storageMatched = false;    // drawable layer 是否等于可见 layer

static void swz_renderbufferStorage(id self, SEL _cmd, NSUInteger target, id drawable) {
    if (!g_storageMatched && drawable != nil) {
        bool same = ((CALayer *)drawable == g_visibleLayer);
        fprintf(stderr, "[ios-embed] GL drawable bound: layer=%p visibleLayer=%p match=%d\n",
                (void *)(__bridge CALayer *)drawable, (void *)g_visibleLayer, (int)same);
        g_storageMatched = true;
    }
    g_origRBS(self, _cmd, target, drawable);
}

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    BOOL r = g_origPresent(self, _cmd, target);
    ++g_presentTotal;
    if (r) ++g_presentOK; else ++g_presentFail;
    // 每 120 帧或每次失败打一次，避免日志爆炸
    if (g_presentTotal % 120 == 1 || !r) {
        fprintf(stderr, "[ios-embed] present #%llu r=%d ok=%llu fail=%llu\n",
                (unsigned long long)g_presentTotal, (int)r,
                (unsigned long long)g_presentOK, (unsigned long long)g_presentFail);
    }
    return r;
}

static void mkxp_installPresentHook() {
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
    fprintf(stderr, "[ios-embed] present hook installed\n");
}

// 4 秒后打一次汇总，无引擎时也能从日志判断"有没有在 present"
static void mkxp_schedulePresentSummary() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fprintf(stderr, "[ios-embed] present summary: total=%llu ok=%llu fail=%llu\n",
                (unsigned long long)g_presentTotal,
                (unsigned long long)g_presentOK, (unsigned long long)g_presentFail);
    });
}

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

        // 保持 sdlView 原始 bounds 不动（896×414@横屏）——CAEAGLLayer 的
        // renderbufferStorage 是按 bounds×contentsScale 分配的，改 bounds 会让
        // 已绑定的 drawable storage 失配（Metal-backed GLES 下表现为 present 全成功
        // 但画面全黑）。缩放改用 transform（CA 层几何变换，不触发 storage 重建）。
        CGRect sdlFrame = sdlView.frame.size.height > 0 ? sdlView.frame : CGRectMake(0, 0, 896, 414);
        // aspect-fit 居中到 host
        CGSize hostSize = host.bounds.size;
        CGFloat scale = MIN(hostSize.width / CGRectGetWidth(sdlFrame),
                            hostSize.height / CGRectGetHeight(sdlFrame));
        CGAffineTransform t = CGAffineTransformMakeScale(scale, scale);
        CGPoint fitCenter = CGPointMake(hostSize.width / 2, hostSize.height / 2);
        sdlView.translatesAutoresizingMaskIntoConstraints = NO;
        [host addSubview:sdlView];
        sdlView.center = fitCenter;
        sdlView.transform = t;
        [host bringSubviewToFront:sdlView];

        // SDL 自建窗口不再需要显示（避免盖屏/空窗），但保留其存在供 SDL 内部引用
        sdlWin.windowLevel = -1000.0;  // 压到 Flutter window 之下，让 Flutter 完全盖住
        sdlWin.hidden = NO;            // 不 hidden：layer 保持附着完整，drawable 有效

        g_visibleLayer = sdlView.layer;

        fprintf(stderr,
            "[ios-embed] embed ok: sdlView=%p sdlLayer=%p host=%p hostFrame=%s hostWin=%p "
            "sdlWinFrame=%s sdlWinHidden=%d sdlWinLevel=%.0f sdlViewFrame=%s sdlViewBounds=%s "
            "sdlViewWinFrame=%s screen=%s statusBar=%ld winScene=%ld scale=%.2f\n",
            (void *)sdlView, (void *)sdlView.layer, (void *)host,
            NSStringFromCGRect(host.bounds).UTF8String, (void *)host.window,
            NSStringFromCGRect(sdlWin.frame).UTF8String, sdlWin.hidden,
            (double)sdlWin.windowLevel,
            NSStringFromCGRect(sdlView.frame).UTF8String,
            NSStringFromCGRect(sdlView.bounds).UTF8String,
            NSStringFromCGRect(sdlView.window ? sdlView.window.frame : CGRectZero).UTF8String,
            
            NSStringFromCGRect(UIScreen.mainScreen.bounds).UTF8String,
            (long)[UIApplication sharedApplication].statusBarOrientation,
            (long)host.window.windowScene.interfaceOrientation,
            (double)scale);

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
    mkxp_installPresentHook();
    mkxp_schedulePresentSummary();
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
