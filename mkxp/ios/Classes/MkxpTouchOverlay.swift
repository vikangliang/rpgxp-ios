import UIKit

/// 原生触摸控制浮层（M2 阶段二）。
///
/// 游戏运行时 SDL 自建全屏窗口盖在 Flutter 之上并吞掉触摸，因此虚拟控制键必须是一个
/// 位于 SDL 窗口之上的原生 UIWindow，按钮直调 `MkxpBridge.key`（不依赖 Flutter 主线程）。
/// 根视图 `isUserInteractionEnabled = false`，让游戏区的触摸穿透到下层 SDL 窗口；
/// 只有摇杆与动作键子视图接收触摸。
///
/// 键位映射（Essentials 默认，可在设置重映射）：
///   方向：Up=8 / Down=2 / Left=4 / Right=6（Input::ButtonCode）
///   动作：C 确定=13 / ✕ 取消=12 / Z 特殊=16 / ☰ 菜单=14
final class MkxpTouchOverlay {
  static let shared = MkxpTouchOverlay()

  /// RGSS 键码（Input::ButtonCode），与 scripts/mkxp-framework/mkxp_framework.cpp 注释一致。
  private let KEY_UP: Int32 = 8, KEY_DOWN: Int32 = 2, KEY_LEFT: Int32 = 4, KEY_RIGHT: Int32 = 6

  private var window: UIWindow?
  private var controlsView: UIView?
  private var joystick: MkxpJoystickView?
  private var actionButtons: [UIButton] = []
  private var menuButton: UIButton?
  private var controlsHidden = false

  // MARK: - 生命周期

  /// 引擎启动后调用：创建并展示浮层（幂等）。
  func show() {
    if let win = window {
      win.isHidden = false
      return
    }
    let scene = (UIApplication.shared.connectedScenes
      .first { $0.activationState == .foregroundActive } as? UIWindowScene)
    let win = UIWindow(windowScene: scene ?? UIApplication.shared.windows.first?.windowScene
                       ?? UIWindowScene(session: UISceneSession(role: .windowApplication), connectionOptions: UIScene.ConnectionOptions()))
    win.windowLevel = .alert + 2   // 高于 SDL 与 Flutter 窗口
    let vc = UIViewController()
    vc.view.backgroundColor = .clear
    win.rootViewController = vc

    let root = vc.view!
    root.isUserInteractionEnabled = false   // 游戏区触摸穿透到下层 SDL 窗口
    let ctl = UIView(frame: root.bounds)
    ctl.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    ctl.isUserInteractionEnabled = true
    root.addSubview(ctl)
    controlsView = ctl

    buildJoystick(in: ctl, root: root)
    buildActionButtons(in: ctl, root: root)
    buildMenuButton(in: ctl, root: root)

    window = win
    win.isHidden = false
    win.makeKeyAndVisible()
  }

  func hide() { window?.isHidden = true }

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

  private func buildJoystick(in ctl: UIView, root: UIView) {
    let size: CGFloat = 168
    let joy = MkxpJoystickView(frame: CGRect(
      x: 22, y: root.bounds.height - size - 28, width: size, height: size))
    joy.autoresizingMask = [.flexibleTopMargin, .flexibleRightMargin]
    joy.onDirectionChange = { [weak self] dir in
      self?.applyDirection(dir)
    }
    ctl.addSubview(joy)
    joystick = joy
  }

  private func buildActionButtons(in ctl: UIView, root: UIView) {
    // (label, RGSS key) —— Essentials 默认
    let items: [(String, Int32)] = [
      ("C", 13), ("✕", 12),
      ("Z", 16), ("☰", 14),
    ]
    let d: CGFloat = 72, gap: CGFloat = 14
    let block = d * 2 + gap
    let x0 = root.bounds.width - block - 22
    let y0 = root.bounds.height - block - 36
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
    b.frame = CGRect(x: root.bounds.width - 56, y: 28, width: 44, height: 44)
    b.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
    b.addTarget(self, action: #selector(menuTap), for: .touchUpInside)
    ctl.addSubview(b)
    menuButton = b
  }

  // MARK: - 交互

  private var currentDir: String = ""
  private func applyDirection(_ dir: String) {
    if dir == currentDir { return }
    if !currentDir.isEmpty { MkxpBridge.key(keyFor(currentDir), down: false) }
    currentDir = dir
    if !currentDir.isEmpty { MkxpBridge.key(keyFor(currentDir), down: true) }
  }
  private func keyFor(_ dir: String) -> Int32 {
    switch dir {
    case "up": return KEY_UP
    case "down": return KEY_DOWN
    case "left": return KEY_LEFT
    default: return KEY_RIGHT
    }
  }

  @objc private func actionDown(_ s: UIButton) { MkxpBridge.key(Int32(s.tag), down: true) }
  @objc private func actionUp(_ s: UIButton)   { MkxpBridge.key(Int32(s.tag), down: false) }

  @objc private func menuTap() { toggle() }

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

/// 圆环方向摇杆：半透明深色圆环 + 中心圆点，拖动算 8 向、取主方向（4 向主导）。
final class MkxpJoystickView: UIView {
  var onDirectionChange: ((String) -> Void)?

  private let ring = CAShapeLayer()
  private let knob = UIView()
  private var centerPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
  private let deadZone: CGFloat = 18

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = true

    ring.fillColor = UIColor(white: 1, alpha: 0.06).cgColor
    ring.strokeColor = UIColor(white: 1, alpha: 0.18).cgColor
    ring.lineWidth = 2
    layer.addSublayer(ring)

    knob.backgroundColor = UIColor(white: 1, alpha: 0.22)
    knob.layer.cornerRadius = 26
    knob.frame = CGRect(x: 0, y: 0, width: 52, height: 52)
    knob.center = centerPoint
    addSubview(knob)

    let pan = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
    addGestureRecognizer(pan)
  }
  required init?(coder: NSCoder) { fatalError() }

  override func layoutSubviews() {
    super.layoutSubviews()
    let r = min(bounds.width, bounds.height) / 2 - 6
    ring.path = UIBezierPath(ovalIn: CGRect(x: bounds.midX - r, y: bounds.midY - r,
                                            width: r * 2, height: r * 2)).cgPath
    knob.center = centerPoint
  }

  @objc private func pan(_ g: UIPanGestureRecognizer) {
    let p = g.location(in: self)
    var off = CGPoint(x: p.x - centerPoint.x, y: p.y - centerPoint.y)
    let dist = hypot(off.x, off.y)
    let maxR = min(bounds.width, bounds.height) / 2 - knob.frame.width / 2
    if dist > maxR { off = CGPoint(x: off.x / dist * maxR, y: off.y / dist * maxR) }
    knob.center = CGPoint(x: centerPoint.x + off.x, y: centerPoint.y + off.y)

    if g.state == .ended || g.state == .cancelled {
      knob.center = centerPoint
      onDirectionChange?("")
      return
    }
    if dist < deadZone {
      onDirectionChange?("")
      return
    }
    // 取主方向（轴投影更大的方向）
    let dir: String
    if abs(off.x) > abs(off.y) {
      dir = off.x > 0 ? "right" : "left"
    } else {
      dir = off.y > 0 ? "down" : "up"   // 屏幕 y 向下 = Down
    }
    onDirectionChange?(dir)
  }
}
