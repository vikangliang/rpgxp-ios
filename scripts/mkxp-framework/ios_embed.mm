// ios_embed.mm — iOS 嵌入（SDL 官方路径 + 诊断）。
//
// 2026-10-17 诊断结论链（已坐实）：
//   - SDL 自建 UIWindow 在 Flutter 场景里能合成：延迟置顶的绿块满屏可见 => 窗口在合成链、
//     位于浮层/Flutter 之上。
//   - renderbufferStorage: drawable=CAEAGLLayer bounds={0,0,414,896} contentsScale=2 => drawable
//     尺寸正常、storage 非 0；present r=1 100% 成功 => 呈现路径本身"调用成功"。
//   - 但窗口 GL 内容全黑、无 shader 报错。
//   剩余两种可能：(A) present 在 "OpenGL ES 2.0 Metal" 转译下实际不显示；(B) mkxp 场景渲染出黑。
//   本文件用 present hook 内联着色器画满屏红四边形（前 ~600 帧）来定音：红屏出现 => (A) 否、
//   present 正常，问题在 mkxp 场景；红屏不出现 => (A) 是，需切 ANGLE。
#import <SDL.h>
#import <SDL_syswm.h>
#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>
#import <stdio.h>
#import <objc/runtime.h>

static UIView *g_hostView = nil;
static SDL_Window *g_win = NULL;
static int g_drawW = 0, g_drawH = 0; // renderbufferStorage 时记录的 drawable 像素尺寸

// ---- 诊断 hook（模块加载即装，早于 SDL initGL 的 renderbufferStorage） ----
static void (*g_origRBS)(id, SEL, NSUInteger, id);
static BOOL (*g_origPresent)(id, SEL, NSUInteger);
static bool g_rbsLogged = false;
static uint64_t g_presentTotal = 0, g_presentOK = 0;

// ---- 红屏探针（懒编译，首次 present 时 GL 上下文已就绪） ----
static GLuint g_probeProg = 0, g_probeVBO = 0;
static bool g_probeTried = false;
static const int PROBE_FRAMES = 600;

static GLuint mkxp_compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok = 0; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[256]; glGetShaderInfoLog(s, sizeof(buf), NULL, buf);
        fprintf(stderr, "[ios-embed] probe shader compile fail: %s\n", buf);
        glDeleteShader(s); return 0;
    }
    return s;
}

static void mkxp_initProbe() {
    g_probeTried = true;
    const char *vs = "attribute vec2 a_pos; void main(){ gl_Position = vec4(a_pos,0.0,1.0); }";
    const char *fs = "precision mediump float; void main(){ gl_FragColor = vec4(1.0,0.0,0.0,1.0); }";
    GLuint v = mkxp_compile(GL_VERTEX_SHADER, vs);
    GLuint f = mkxp_compile(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) { g_probeProg = 0; return; }
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glBindAttribLocation(p, 0, "a_pos");
    glLinkProgram(p);
    GLint ok = 0; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) { char buf[256]; glGetProgramInfoLog(p, sizeof(buf), NULL, buf);
              fprintf(stderr, "[ios-embed] probe link fail: %s\n", buf); g_probeProg = 0; return; }
    g_probeProg = p;
    // 满屏四边形（NDC 两个三角形）
    static const GLfloat quad[8] = { -1,-1, 1,-1, -1,1, 1,1 };
    glGenBuffers(1, &g_probeVBO);
    glBindBuffer(GL_ARRAY_BUFFER, g_probeVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad), quad, GL_STATIC_DRAW);
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    fprintf(stderr, "[ios-embed] probe program ready (prog=%u vbo=%u)\n", p, g_probeVBO);
}

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

static BOOL swz_presentRenderbuffer(id self, SEL _cmd, NSUInteger target) {
    uint64_t n = ++g_presentTotal;
    if (n <= 5 || n % 600 == 1) {
        fprintf(stderr, "[ios-embed] present #%llu (drawablePx=%dx%d)\n",
                (unsigned long long)n, g_drawW, g_drawH);
    }

    // ---- 红屏探针：前 PROBE_FRAMES 帧，在 mkxp 绘制之后、present 之前，画满屏红 ----
    if (n <= PROBE_FRAMES) {
        if (!g_probeTried) mkxp_initProbe();
        if (g_probeProg) {
            GLint svProg=0, svAB=0, svEB=0, svTex=0, svVA[4]={0,0,0,0};
            GLboolean svBlend=glIsEnabled(GL_BLEND), svDepth=glIsEnabled(GL_DEPTH_TEST),
                      svScissor=glIsEnabled(GL_SCISSOR_TEST);
            glGetIntegerv(GL_CURRENT_PROGRAM, &svProg);
            glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &svAB);
            glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &svEB);
            glGetIntegerv(GL_TEXTURE_BINDING_2D, &svTex);
            for (int i=0;i<4;i++) glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &svVA[i]);

            glUseProgram(g_probeProg);
            glBindBuffer(GL_ARRAY_BUFFER, g_probeVBO);
            glEnableVertexAttribArray(0);
            glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);
            if (g_drawW>0) glViewport(0,0,g_drawW,g_drawH);
            glDisable(GL_BLEND); glDisable(GL_DEPTH_TEST); glDisable(GL_SCISSOR_TEST);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);

            // 还原 mkxp 状态
            glBindBuffer(GL_ARRAY_BUFFER, svAB);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, svEB);
            glBindTexture(GL_TEXTURE_2D, svTex);
            for (int i=0;i<4;i++) {
                if (svVA[i]) glEnableVertexAttribArray(i); else glDisableVertexAttribArray(i);
            }
            if (svBlend) glEnable(GL_BLEND);
            if (svDepth) glEnable(GL_DEPTH_TEST);
            if (svScissor) glEnable(GL_SCISSOR_TEST);
            glUseProgram(svProg);
        }
    }

    BOOL r = g_origPresent(self, _cmd, target);
    if (r) ++g_presentOK;
    if (n == PROBE_FRAMES) fprintf(stderr, "[ios-embed] probe window end (present ok=%llu)\n",
                                   (unsigned long long)g_presentOK);
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
    fprintf(stderr, "[ios-embed] embedIntoView: win=%p scene=%p\n", (void *)sdlWin, (void *)sdlWin.windowScene);

    if ([NSThread isMainThread]) mkxp_show(sdlWin);
    else dispatch_async(dispatch_get_main_queue(), ^{ mkxp_show(sdlWin); });

    // 延迟置顶绿块：0.8s 后 SDL 的 GL view 已挂上，把绿块置顶 => 窗口在合成链必可见
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *m = [[UIView alloc] initWithFrame:sdlWin.bounds];
        m.backgroundColor = [UIColor colorWithRed:0.0 green:0.9 blue:0.2 alpha:1.0];
        m.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [sdlWin addSubview:m]; [sdlWin bringSubviewToFront:m];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [m removeFromSuperview]; });
    });

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
