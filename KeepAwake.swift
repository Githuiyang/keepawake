// KeepAwake —— 「灵动岛」式合盖开关（哥特祭坛画配色版）
//
// 交互：平时隐形，鼠标移到刘海区域 → 浮现胶囊；点击免密切换；移开淡出。
//
// 设计：意大利哥特艺术配色 ——
//   休眠 = 群青夜（青金石蓝渐变 + 金月 + 闪烁星光）
//   运行 = 朱砂昼（vermilion 渐变 + 金日 + 呼吸脉动）
//   描边金箔、文字象牙白、主词衬线体（祭坛画手稿感）
//
// 底层（免密，sudoers.d/keepawake）：
//   开 = pmset -a disablesleep 1（状态读 IORegistry SleepDisabled）
//   关 = pmset -a disablesleep 0 + sleep 10

import AppKit
import Combine
import SwiftUI

func dbgLog(_ message: String) {
    let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
    let line = "\(stamp)  \(message)\n"
    let path = "/tmp/keepawake_debug.log"
    if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        if let data = line.data(using: .utf8) {
            handle.write(data)
        }
        try? handle.close()
    } else {
        try? line.write(toFile: path, atomically: true, encoding: .utf8)
    }
}

// MARK: - 状态模型

final class KeepAwakeModel: ObservableObject {
    static let shared = KeepAwakeModel()

    @Published var isOn = false
    @Published var idleSleepText = "?"
    @Published var busy = false
    @Published var lastError: String?

    private var timer: Timer?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        dbgLog("Model init: isOn=\(isOn)")
    }

    deinit { timer?.invalidate() }

    func refresh() {
        isOn = Self.readDisablesSleep()
        idleSleepText = Self.readIdleSleep()
    }

    func toggle() {
        guard !busy else { return }
        busy = true
        let target = !isOn
        dbgLog("toggle → \(target)")
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.setDisablesSleep(target)
            DispatchQueue.main.async {
                self.busy = false
                if ok {
                    self.lastError = nil
                    self.refresh()
                } else {
                    self.lastError = "设置失败：可能取消了管理员密码输入"
                }
                dbgLog("toggle done ok=\(ok) isOn=\(self.isOn)")
            }
        }
    }

    func restoreIdleSleep() {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.runPasswordless(["/usr/bin/pmset", "-a", "sleep", "10"])
                || Self.runAdminShell("pmset -a sleep 10")
            DispatchQueue.main.async {
                self.busy = false
                if ok {
                    self.lastError = nil
                } else {
                    self.lastError = "修复失败：可能取消了管理员密码输入"
                }
                self.refresh()
            }
        }
    }

    // 读取合盖休眠开关状态。
    // macOS 26 的 pmset -g/-g custom 不再显示 disablesleep 字段，
    // 改读 IORegistry 内核真值：IOPMrootDomain 的 SleepDisabled 属性（无需 sudo）。
    // 注意：ioreg -l 输出约 1.8MB 且含非 UTF-8 二进制字节，直接整包解码会失败，
    // 必须经 grep 字节级过滤后只取匹配行（纯 ASCII）再判断。
    static func readDisablesSleep() -> Bool {
        let output = runAndCapture("/bin/sh", ["-c",
            "/usr/sbin/ioreg -c IOPMrootDomain -l | /usr/bin/grep 'SleepDisabled' || true"])
        return output.contains("= Yes")
    }

    static func readIdleSleep() -> String {
        let output = runAndCapture("/usr/bin/pmset", ["-g", "custom"])
        var first = true
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("sleep ") && first {
                first = false
                let value = line.replacingOccurrences(of: "sleep", with: "").trimmingCharacters(in: .whitespaces)
                if value == "0" { return "永不（耗电根源）" }
                return "\(value) 分钟"
            }
        }
        return "?"
    }

    static func setDisablesSleep(_ on: Bool) -> Bool {
        if on {
            if runPasswordless(["/usr/bin/pmset", "-a", "disablesleep", "1"]) {
                return true
            }
            return runAdminShell("pmset -a disablesleep 1")
        } else {
            let ok1 = runPasswordless(["/usr/bin/pmset", "-a", "disablesleep", "0"])
            let ok2 = runPasswordless(["/usr/bin/pmset", "-a", "sleep", "10"])
            if ok1 && ok2 {
                return true
            }
            return runAdminShell("pmset -a disablesleep 0; pmset -a sleep 10")
        }
    }

    static func runPasswordless(_ args: [String]) -> Bool {
        runAndCheck("/usr/bin/sudo", ["-n"] + args)
    }

    static func runAdminShell(_ cmd: String) -> Bool {
        if runAndCheck("/usr/bin/sudo", ["-n", "sh", "-c", cmd]) {
            return true
        }
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        return runAndCheck("/usr/bin/osascript", ["-e", script])
    }

    @discardableResult
    private static func runAndCapture(_ path: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func runAndCheck(_ path: String, _ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

// MARK: - 灵动岛显隐状态（供胶囊做进出场动画）

final class IslandViewModel: ObservableObject {
    @Published var visible = false
    @Published var hovered = false
}

// MARK: - 哥特配色

private enum GothicPalette {
    static let gold = Color(red: 0.90, green: 0.76, blue: 0.42)        // 金箔
    static let goldLight = Color(red: 0.96, green: 0.87, blue: 0.62)   // 亮金
    static let ivory = Color(red: 0.95, green: 0.91, blue: 0.84)       // 象牙白
    // 群青夜（青金石 → 午夜）
    static let nightTop = Color(red: 0.18, green: 0.20, blue: 0.40)
    static let nightBottom = Color(red: 0.05, green: 0.06, blue: 0.18)
    // 朱砂昼（vermilion → 深绯）
    static let fireTop = Color(red: 0.70, green: 0.16, blue: 0.10)
    static let fireBottom = Color(red: 0.33, green: 0.05, blue: 0.04)
}

// MARK: - 图标（带自主动画）

private struct MoonIcon: View {
    var body: some View {
        Image(systemName: "moon.stars.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(GothicPalette.gold)
            .rotationEffect(.degrees(-14))
    }
}

private struct SunIcon: View {
    @State private var breathing = false
    var body: some View {
        Image(systemName: "sun.max.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(GothicPalette.gold)
            .scaleEffect(breathing ? 1.12 : 0.94)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

private struct TwinkleStar: View {
    let delay: Double
    @State private var lit = false
    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 6))
            .foregroundStyle(GothicPalette.goldLight.opacity(0.9))
            .opacity(lit ? 0.95 : 0.20)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true).delay(delay)) {
                    lit = true
                }
            }
    }
}

// MARK: - 胶囊视图

struct PillView: View {
    @ObservedObject var model: KeepAwakeModel
    @ObservedObject var island: IslandViewModel

    var body: some View {
        let isNight = !model.isOn

        HStack(spacing: 10) {
            // 图标：月/日 切换时缩放淡入
            ZStack {
                if isNight {
                    MoonIcon()
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                } else {
                    SunIcon()
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: model.isOn)

            // 主词（衬线体，手稿感）
            VStack(alignment: .leading, spacing: 1) {
                Text(model.busy ? "正在切换…" : (isNight ? "合盖休眠" : "合盖运行中"))
                    .font(.system(size: 12.5, weight: .semibold, design: .serif))
                    .foregroundStyle(GothicPalette.ivory)
                Text(isNight ? "轻点切换 · 合盖继续运行" : "轻点切回 · 恢复正常休眠")
                    .font(.system(size: 9))
                    .foregroundStyle(GothicPalette.ivory.opacity(0.62))
            }

            if isNight && !model.busy {
                HStack(spacing: 5) {
                    TwinkleStar(delay: 0.0)
                    TwinkleStar(delay: 0.5)
                    TwinkleStar(delay: 1.0)
                }
                .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 背景渐变：群青夜 / 朱砂昼，切换时 0.5s 交叉过渡
        .background(
            ZStack {
                Capsule().fill(
                    LinearGradient(
                        colors: isNight
                            ? [GothicPalette.nightTop, GothicPalette.nightBottom]
                            : [GothicPalette.fireTop, GothicPalette.fireBottom],
                        startPoint: .top, endPoint: .bottom)
                )
                // 顶部微光（祭坛金箔的高光感）
                Capsule().fill(
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear],
                        startPoint: .top, endPoint: .center)
                )
            }
            .animation(.easeInOut(duration: 0.5), value: model.isOn)
        )
        // 金箔描边
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(
                    colors: [GothicPalette.goldLight, GothicPalette.gold, GothicPalette.gold.opacity(0.5)],
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 1
            )
        )
        // 投影：黑影 + 金晕
        .shadow(color: .black.opacity(0.38), radius: 7, y: 2)
        .shadow(color: GothicPalette.gold.opacity(isNight ? 0.22 : 0.38), radius: 8)
        .contentShape(Rectangle())
        // 进出场：缩放 + 位移 + 模糊渐显（有质感的弹簧）
        .scaleEffect(island.visible ? (island.hovered ? 1.045 : 1.0) : 0.82)
        .offset(y: island.visible ? 0 : -5)
        .blur(radius: island.visible ? 0 : 2.2)
        .animation(.spring(response: 0.42, dampingFraction: 0.76), value: island.visible)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: island.hovered)
        .onHover { island.hovered = $0 }
        .onTapGesture { model.toggle() }
    }
}

// 承载 SwiftUI 的 NSHostingView，仅用于右键菜单
final class PillHostingView<Content: View>: NSHostingView<Content> {
    var onRightClick: (() -> Void)?

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

// MARK: - 灵动岛控制器

final class DynamicIslandController: NSObject {
    private var panel: NSPanel!
    private let model = KeepAwakeModel.shared
    private let islandVM = IslandViewModel()
    private var pollTimer: Timer?
    private var visible = false
    private var flashUntil = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    // 悬停感应区：刘海及其正下方
    private var revealRect: NSRect {
        guard let screen = NSScreen.main else { return .zero }
        let w: CGFloat = 280
        let h: CGFloat = 50
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w, height: h)
    }

    func install() {
        guard let screen = NSScreen.main else { return }
        let width: CGFloat = 268
        let height: CGFloat = 30
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - 24 - height,  // 紧贴菜单栏下沿 = 刘海正下方
                           width: width, height: height)

        let hosting = PillHostingView(rootView: PillView(model: model, island: islandVM))
        hosting.onRightClick = { [weak self] in self?.showMenu() }

        panel = NSPanel(contentRect: frame,
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()

        // 状态变化时闪现反馈
        model.$isOn
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { [weak self] _ in self?.flash() }
            .store(in: &cancellables)

        // 轮询鼠标位置决定显隐（隐形时窗口穿透，不挡任何操作）
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.updateVisibility()
        }
        dbgLog("DynamicIsland: 面板已创建 frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.width))x\(Int(frame.height))，感应区=\(revealRect)")
    }

    private func flash() {
        flashUntil = Date().addingTimeInterval(1.8)
        updateVisibility()
    }

    private func updateVisibility() {
        let mouse = NSEvent.mouseLocation
        let inside = revealRect.contains(mouse)
        let shouldShow = inside || Date() < flashUntil
        setVisible(shouldShow)
    }

    private func setVisible(_ show: Bool) {
        guard show != visible else { return }
        visible = show
        panel.ignoresMouseEvents = !show
        islandVM.visible = show
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = show ? 1 : 0
        })
    }

    private func showMenu() {
        let menu = NSMenu()

        let state = NSMenuItem(
            title: model.busy ? "正在切换…" : (model.isOn ? "● 合盖后继续运行" : "○ 合盖后正常休眠"),
            action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)

        let toggle = NSMenuItem(
            title: model.isOn ? "改为：合盖后正常休眠" : "改为：合盖后继续运行",
            action: #selector(menuToggle), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let idle = NSMenuItem(title: "空闲休眠：\(model.idleSleepText)", action: nil, keyEquivalent: "")
        idle.isEnabled = false
        menu.addItem(idle)

        if model.idleSleepText.hasPrefix("永不") {
            let fix = NSMenuItem(title: "修复：空闲休眠恢复为 10 分钟",
                                 action: #selector(menuFix), keyEquivalent: "")
            fix.target = self
            menu.addItem(fix)
        }

        if let error = model.lastError {
            menu.addItem(.separator())
            let err = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            err.isEnabled = false
            menu.addItem(err)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        let location = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        menu.popUp(positioning: nil, at: location, in: panel.contentView)
    }

    @objc private func menuToggle() { model.toggle() }
    @objc private func menuFix() { model.restoreIdleSleep() }
    @objc private func menuQuit() { NSApp.terminate(nil) }
}

// MARK: - 纯 AppKit 入口

@main
enum KeepAwakeMain {
    static func main() {
        dbgLog("=== KeepAwake 启动（哥特配色灵动岛）===")
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DynamicIslandController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dbgLog("applicationDidFinishLaunching 触发")
        let island = DynamicIslandController()
        island.install()
        controller = island
    }
}
