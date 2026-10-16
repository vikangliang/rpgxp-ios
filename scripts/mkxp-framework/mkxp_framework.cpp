// =============================================================================
// mkxp_framework.cpp — MKXP-Z 框架化入口（iOS 嵌入用，M1-A）
//
// 上游 mkxp-z 是独立 app：int main + SDL 自建全屏窗口。本文件把它包装成可嵌入
// 静态库，供 Flutter 侧（mkxp 插件）通过 MKXP.h 的三个 C 接口调用：
//
//   int  mkxp_run(const char *gamePath)  主线程启动引擎，立即返回 0
//   void mkxp_key(int rgssKey, int down) 注入 RGSS 按键（Input::ButtonCode）
//   void mkxp_quit(void)                 走正常关机流程
//
// 依赖（均由 scripts/build_mkxp_ios.sh 在编译前准备好）：
//   1. framework-entry.patch：main.cpp 的 main() -> extern "C" mkxp_z_main()；
//      input.cpp 在绑定变化时重建 g_buttonToScancode 反查表。
//   2. CMake 定义 WORKDIR_CURRENT：mkxp_z_main 不再 chdir 到 SDL_GetBasePath()，
//      使用调用方（mkxp_run）设置的工作目录作为游戏根。
//   3. MKXP.h（构建脚本生成）中的三个声明与本文件定义一致。
//
// 线程模型：SDL_Init/建窗/RGSS 线程在主线程（UIKit 安全；后台线程里
// SDL_Init(VIDEO)/SDL_CreateWindow 会直接崩，2026-10-16 真机实测）。EventThread::process
// 这个阻塞事件循环由 mkxp_z_main 甩到【后台线程】，主线程 run loop 不被占死，Core Animation
// 才能上屏（否则点启动后画面冻在 Flutter 浮层、无游戏画面）。mkxp_run 立即返回，Dart 侧不阻塞；
// g_engineRunning 由后台线程在引擎真正退出时复位。SDL 事件队列线程安全，按键与退出请求
// 经 SDL_PushEvent 投递，走引擎原生输入管线。
// =============================================================================

#include <SDL.h>
#include <SDL_scancode.h>
#include <dispatch/dispatch.h>

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>

#include "filesystem/filesystem.h"
#include "input/input.h"

/* 由 framework-entry.patch 改名的原 main() */
extern "C" int mkxp_z_main(int argc, char *argv[]);

/* iOS 上 SDL 不接管 main（libSDL2main 已从框架合并中排除），但个别 SDL2 对象
 * 仍可能引用 SDL_main；提供无害桩——永远不会被调用（入口是 mkxp_z_main）。 */
extern "C" int SDL_main(int argc, char *argv[]) {
  (void)argc;
  (void)argv;
  return 0;
}

/* 由 input.cpp 发布：rgssKey(Input::ButtonCode) -> SDL_Scancode */
extern std::unordered_map<int, SDL_Scancode> g_buttonToScancode;
extern std::mutex g_buttonToScancodeMtx;

std::atomic<bool> g_engineRunning{false};

extern "C" {

/* 启动引擎。gamePath 指向游戏目录（含 Game.ini / Data/）。
 * 返回：0 成功（已派发到主线程）；-1 参数为空；-2 引擎已在运行；-3 游戏目录不存在。 */
int mkxp_run(const char *gamePath)
{
    if (!gamePath || !gamePath[0])
        return -1;

    if (g_engineRunning.load())
        return -2;

    /* stdout/stderr → Documents/mkxp.log：引擎 C++ 日志、Ruby/Essentials 启动报错、
     * shader 编译错误全部落盘，供 App 内日志页读取（无 Mac 环境的唯一调试通道）。
     * 沙盒进程 HOME 即 App 沙盒根。stderr 不缓冲，崩溃前也能看到已写内容。 */
    {
        const char *home = getenv("HOME");
        if (home && home[0])
        {
            std::string logPath = std::string(home) + "/Documents/mkxp.log";
            if (freopen(logPath.c_str(), "a", stdout))
                setvbuf(stdout, nullptr, _IOLBF, 0);
            if (freopen(logPath.c_str(), "a", stderr))
                setvbuf(stderr, nullptr, _IONBF, 0);
            fprintf(stderr, "\n===== mkxp engine start: %s =====\n", gamePath);
        }
    }

    /* 工作目录 = 游戏目录。配合 WORKDIR_CURRENT，mkxp_z_main 不会再 chdir。 */
    if (!mkxp_fs::setCurrentDirectory(gamePath))
        return -3;

    /* SDL 嵌入既有 iOS App 必须先声明「主循环由宿主管」，否则 SDL 会尝试
     * 接管 UIApplication。必须在 SDL_Init 之前调用（任意线程均可）。 */
    SDL_SetMainReady();

    /* 引擎初始化（SDL_Init/建窗/RGSS 线程）在主线程（UIKit 安全），阻塞事件循环由
     * mkxp_z_main 内部甩到后台线程；本函数立即返回，主线程 run loop 不被占死，iOS 合成器
     * 才能上屏。g_engineRunning 由后台线程在引擎真正退出时复位。argv 用块内复合字面量，避免悬空指针。 */
    g_engineRunning.store(true);
    dispatch_async(dispatch_get_main_queue(), ^{
        mkxp_z_main(1, (char *[]){"mkxp", nullptr});
    });

    return 0;
}

/* 注入 RGSS 按键。rgssKey 为 Input::ButtonCode（Down=2/Left=4/Right=6/Up=8，
 * A=11/B=12/C=13/X=14/Y=15/Z=16/L=17/R=18/F5=25...）。down 非 0 为按下。
 * 经反查表换算成 SDL scancode 后以 SDL_KEYDOWN/UP 入队，由 EventThread
 * 的事件循环消费。未绑定的键位静默忽略。 */
void mkxp_key(int rgssKey, int down)
{
    if (!g_engineRunning.load())
        return;

    SDL_Scancode scan;
    {
        std::lock_guard<std::mutex> _(g_buttonToScancodeMtx);
        auto it = g_buttonToScancode.find(rgssKey);
        if (it == g_buttonToScancode.end())
            return;
        scan = it->second;
    }

    SDL_Event e;
    SDL_zero(e);
    e.type = down ? SDL_KEYDOWN : SDL_KEYUP;
    e.key.state = down ? SDL_PRESSED : SDL_RELEASED;
    e.key.repeat = 0;
    e.key.keysym.scancode = scan;
    e.key.keysym.sym = SDL_GetKeyFromScancode(scan);
    SDL_PushEvent(&e);
}

/* 请求关机：SDL_QUIT -> EventThread::process 置 terminate -> 引擎走完清理
 * 流程（SDL_Quit 等）后 g_engineThread 结束。 */
void mkxp_quit()
{
    if (!g_engineRunning.load())
        return;

    SDL_Event e;
    SDL_zero(e);
    e.type = SDL_QUIT;
    SDL_PushEvent(&e);
}

} /* extern "C" */
