// ios_embed.mm — iOS 嵌入所需的 UIKit 窗口操作（Objective-C++）。
//
// 必须独立成 .mm：src/main.cpp 是纯 C++ 翻译单元，不能 #include <objc/...> 或
// 使用 id/SEL/objc_msgSend 这类 Objective-C 构造（CI 用 C++ 编译器编 main.cpp 时
// objc 头里的 extern "C" 会炸 "expected unqualified-id"）。SDL 自建的 UIWindow 的
// addSubview / setWindowLevel / makeKeyAndVisible 都是 ObjC 方法，只能在 ObjC++ 下调。
//
// mkxp_ios_raiseWindow 由 main.cpp（MKXPZ_IOS_EMBED 分支）调用，把 SDL 的渲染视图挂进
// 其自建窗口并抬高层级，盖过 Flutter 的占位视图，解决整屏黑。本文件与 main.cpp 均为
// 普通 C++ 符号（不带 extern "C"），Apple clang 的 Itanium ABI 名字修饰一致，链接自动匹配。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>

void mkxp_ios_raiseWindow(SDL_Window *win) {
    if (!win) return;
    SDL_SysWMinfo wm;
    SDL_VERSION(&wm.version);
    if (!SDL_GetWindowWMInfo(win, &wm)) return;
    UIWindow *sdlWin = wm.info.uikit.window;
    UIView *sdlView = wm.info.uikit.view;
    if (!sdlWin || !sdlView) return;
    if (![sdlView isDescendantOfView:sdlWin])
        [sdlWin addSubview:sdlView];
    sdlWin.windowLevel = 1500.0;
    [sdlWin makeKeyAndVisible];
}
