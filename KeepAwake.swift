// KeepAwake —— 「灵动岛」式合盖开关（Anthropic 风格暗色控制台）
//
// 交互：平时隐形，鼠标移到刘海区域 → 浮现控制台卡片；点击免密切换；移开淡出；右键菜单。
//
// 视觉：Anthropic/Claude 终端控制台语言 ——
//   暖调深灰半透明圆角卡片、细边框、柔和阴影；
//   米白衬线标题 + mono 信息行；品牌橙 #D97757 只做点睛
//   （运行态状态点/ON 徽标/边框微染），微弱辉光不霓虹。
//   休眠 = 一切归于暖灰安静；运行 = 橙色点亮。
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

// MARK: - 灵动岛显隐状态（供卡片做进出场动画）

final class IslandViewModel: ObservableObject {
    @Published var visible = false
    @Published var hovered = false
}

// MARK: - Anthropic 风格暗色控制台配色

private enum ConsolePalette {
    static let cream = Color(red: 0.98, green: 0.97, blue: 0.95)   // 米白（Anthropic ivory）
    static let warmGray = Color(red: 0.66, green: 0.64, blue: 0.61) // 低饱和暖灰
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)   // 品牌橙 #D97757
    static let cardBG = Color(red: 0.15, green: 0.15, blue: 0.14)   // 暖调深灰（非纯黑）
    static let hairline = Color.white.opacity(0.09)                  // 细边框
    static let dotDim = Color(red: 0.42, green: 0.41, blue: 0.39)    // 休眠态状态点
}

// 运行态的呼吸状态点（微弱橙色辉光，不霓虹）
private struct StatusDot: View {
    let isOn: Bool
    @State private var breathing = false
    var body: some View {
        Circle()
            .fill(isOn ? ConsolePalette.accent : ConsolePalette.dotDim)
            .frame(width: 7, height: 7)
            .shadow(color: isOn ? ConsolePalette.accent.opacity(breathing ? 0.55 : 0.25) : .clear,
                    radius: isOn ? 5 : 0)
            .onAppear {
                guard isOn else { return }
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
    }
}

// MARK: - 控制台卡片

struct PillView: View {
    @ObservedObject var model: KeepAwakeModel
    @ObservedObject var island: IslandViewModel

    var body: some View {
        let isOn = model.isOn

        HStack(spacing: 12) {
            StatusDot(isOn: isOn)
                .animation(.easeInOut(duration: 0.4), value: isOn)

            VStack(alignment: .leading, spacing: 2) {
                // 衬线大标题（安静、克制）
                Text(model.busy ? "切换中…" : (isOn ? "合盖运行中" : "合盖休眠"))
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(ConsolePalette.cream)
                // mono 信息行：命令语义 + 关键字用橙色点睛
                HStack(spacing: 0) {
                    Text("pmset disablesleep ")
                        .foregroundStyle(ConsolePalette.warmGray)
                    Text(isOn ? "on" : "off")
                        .foregroundStyle(isOn ? ConsolePalette.accent : ConsolePalette.warmGray)
                    Text("  ·  ")
                        .foregroundStyle(ConsolePalette.warmGray.opacity(0.6))
                    Text(isOn ? "lid close keeps running" : "click to keep running")
                        .foregroundStyle(ConsolePalette.warmGray)
                }
                .font(.system(size: 8.5, weight: .regular, design: .monospaced))
            }

            Spacer(minLength: 8)

            // 大号 mono 徽标（视觉锚点，ON 橙 / OFF 暖灰）
            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(isOn ? ConsolePalette.accent : ConsolePalette.warmGray.opacity(0.7))
                .opacity(model.busy ? 0.4 : 1)
                .animation(.easeInOut(duration: 0.35), value: isOn)
        }
        .padding(.horizontal, 15)
        .frame(width: 300, height: 44)
        // 半透明暖灰圆角卡片 + 细边框（运行态边框微染橙色）
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ConsolePalette.cardBG.opacity(isOn ? 0.92 : 0.86))
                .animation(.easeInOut(duration: 0.4), value: isOn)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOn ? ConsolePalette.accent.opacity(0.28) : ConsolePalette.hairline,
                              lineWidth: 1)
                .animation(.easeInOut(duration: 0.4), value: isOn)
        )
        // 柔和阴影 + 运行态微弱橙晕
        .shadow(color: .black.opacity(0.40), radius: 10, y: 3)
        .shadow(color: ConsolePalette.accent.opacity(isOn ? 0.18 : 0), radius: 9)
        // 进出场：弹簧缩放 + 上浮 + 模糊渐显
        .scaleEffect(island.visible ? (island.hovered ? 1.03 : 1.0) : 0.86)
        .offset(y: island.visible ? 0 : -5)
        .blur(radius: island.visible ? 0 : 2.0)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: island.visible)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: island.hovered)
        // 居中于面板全域；悬停/点击覆盖整卡
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
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
        let w: CGFloat = 320
        let h: CGFloat = 55
        return NSRect(x: screen.frame.midX - w / 2,
                      y: screen.frame.maxY - h,
                      width: w, height: h)
    }

    func install() {
        guard let screen = NSScreen.main else { return }
        // 面板比卡片大一圈：卡片 300x44，面板 352x60，
        // 余量留给悬停放大(1.03x)、阴影和橙晕，防止边缘被窗口裁剪
        let width: CGFloat = 352
        let height: CGFloat = 60
        let frame = NSRect(x: screen.frame.midX - width / 2,
                           y: screen.frame.maxY - 24 - height,  // 紧贴菜单栏下沿 = 刘海正下方
                           width: width, height: height)

        let hosting = PillHostingView(rootView: PillView(model: model, island: islandVM))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
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
        dbgLog("=== KeepAwake 启动（Anthropic 控制台风）===")
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
