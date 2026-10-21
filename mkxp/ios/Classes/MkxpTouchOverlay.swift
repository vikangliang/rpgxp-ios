import UIKit

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
final class MkxpTouchOverlay: NSObject {
  static let shared = MkxpTouchOverlay()

  /// RGSS 键码（Input::ButtonCode），与 scripts/mkxp-framework/mkxp_framework.cpp 注释一致。
  private let KEY_UP: Int32 = 8, KEY_DOWN: Int32 = 2, KEY_LEFT: Int32 = 4, KEY_RIGHT: Int32 = 6

  private var window: UIWindow?
  private var controlsView: UIView?
  private var actionButtons: [UIButton] = []
  private var menuButton: UIButton?
  private var controlsHidden = false

  /// 启动加载 HUD：必须画在 SDL 引擎窗口（level 1999）【之上】——引擎窗口
  /// 创建后立刻以纯黑盖住 Flutter，Flutter 侧的加载提示根本看不见。
  private var loadingWindow: UIWindow?
  private var loadingTimer: Timer?

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

  // MARK: - 生命周期

  /// 引擎启动后调用：创建并展示浮层（幂等）。
  func show() {
    if let win = window {
      win.isHidden = false
      return
    }
    let scene = (UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene)
      ?? (UIApplication.shared.connectedScenes.first as? UIWindowScene)
      ?? UIApplication.shared.windows.first?.windowScene
    guard let scene else { return }   // 无可用 scene（极少见）：下次 show() 重试
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
    buildMenuButton(in: ctl, root: root)

    window = win
    win.isHidden = false
    win.makeKeyAndVisible()
  }

  func hide() {
    window?.isHidden = true
    hideLoading()
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

  /// 十字方向区：单一触摸追踪视图（覆盖整个十字外接范围）。
  /// 之前 4 个独立 UIButton 的缺陷：按住后手指滑出按钮不会触发 touchUp，
  /// 原方向键一直卡在“按下”→ 表现为“偶尔失灵”。单视图追踪可随手滑换向、
  /// 也天然支持斜向双键（如右+上）。
  private func buildDpad(in ctl: UIView) {
    let side: CGFloat = 204      // 十字外接边长（4 臂 + 中心 hub + 边距）
    let cx: CGFloat = 104        // 十字中心 x（左侧偏下，少挡画面）
    let h = max(ctl.bounds.height, UIScreen.main.bounds.height)
    let cy = h - 150             // 十字中心 y
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
    let w = max(root.bounds.width, UIScreen.main.bounds.width)
    let h = max(root.bounds.height, UIScreen.main.bounds.height)
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

  private func buildMenuButton(in ctl: UIView, root: UIView) {
    let b = makeGlassButton(title: "⋯")
    let w = max(root.bounds.width, UIScreen.main.bounds.width)
    b.frame = CGRect(x: w - 56, y: 28, width: 44, height: 44)
    b.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
    b.addTarget(self, action: #selector(menuTap), for: .touchUpInside)
    ctl.addSubview(b)
    menuButton = b
  }

  // MARK: - 交互

  @objc private func actionDown(_ s: UIButton) { MkxpBridge.key(s.tag, down: true) }
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
}

/// 穿透视图：命中自身（即空白区域）时返回 nil，让触摸落到下层 SDL 窗口；
/// 命中子按钮（方向键/动作键）时正常返回按钮。解决“按钮收不到触摸”。
final class MkxpPassthroughView: UIView {
  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    let v = super.hitTest(point, with: event)
    return v === self ? nil : v
  }
}

/// 十字方向键：单视图追踪全部触摸，按位置判定 4 向（上/下/左/右）。
/// 设计目标：消除“误触”。命中区是【真正的十字】——中心 hub + 4 条臂，
/// 臂外的 4 个角落与中心 hub 都是死区；同一时刻只认一条臂（取最近按下），
/// 因此不会斜向合成双键、也不会点到相邻方向。手指可在臂间滑动自动换方向、
/// 抬起精准释放（旧的多 UIButton 方案会卡键）。
final class MkxpDpadView: UIView {
  private let armW: CGFloat = 64      // 每条臂宽度
  private let armLen: CGFloat = 64    // 臂长（中心到臂尖）
  private let hub: CGFloat = 30       // 中心死区半径（十字中心不响应）
  private var held: Set<Int32> = []
  private var heldOrder: [Int32] = []   // 按下顺序（最近按下优先保留）
  /// 本视图上仍活动的触摸（自维护）。不能用 event.allTouches：
  /// 已 ended 的触摸 location 依然有效，计入会把键永远卡在按下
  /// （表现为“最后点的方向一直自动走下去”、选项菜单上下失效）。
  private var activeTouches: Set<UITouch> = []

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isMultipleTouchEnabled = true
    drawCross()
  }
  required init?(coder: NSCoder) { fatalError() }

  /// 画“十字”：中心 hub（圆，半透明）+ 4 条臂（圆角矩形，含 ▲▼◀▶）。
  /// 臂与 hub 之间留 8pt 缝，视觉上清楚分隔每个方向，配合死区彻底防误触。
  private func drawCross() {
    let cx = bounds.midX, cy = bounds.midY
    let hubView = makePad(w: hub * 2, h: hub * 2, rounded: hub, alpha: 0.06)
    hubView.center = CGPoint(x: cx, y: cy)
    addSubview(hubView)
    let off = hub + 8 + armLen / 2   // 臂中心：hub 边缘外侧再留 8pt 缝
    let arms: [(CGPoint, String)] = [
      (CGPoint(x: 0, y: -off), "▲"),
      (CGPoint(x: 0, y:  off), "▼"),
      (CGPoint(x: -off, y: 0), "◀"),
      (CGPoint(x:  off, y: 0), "▶"),
    ]
    for (p, arrow) in arms {
      let v = makePad(w: armW, h: armLen, rounded: 14, alpha: 0.12)
      v.center = CGPoint(x: cx + p.x, y: cy + p.y)
      let lb = UILabel(frame: v.bounds)
      lb.text = arrow
      lb.textColor = .white
      lb.font = .systemFont(ofSize: 20, weight: .bold)
      lb.textAlignment = .center
      lb.isUserInteractionEnabled = false
      v.addSubview(lb)
      addSubview(v)
    }
  }

  private func makePad(w: CGFloat, h: CGFloat, rounded: CGFloat, alpha: CGFloat) -> UIView {
    let v = UIView(frame: CGRect(x: 0, y: 0, width: w, height: h))
    v.backgroundColor = UIColor(white: 1, alpha: alpha)
    v.layer.cornerRadius = rounded
    v.layer.borderWidth = 1
    v.layer.borderColor = UIColor(white: 1, alpha: 0.22).cgColor
    v.isUserInteractionEnabled = false
    return v
  }

  override func touchesBegan(_ t: Set<UITouch>, with e: UIEvent?) {
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
      candidates.formUnion(keysFor(point: t.location(in: self)))
    }
    heldOrder = heldOrder.filter { candidates.contains($0) }
    for k in candidates.sorted() where !heldOrder.contains(k) {
      heldOrder.append(k)
    }
    var want: Set<Int32> = []
    if let k = heldOrder.last { want.insert(k) }
    for old in held.subtracting(want) { MkxpBridge.key(Int(old), down: false) }
    for k in want.subtracting(held) { MkxpBridge.key(Int(k), down: true) }
    held = want
  }

  /// 位置 → 方向键码（十字命中）：
  /// - 中心 hub（|dx|<hub 且 |dy|<hub）→ 不响应；
  /// - 竖向臂（|dx|<=armW/2 且 |dy|>=hub）→ 上/下；
  /// - 横向臂（|dy|<=armW/2 且 |dx|>=hub）→ 左/右；
  /// - 其余（臂外 4 角）→ 不响应，避免误触相邻方向。
  private func keysFor(point p: CGPoint) -> Set<Int32> {
    let dx = p.x - bounds.midX
    let dy = p.y - bounds.midY
    if abs(dx) < hub && abs(dy) < hub { return [] }
    if abs(dx) <= armW / 2 && abs(dy) >= hub { return [dy < 0 ? 8 : 2] }   // 上=8 下=2
    if abs(dy) <= armW / 2 && abs(dx) >= hub { return [dx < 0 ? 4 : 6] }   // 左=4 右=6
    return []
  }
}
