// KeepAwake —— 「灵动岛」式合盖开关
//
// 平时完全隐形。鼠标移到屏幕顶部中央（刘海区域）时，
// 刘海正下方浮现深色胶囊：🌙 合盖休眠 / ☀️ 合盖运行，点击切换，移开淡出。
//
// 实现要点：
// - 悬浮 NSPanel（borderless + nonactivating），窗口常驻但 alpha=0、
//   ignoresMouseEvents=true → 隐形时零拦截，不挡任何点击
// - 0.25s 轮询 NSEvent.mouseLocation 判断是否进入刘海感应区，
//   进入→显示并开启鼠标事件；离开→淡出并恢复穿透
// - 状态切换后胶囊自动闪现 1.6 秒给反馈（无需悬停）
// - 右键胶囊：修复空闲休眠 / 退出
// - 不再创建菜单栏状态项（用户要求平时隐藏）
//
// 免密（sudoers.d/keepawake 已配置）：
//   开 = pmset -a disablesleep 1
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

    static func readDisablesSleep() -> Bool {
        let output = runAndCapture("/usr/bin/pmset", ["-g", "custom"])
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("disablesleep") {
                return line.hasSuffix("1")
            }
        }
        return false
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

// MARK: - 胶囊视图（刘海下方的深色小岛）

struct PillView: View {
    @ObservedObject var model: KeepAwakeModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.isOn ? "sun.max.fill" : "moon.fill")
                .imageScale(.small)
            if model.busy {
                Text("正在切换…").font(.system(size: 12, weight: .medium))
            } else {
                Text(model.isOn ? "合盖运行中 · 点击切回休眠" : "合盖休眠 · 点击切换运行")
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .contentShape(Rectangle())
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
    private var pollTimer: Timer?
    private var visible = false
    private var flashUntil = Date.distantPast
    private var cancellables = Set<AnyCancellable>()

    // 悬停感应区：刘海及其正下方（宽 280 × 高 50，横跨顶部中央）
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
        let width: CGFloat = 260
        let height: CGFloat = 28
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - 24 - height,  // 紧贴菜单栏下沿 = 刘海正下方
                           width: width, height: height)

        let hosting = PillHostingView(rootView: PillView(model: model))
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
        flashUntil = Date().addingTimeInterval(1.6)
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
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
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
        dbgLog("=== KeepAwake 启动（灵动岛模式）===")
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
