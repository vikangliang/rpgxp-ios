// MkxpLinkAnchor.m — 链接锚点（由 CI 的 scripts/ios-link-mkxp.rb 加入 Runner 编译）。
//
// 存在的理由：mkxp 插件的 Swift 桥（MkxpBridge.o）在 pod 的静态框架归档里，
// 对 MKXP 框架三个 C 符号的引用发生在 ld 扫描 MKXP.framework 之后——按需加载
// 顺序不对就拉不到（Undefined symbol: _mkxp_run）；而 -force_load 全量载入又会把
// Ruby static-linked-ext 烘进的 zlib 等对象与 vcpkg 的 libz/libpng 重叠符号一起载入，
// 炸 800+ duplicate symbols。两难之间，让 Runner 自己的目标文件直接引用这三个符号：
// 链接器一开头它们就是未决状态，MKXP.framework 在链接线任何位置都能被按需拉中。
// 符号被取地址即产生未决引用；used 属性防止数组被优化掉。
extern int mkxp_run(const char *gamePath);
extern void mkxp_key(int rgssKey, int down);
extern void mkxp_quit(void);

__attribute__((used)) static const void *mkxp_link_anchors[] = {
    (const void *)mkxp_run,
    (const void *)mkxp_key,
    (const void *)mkxp_quit,
};
