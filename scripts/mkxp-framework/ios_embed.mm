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
static bool g_rbsAllocated = false;
static int g_rbsW = 0, g_rbsH = 0;
static uint64_t g_presentTotal = 0, g_presentOK = 0;

/* 由 mkxp 的 graphics.cpp 提供：当前合成结果纹理 + letterbox 几何 */
extern "C" void mkxp_ios_getScene(GLuint *tex, int *sw, int *sh,
                                  int *ox, int *oy, int *ww, int *wh);

/* iOS 兜底：present 前一刻由我们完成最后的上屏 blit。
 * 绘制状态（着色器/VBO）首次使用时惰性建立。 */
static GLuint g_blitProg = 0, g_blitVbo = 0;
static GLint g_blitTexLoc = -1;
static bool g_blitTried = false;

static void mkxp_initBlitProg() {
    g_blitTried = true;
    const char *vs =
        "attribute vec2 a_pos; attribute vec2 a_uv; varying vec2 v_uv;"
        "void main(){ v_uv = a_uv; gl_Position = vec4(a_pos, 0.0, 1.0); }";
    const char *fs =
        "precision mediump float; uniform sampler2D u_tex; varying vec2 v_uv;"
        "void main(){ gl_FragColor = texture2D(u_tex, v_uv); }";
    GLuint v = glCreateShader(GL_VERTEX_SHADER);
    glShaderSource(v, 1, &vs, NULL);
    glCompileShader(v);
    GLuint f = glCreateShader(GL_FRAGMENT_SHADER);
    glShaderSource(f, 1, &fs, NULL);
    glCompileShader(f);
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glBindAttribLocation(p, 0, "a_pos");
    glBindAttribLocation(p, 1, "a_uv");
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char buf[256];
        glGetProgramInfoLog(p, sizeof(buf), NULL, buf);
        fprintf(stderr, "[ios-embed] blit link fail: %s\n", buf);
        return;
    }
    g_blitProg = p;
    g_blitTexLoc = glGetUniformLocation(p, "u_tex");
    glGenBuffers(1, &g_blitVbo);
    fprintf(stderr, "[ios-embed] blit ready (prog=%u vbo=%u)\n",
            g_blitProg, g_blitVbo);
}

/* 把 mkxp 合成好的场景纹理 letterbox 居中画到默认帧缓冲。
 * 必须在 present 前一刻调用：只有那时默认帧缓冲才是完整的。 */
static void mkxp_presentBlit() {
    if (!g_blitTried) mkxp_initBlitProg();
    if (!g_blitProg) return;

    GLuint tex = 0;
    int sw = 0, sh = 0, ox = 0, oy = 0, ww = 0, wh = 0;
    mkxp_ios_getScene(&tex, &sw, &sh, &ox, &oy, &ww, &wh);
    if (!tex || ww <= 0 || wh <= 0 || sw <= 0 || sh <= 0) return;

    /* 视口必须是整个 drawable，否则 NDC 会被映射到旧的 512x384 小视口 */
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glViewport(0, 0, ww, wh);

    float x0 = ((float)ox / (float)ww) * 2.f - 1.f;
    float x1 = ((float)(ox + sw) / (float)ww) * 2.f - 1.f;
    float y0 = ((float)oy / (float)wh) * 2.f - 1.f;
    float y1 = ((float)(oy + sh) / (float)wh) * 2.f - 1.f;

    /* TL,TR,BR,BL；FBO 纹理第 0 行是游戏底部，故 v 随 y 递增（不翻转） */
    const float vb[16] = {
        x0, y1, 0.f, 1.f,
        x1, y1, 1.f, 1.f,
        x1, y0, 1.f, 0.f,
        x0, y0, 0.f, 0.f
    };

    glClearColor(0.f, 0.f, 0.f, 1.f);
    glClear(GL_COLOR_BUFFER_BIT);

    glUseProgram(g_blitProg);
    if (g_blitTexLoc >= 0) glUniform1i(g_blitTexLoc, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, tex);
    glBindBuffer(GL_ARRAY_BUFFER, g_blitVbo);
    glBufferData(GL_ARRAY_BUFFER, sizeof(vb), vb, GL_STREAM_DRAW);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 16, (const GLvoid *)0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 16, (const GLvoid *)8);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glUseProgram(0);

    static int logged = 0;
    if (logged < 3) {
        ++logged;
        fprintf(stderr,
            "[ios-embed] presentBlit tex=%u %dx%d -> letterbox(%d,%d %dx%d) "
            "in %dx%d err=0x%x\n",
            tex, sw, sh, ox, oy, sw, sh, ww, wh, (unsigned)glGetError());
    }
}

static void swz_renderbufferStorage(id self, SEL _cmd, NSUInteger target, id drawable) {
    if (drawable != nil) {
        CALayer *layer = (CALayer *)drawable;
        CGRect b = layer.bounds;
        int w = (int)(b.size.width * layer.contentsScale);
        int h = (int)(b.size.height * layer.contentsScale);
        g_drawW = w;
        g_drawH = h;

        /* 统计重分配次数：iOS 在 present 后作废颜色缓冲，需要重新
         * renderbufferStorage 才能让默认帧缓冲恢复完整。
         * 注意：这里不能跳过它，跳过会让 FBO 0 一直不完整。 */
        {
            static uint64_t n = 0;
            ++n;
            if (n <= 3 || n % 600 == 0)
                fprintf(stderr, "[ios-embed] renderbufferStorage #%llu (%dx%d)\n",
                        (unsigned long long)n, w, h);
        }

        g_rbsW = w;
        g_rbsH = h;
        g_rbsAllocated = true;
        fprintf(stderr,
            "[ios-embed] renderbufferStorage: drawable=%s bounds={%.0f,%.0f,%.0f,%.0f} "
            "scale=%.2f drawablePx=%dx%d opaque=%d\n",
            NSStringFromClass([drawable class]).UTF8String,
            b.origin.x, b.origin.y, b.size.width, b.size.height,
            (double)layer.contentsScale, w, h, (int)layer.opaque);
    }
    g_origRBS(self, _cmd, target, drawable);
}

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t n = ++g_presentTotal;
    if (n <= 5 || n % 600 == 1) {
        fprintf(stderr, "[ios-embed] present #%llu (drawablePx=%dx%d)\n",
                (unsigned long long)n, g_drawW, g_drawH);
    }

    // 读 mkxp 在 present 前实际留下的视口。修复后应等于整屏 drawable（或 mkxp 自己
    // 算出的 letterbox 区域）；若仍停留在 defScreen(512x384) 说明 winSize 未同步。
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

        for (int i=0;i<4;i++) lastVP[i] = vp[i];
    }

    /* 兜底：在 present 前一刻自己把画面画上去（该时机 FBO 0 才完整） */
    mkxp_presentBlit();

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
