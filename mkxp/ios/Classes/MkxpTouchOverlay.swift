import UIKit
import MKXP

/// 原生触摸控制浮层（M2 阶段二）。
///
/// 游戏运行时 SDL 自建全屏窗口盖在 Flutter 之上并吞掉触摸，因此虚拟控制键必须是一个
/// 位于 SDL 窗口之上的原生 UIWindow，按钮直调 `MkxpBridge.key`（不依赖 Flutter 主线程）。
/// 根视图 `isUserInteractionEnabled = false`，让游戏区的触摸穿透到下层 SDL 窗口；
/// 只有摇杆与动作键子视图接收触摸。
///
/// 键位映射（用户指定）：
///   方向：Up=8 / Down=2 / Left=4 / Right=6（Input::ButtonCode）
///   动作：C 确定=13 / ✕ 取消=12 / Z=电脑键盘Z（RGSS A）=11 / ☰ 菜单=电脑键盘D（RGSS Z）=16
///   肩键：L=电脑键盘A（RGSS X）=14 / R=电脑键盘S（RGSS Y）=15（mkxp-z 默认键表：A→X、S→Y）
final class MkxpTouchOverlay: NSObject {
  static let shared = MkxpTouchOverlay()

  /// RGSS 键码（Input::ButtonCode），与 scripts/mkxp-framework/mkxp_framework.cpp 注释一致。
  private let KEY_UP: Int32 = 8, KEY_DOWN: Int32 = 2, KEY_LEFT: Int32 = 4, KEY_RIGHT: Int32 = 6

  private var window: UIWindow?
  private var controlsView: UIView?
  private var actionButtons: [UIButton] = []
  private var menuButton: UIButton?
  private var controlsHidden = false

  /// 动作键触感。与圆盘方向键同为 .light，保持手感一致。
  /// prepare() 提前预热 Taptic Engine，避免首次按下时反馈迟到或丢失。
  private let actionHaptic = UIImpactFeedbackGenerator(style: .light)

  /// 启动加载 HUD：必须画在 SDL 引擎窗口（level 1999）【之上】——引擎窗口
  /// 创建后立刻以纯黑盖住 Flutter，Flutter 侧的加载提示根本看不见。
  private var loadingWindow: UIWindow?
  private var loadingTimer: Timer?
  private var fpsWindow: UIWindow?
  private var fpsLabel: UILabel?
  private var fpsTimer: Timer?

  // MARK: - 加载 HUD

  /// 引擎启动时展示“加载中”HUD（幂等）；引擎出首帧后自动收起。
  func showLoading() {
    guard loadingWindow == nil else { return }
    let scene = (UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene)
      ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
    guard let scene else { return }
    let size = CGSize(width: 156, height: 116)
    let win = UIWindow(windowScene: scene)
    win.windowLevel = UIWindow.Level(rawValue: 2005)   // 高于 SDL 引擎窗口(1999)与触摸浮层
    win.backgroundColor = .clear
    // 关键：HUD 窗口必须【不接收触摸】，否则全屏窗口会挡住下层触摸浮层的所有按键
    win.isUserInteractionEnabled = false
    let vc = UIViewController()
    vc.view.backgroundColor = .clear
    let box = UIView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))
    box.backgroundColor = UIColor(white: 0.07, alpha: 0.86)
    box.layer.cornerRadius = 18
    box.translatesAutoresizingMaskIntoConstraints = false
    let spinner = UIActivityIndicatorView(style: .large)
    spinner.color = .white
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()
    let label = UILabel()
    label.text = "正在启动游戏…"
    label.textColor = UIColor(white: 1, alpha: 0.85)
    label.font = .systemFont(ofSize: 14, weight: .medium)
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    box.addSubview(spinner)
    box.addSubview(label)
    vc.view.addSubview(box)
    // 用约束居中：设备旋转（HUD 创建时 scene 已横屏）也不歪——
    // UIScreen.bounds 恒为竖屏坐标，按它算 frame 会在横屏下跑到底部
    NSLayoutConstraint.activate([
        box.centerXAnchor.constraint(equalTo: vc.view.centerXAnchor),
        box.centerYAnchor.constraint(equalTo: vc.view.centerYAnchor),
        box.widthAnchor.constraint(equalToConstant: size.width),
        box.heightAnchor.constraint(equalToConstant: size.height),
        spinner.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        spinner.topAnchor.constraint(equalTo: box.topAnchor, constant: 20),
        label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
        label.centerXAnchor.constraint(equalTo: box.centerXAnchor),
        label.leadingAnchor.constraint(greaterThanOrEqualTo: box.leadingAnchor, constant: 8),
        label.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
    ])
    win.rootViewController = vc
    win.isHidden = false
    loadingWindow = win

    // 轮询引擎首帧；60 秒兜底超时自动收起
    var waited: TimeInterval = 0
    loadingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
      waited += 0.3
      if MkxpBridge.firstFrameShown() || waited >= 60 {
        t.invalidate()
        self?.hideLoading()
      }
    }
  }

  func hideLoading() {
    loadingTimer?.invalidate()
    loadingTimer = nil
    loadingWindow?.isHidden = true
    loadingWindow = nil
  }

  // MARK: - FPS 角标（m4 优化：实时显示帧率诊断流畅度）

  /// 在 SDL 引擎窗口(1999)之上建一个非交互原生窗口，右上角显示实时 FPS；
  /// 由 0.5s 轮询 MkxpBridge.fps() 更新，引擎退出时 hide() 调 hideFps() 收起。
  func showFps() {
    guard fpsWindow == nil else { return }
    guard let scene = (UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene)
      ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene) else { return }
    let win = UIWindow(windowScene: scene)
    win.windowLevel = UIWindow.Level(rawValue: 2004)  // 高于 SDL 引擎窗(1999)，低于加载 HUD(2005)
    win.backgroundColor = .clear
    win.isUserInteractionEnabled = false
    let vc = UIViewController()
    vc.view.backgroundColor = .clear
    let label = UILabel()
    label.text = "-- FPS"
    label.textColor = UIColor(white: 1, alpha: 0.9)
    label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
    label.textAlignment = .right
    label.translatesAutoresizingMaskIntoConstraints = false
    vc.view.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor, constant: 6),
      label.trailingAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
    ])
    win.rootViewController = vc
    win.isHidden = false
    fpsWindow = win
    fpsLabel = label
    fpsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
      let f = MkxpBridge.fps()
      guard let s = self, let lbl = s.fpsLabel else { return }
      let v = Int(f.rounded())
      let color: UIColor = f >= 55 ? UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
                    : f >= 30 ? UIColor(red: 1.0, green: 0.84, blue: 0.20, alpha: 1)
                    : UIColor(red: 1.0, green: 0.27, blue: 0.23, alpha: 1)
      lbl.text = "\(v) FPS"
      lbl.textColor = color
    }
  }

  func hideFps() {
    fpsTimer?.invalidate()
    fpsTimer = nil
    fpsWindow?.isHidden = true
    fpsWindow = nil
    fpsLabel = nil
  }

  // MARK: - 生命周期

  /// 引擎启动后调用：创建并展示浮层（幂等）。
  func show() {
    if let win = window {
      win.isHidden = false
      actionHaptic.prepare()   // 切回前台/重新显示时补一次预热
      showFps()
      return
    }
    let scene = (UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene)
      ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
      ?? UIApplication.shared.windows.first?.windowScene
    guard let scene else {
      MkxpLog.append("[overlay] show FAILED: no active scene")
      return
    }   // 无可用 scene（极少见）：下次 show() 重试
    let win = UIWindow(windowScene: scene)
    win.windowLevel = UIWindow.Level.alert + 2   // 高于 SDL 与 Flutter 窗口
    let vc = UIViewController()
    vc.view.backgroundColor = .clear
    win.rootViewController = vc

    let root = vc.view!
    // 注意：父视图 isUserInteractionEnabled=false 会连子视图一起禁掉（UIKit 陷阱），
    // 导致所有按钮收不到触摸——之前“按键全无反应”就是它。故 root 必须开启交互，
    // 空白区域穿透交给 ctl 的 hitTest 覆写（命中自身时返回 nil，让触摸落到下层 SDL 窗口）。
    root.isUserInteractionEnabled = true
    let ctl = MkxpPassthroughView(frame: root.bounds)
    ctl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    root.addSubview(ctl)
    controlsView = ctl

    buildDpad(in: ctl)
    buildActionButtons(in: ctl, root: root)
    buildShoulderButtons(in: ctl, root: root)
    buildMenuButton(in: ctl, root: root)
    actionHaptic.prepare()   // 预热 Taptic Engine：首次按动作键时不掉反馈

    window = win
    win.isHidden = false
    win.makeKeyAndVisible()
    MkxpLog.append("[overlay] show OK level=\(win.windowLevel.rawValue)")
    showFps()
  }

  func hide() {
    window?.isHidden = true
    hideLoading()
    hideFps()
  }

  /// 切换整体可见性（同时恢复 key window 到 Flutter，避免遮挡返回手势）。
  func toggle() {
    guard let win = window else { show(); return }
    controlsHidden.toggle()
    win.isHidden = controlsHidden
    if !controlsHidden {
      win.makeKeyAndVisible()
    } else {
      // 把 key window 交还 Flutter，否则 Flutter 收不到触摸/系统手势
      UIApplication.shared.windows
        .first { $0 != win && $0.windowLevel == .normal }?
        .makeKey()
    }
  }

  // MARK: - 控件构建

  /// 圆盘方向区：单一触摸追踪视图（整盘命中）。
  /// 触摸点相对盘心的角度判 4 向（点哪亮哪），中心小圆环为死区，
  /// 换向触发轻触感；手指可滑动连续换向、抬起精准释放。
  private func buildDpad(in ctl: UIView) {
    let side: CGFloat = 204      // 圆盘直径
    let cx: CGFloat = 104        // 盘心 x（左侧偏下，少挡画面）
    let h = ctl.bounds.height   // 用真实窗口高度（横屏时≠UIScreen.main.bounds）
    let cy = h - 150             // 盘心 y
    let pad = MkxpDpadView(frame: CGRect(
        x: cx - side / 2, y: cy - side / 2, width: side, height: side))
    pad.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
    ctl.addSubview(pad)
  }

  private func buildActionButtons(in ctl: UIView, root: UIView) {
    // (label, RGSS key) —— 按用户键位要求：
    //   C 确定=13 / ✕ 取消=12 / Z=电脑键盘Z（RGSS A）=11 / ☰ 菜单=电脑键盘D（RGSS Z）=16
    let items: [(String, Int32)] = [
      ("C", 13), ("✕", 12),
      ("Z", 11), ("☰", 16),
    ]
    let d: CGFloat = 72, gap: CGFloat = 14
    let block = d * 2 + gap
    let w = root.bounds.width    // 用真实窗口尺寸（横屏时 w=896 h=414）
    let h = root.bounds.height
    let x0 = w - block - 22
    let y0 = h - block - 36
    let positions: [CGRect] = [
      CGRect(x: x0,            y: y0,            width: d, height: d),
      CGRect(x: x0 + d + gap,  y: y0,            width: d, height: d),
      CGRect(x: x0,            y: y0 + d + gap,  width: d, height: d),
      CGRect(x: x0 + d + gap,  y: y0 + d + gap,  width: d, height: d),
    ]
    for (i, (label, key)) in items.enumerated() {
      let b = makeGlassButton(title: label)
      b.frame = positions[i]
      b.autoresizingMask = [.flexibleLeftMargin, .flexibleTopMargin]
      b.addTarget(self, action: #selector(actionDown(_:)), for: .touchDown)
      b.addTarget(self, action: #selector(actionUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      b.tag = Int(key)
      ctl.addSubview(b)
      actionButtons.append(b)
    }
  }

  /// 肩键 L / R：参考掌机顶部 L/R 造型，做成宽圆角胶囊，置于左右黑边顶部。
  /// 键位映射（与现有动作键注释同属 mkxp-z 默认键表）：
  ///   L = 电脑键盘 A → Input::X(14)
  ///   R = 电脑键盘 S → Input::Y(15)
  private func buildShoulderButtons(in ctl: UIView, root: UIView) {
    let items: [(String, Int32, Bool)] = [
      ("L", 14, false),   // 左肩：靠左
      ("R", 15, true),    // 右肩：靠右
    ]
    let w = root.bounds.width
    let bw: CGFloat = 140, bh: CGFloat = 40
    let top: CGFloat = 34   // 在右上 FPS 角标(顶部)下方，避免与 R 肩键重叠
    for (label, key, right) in items {
      let b = makeShoulderButton(title: label)
      let x = right ? (w - bw - 14) : 14
      b.frame = CGRect(x: x, y: top, width: bw, height: bh)
      b.autoresizingMask = right
        ? [.flexibleLeftMargin, .flexibleBottomMargin]
        : [.flexibleRightMargin, .flexibleBottomMargin]
      b.addTarget(self, action: #selector(actionDown(_:)), for: .touchDown)
      b.addTarget(self, action: #selector(actionUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
      b.tag = Int(key)
      ctl.addSubview(b)
    }
  }

  private func buildMenuButton(in ctl: UIView, root: UIView) {
    // 菜单按钮改放到左侧黑边的竖向中部：上方是 L 肩键(top=34, 底≈74)，
    // 下方是方向圆盘(盘心 cy=h-150, 顶=h-252)，中间一段空闲且远离右上 R 肩键与 FPS，
    // 既不被新肩键遮挡，也便于左手拇指从圆盘上抬时点到。
    let b = makeGlassButton(title: "⋯")
    let h = root.bounds.height
    let dpadTop: CGFloat = h - 150 - 102   // 方向圆盘上沿
    let yTop: CGFloat = 34 + 40 + 8        // L 肩键底 + 间距
    let yBot: CGFloat = dpadTop - 44 - 8   // 方向圆盘上沿 - 按钮高 - 间距
    let y = max(yTop, min(yBot, (yTop + yBot) / 2))
    b.frame = CGRect(x: 16, y: y, width: 44, height: 44)
    b.autoresizingMask = [.flexibleRightMargin, .flexibleBottomMargin]
    b.addTarget(self, action: #selector(menuTap), for: .touchUpInside)
    ctl.addSubview(b)
    menuButton = b
  }

  // MARK: - 交互

  @objc private func actionDown(_ s: UIButton) {
    // 先发键码再给轻触感：输入响应优先于反馈，避免触感调用排在按键前造成可感延迟
    // （与圆盘方向键一致的手感仍保留）。
    MkxpBridge.key(s.tag, down: true)
    actionHaptic.impactOccurred()
    actionHaptic.prepare()
  }
  @objc private func actionUp(_ s: UIButton)   { MkxpBridge.key(s.tag, down: false) }

  /// "⋯"菜单：动作表（收起/显示控件、退出游戏）。
  /// SDL 全屏窗盖住 Flutter 后，这里是用户回库的唯一出口。
  @objc private func menuTap() {
    guard let vc = window?.rootViewController else { return }
    let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
    alert.addAction(UIAlertAction(title: controlsHidden ? "显示控件" : "收起控件",
                                  style: .default) { [weak self] _ in
      self?.toggle()
    })
    alert.addAction(UIAlertAction(title: "退出游戏", style: .destructive) { [weak self] _ in
      self?.exitGame()
    })
    alert.addAction(UIAlertAction(title: "取消", style: .cancel))
    if let pop = alert.popoverPresentationController {
      pop.sourceView = vc.view
      pop.sourceRect = CGRect(x: vc.view.bounds.midX, y: 30, width: 1, height: 1)
    }
    vc.present(alert, animated: true)
  }

  /// 退出游戏：收浮层 → 转回竖屏 → 引擎走 SDL_QUIT 清理（窗口销毁后露出 Flutter）。
  private func exitGame() {
    hide()
    MkxpOrientation.lockLandscape(false)
    MkxpBridge.quit()
  }

  // MARK: - 样式

  private func makeGlassButton(title: String) -> UIButton {
    let b = UIButton(type: .system)
    b.setTitle(title, for: .normal)
    b.setTitleColor(.white, for: .normal)
    b.titleLabel?.font = .systemFont(ofSize: 22, weight: .semibold)
    b.backgroundColor = UIColor(white: 1, alpha: 0.10)
    b.layer.cornerRadius = b.frame.height == 0 ? 36 : min(b.frame.width, b.frame.height) / 2
    b.layer.borderWidth = 1
    b.layer.borderColor = UIColor(white: 1, alpha: 0.25).cgColor
    b.clipsToBounds = true
    return b
  }

  /// 肩键胶囊按钮：半透明玻璃 + 细白描边，圆角=高度一半 → 胶囊形（L/R 造型），
  /// 与动作键同款玻璃拟态，整体视觉一致。
  private func makeShoulderButton(title: String) -> UIButton {
    let b = UIButton(type: .system)
    b.setTitle(title, for: .normal)
    b.setTitleColor(.white, for: .normal)
    b.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
    b.backgroundColor = UIColor(white: 1, alpha: 0.08)
    b.layer.cornerRadius = 20   // == 高度/2 → 胶囊
    b.layer.borderWidth = 1
    b.layer.borderColor = UIColor(white: 1, alpha: 0.22).cgColor
    b.clipsToBounds = true
    return b
  }
}

/// 穿透视图：空白区命中自身时返回 self（【捕获】触摸并转成 SDL 鼠标事件注入引擎），
/// 命中子按钮（方向键/动作键/菜单）时正常返回按钮（走键盘注入）。
/// 原实现返回 nil 让触摸穿透到下层 SDL 窗口，但 SDL 窗口上的 g_softView 会吞掉所有触摸，
/// 导致 RGSS Mouse 模块永远收不到输入——Pokémon Amie 等依赖鼠标的插件在 iOS 上失效。
final class MkxpPassthroughView: UIView {
  private var mouseTouch: UITouch?

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    let spng = UITapGestureRecognizer(target: self, action: #selector(spngTap(_:)))
    spng.numberOfTouchesRequired = 3
    spng.numberOfTapsRequired = 1
    addGestureRecognizer(spng)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let v = super.hitTest(point, with: event)
    return v === self ? self : v
  }

  // MARK: - 空白区触摸 → SDL 鼠标（驱动 RGSS Mouse 模块）
  override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
    if mouseTouch == nil, let touch = t.first { mouseTouch = touch; inject(touch, down: true) }
  }
  override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) {
    if let touch = mouseTouch, t.contains(touch) { inject(touch, down: true) }
  }
  override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
    if let touch = mouseTouch, t.contains(touch) { inject(touch, down: false); mouseTouch = nil }
  }
  override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
    if let touch = mouseTouch, t.contains(touch) { inject(touch, down: false); mouseTouch = nil }
  }

  private func inject(_ touch: UITouch, down: Bool) {
    let p = touch.location(in: self)
    // 归一化到 0..1（浮层即全屏），由 C 侧乘 SDL 窗口尺寸映射到正确坐标，
    // 修正 retina 下 UIKit 点→SDL 像素的偏移，避免小目标(食物格)点不中。
    let nx = Float(p.x / max(self.bounds.width, 1))
    let ny = Float(p.y / max(self.bounds.height, 1))
    mkxp_ios_inject_mouse(nx, ny, Int32(down ? 1 : 0))
  }

  /// 三指轻点：切换 spng 快速路径截屏（原挂在 g_softView，现浮层接管空白区触摸后转挂此处）。
  @objc private func spngTap(_ g: UITapGestureRecognizer) {
    if g.state == .ended { mkxp_ios_toggle_spng() }
  }
}

/// 圆盘方向键：整盘命中，按触摸点相对盘心的角度判 4 向（点哪亮哪），
/// 中心小圆环为死区；换向触发轻触感。同一时刻只保留一个方向，
/// 手指滑动可连续换向、抬起精准释放（旧的多 UIButton 方案会卡键）。
final class MkxpDpadView: UIView {
  private let hub: CGFloat = 26        // 中心死区半径（小圆环内不响应）
  private var held: Set<Int32> = []
  private var heldOrder: [Int32] = []   // 按下顺序（最近按下优先保留）
  /// 本视图上仍活动的触摸（自维护）。不能用 event.allTouches：
  /// 已 ended 的触摸 location 依然有效，计入会把键永远卡在按下
  /// （表现为“最后点的方向一直自动走下去”、选项菜单上下失效）。
  private var activeTouches: Set<UITouch> = []
  private let haptic = UIImpactFeedbackGenerator(style: .light)

  private var wedges: [Int32: CAShapeLayer] = [:]   // 方向 -> 高亮楔形
  private var arrows: [Int32: CAShapeLayer] = [:]   // 方向 -> 箭头三角
  /// 方向 -> 扇区起止角（atan2(dy,dx) 坐标系，y 向下顺时针为正）
  private let sectors: [(key: Int32, a0: CGFloat, a1: CGFloat)] = [
    (8, -3 * .pi / 4, -.pi / 4),       // 上
    (6, -.pi / 4,      .pi / 4),       // 右
    (2,  .pi / 4,  3 * .pi / 4),       // 下
    (4,  3 * .pi / 4,  5 * .pi / 4),   // 左
  ]

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    buildDial()
  }
  required init?(coder: NSCoder) { fatalError() }

  /// 画圆盘：半透明底盘 + 细描边、4 个高亮楔形（默认隐藏）、4 个灰色箭头、
  /// 中心小圆环（死区指示）。样式对齐用户提供的参考图。
  private func buildDial() {
    let c = CGPoint(x: bounds.midX, y: bounds.midY)
    let r = bounds.width / 2

    let disc = CAShapeLayer()
    disc.path = UIBezierPath(ovalIn: CGRect(x: c.x - r + 2, y: c.y - r + 2,
                                            width: r * 2 - 4, height: r * 2 - 4)).cgPath
    disc.fillColor = UIColor(white: 1, alpha: 0.07).cgColor
    disc.strokeColor = UIColor(white: 1, alpha: 0.22).cgColor
    disc.lineWidth = 1.5
    layer.addSublayer(disc)

    for (key, a0, a1) in sectors {
      let w = CAShapeLayer()
      w.path = sectorPath(center: c, radius: r - 5, a0: a0, a1: a1).cgPath
      w.fillColor = UIColor(white: 1, alpha: 0.16).cgColor
      w.opacity = 0
      layer.addSublayer(w)
      wedges[key] = w

      let a = CAShapeLayer()
      a.path = arrowPath(center: c, angle: (a0 + a1) / 2)
      a.fillColor = UIColor(white: 1, alpha: 0.40).cgColor
      layer.addSublayer(a)
      arrows[key] = a
    }

    let ring = CAShapeLayer()
    ring.path = UIBezierPath(ovalIn: CGRect(x: c.x - hub + 3, y: c.y - hub + 3,
                                            width: (hub - 3) * 2, height: (hub - 3) * 2)).cgPath
    ring.fillColor = UIColor(white: 1, alpha: 0.05).cgColor
    ring.strokeColor = UIColor(white: 1, alpha: 0.30).cgColor
    ring.lineWidth = 1.5
    layer.addSublayer(ring)
  }

  private func sectorPath(center c: CGPoint, radius: CGFloat, a0: CGFloat, a1: CGFloat) -> UIBezierPath {
    let p = UIBezierPath()
    p.move(to: c)
    p.addArc(withCenter: c, radius: radius, startAngle: a0, endAngle: a1, clockwise: true)
    p.close()
    return p
  }

  /// 指向 `angle` 方向的三角形（顶点朝外，位于盘心到边缘约 58% 处）
  private func arrowPath(center c: CGPoint, angle: CGFloat) -> CGPath {
    let d = bounds.width * 0.29
    let s: CGFloat = 15
    let dir = CGPoint(x: cos(angle), y: sin(angle))
    let perp = CGPoint(x: -dir.y, y: dir.x)
    let tip = CGPoint(x: c.x + dir.x * (d + s), y: c.y + dir.y * (d + s))
    let b1 = CGPoint(x: c.x + dir.x * (d - s) + perp.x * s * 0.85,
                     y: c.y + dir.y * (d - s) + perp.y * s * 0.85)
    let b2 = CGPoint(x: c.x + dir.x * (d - s) - perp.x * s * 0.85,
                     y: c.y + dir.y * (d - s) - perp.y * s * 0.85)
    let p = UIBezierPath()
    p.move(to: tip)
    p.addLine(to: b1)
    p.addLine(to: b2)
    p.close()
    return p.cgPath
  }

  override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
    haptic.prepare()
    activeTouches.formUnion(t)
    refresh()
  }
  override func touchesMoved(_ t: Set<UITouch>, with e: UIEvent?) { refresh() }
  override func touchesEnded(_ t: Set<UITouch>, with e: UIEvent?) {
    t.forEach { activeTouches.remove($0) }
    refresh()
  }
  override func touchesCancelled(_ t: Set<UITouch>, with e: UIEvent?) {
    t.forEach { activeTouches.remove($0) }
    refresh()
  }

  /// 按当前活动触摸重算方向键状态：同一时刻【只保留一个方向】
  /// （优先保留最近按下的那个），RGSS 4 向移动不需要斜向双键。
  private func refresh() {
    var candidates = Set<Int32>()
    for t in activeTouches {
      if let k = directionKey(at: t.location(in: self)) { candidates.insert(k) }
    }
    heldOrder = heldOrder.filter { candidates.contains($0) }
    for k in candidates.sorted() where !heldOrder.contains(k) {
      heldOrder.append(k)
    }
    var want: Set<Int32> = []
    if let k = heldOrder.last { want.insert(k) }
    for old in held.subtracting(want) { MkxpBridge.key(Int(old), down: false) }
    for k in want.subtracting(held) {
      MkxpBridge.key(Int(k), down: true)
      haptic.impactOccurred()   // 新方向按下：轻触感
    }
    held = want
    updateVisual(dir: heldOrder.last)
  }

  /// 触摸点 -> 方向键码：以盘心为原点按角度四分（点哪亮哪），
  /// 中心 hub（r < hub）与盘外四角（r > 半径）都是死区，避免误触。
  private func directionKey(at p: CGPoint) -> Int32? {
    let dx = p.x - bounds.midX
    let dy = p.y - bounds.midY
    let r = hypot(dx, dy)
    if r < hub || r > bounds.width / 2 - 2 { return nil }
    switch atan2(dy, dx) {
    case ..<(-3 * .pi / 4): return 4    // 左
    case ..<(-.pi / 4):     return 8    // 上
    case ..<( .pi / 4):     return 6    // 右
    case ..<( 3 * .pi / 4): return 2    // 下
    default:                return 4    // 左
    }
  }

  /// 点哪亮哪：按下方向的楔形点亮、箭头变白，其余熄灭；松开全部复位。
  private func updateVisual(dir: Int32?) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(0.08)
    for (k, w) in wedges {
      let on = (k == dir)
      w.opacity = on ? 1 : 0
      arrows[k]?.fillColor = (on ? UIColor.white : UIColor(white: 1, alpha: 0.40)).cgColor
    }
    CATransaction.commit()
  }
}
