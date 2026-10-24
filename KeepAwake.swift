// KeepAwake —— 菜单栏常驻「合盖休眠 / 合盖运行」开关
//
// 菜单栏显示单个 emoji（🌙=合盖休眠 / ☀️=合盖运行），最小宽度，
// 避免在拥挤/有刘海的菜单栏被挤到刘海后面。
// 支持 ⌘ 拖动换位，autosaveName 记住位置（重启后保持在原地）。
//
// 底层（免密，sudoers.d/keepawake 已配置）：
//   开 = pmset -a disablesleep 1
//   关 = pmset -a disablesleep 0 + sleep 10（恢复正常休眠）

import AppKit
import Combine
import SwiftUI

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

    // 免密路径必须直接调 /usr/bin/pmset（与 sudoers 规则逐字匹配）。
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

// MARK: - 原生状态栏项（单 emoji + 位置记忆）

final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let model = KeepAwakeModel.shared
    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // 记住 ⌘ 拖动后的位置，重启后保持
        statusItem.autosaveName = "KeepAwakeStatusItem"
        statusItem.button?.title = model.isOn ? "☀️" : "🌙"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        model.$isOn
            .receive(on: RunLoop.main)
            .sink { [weak self] on in
                guard let self else { return }
                let title = on ? "☀️" : "🌙"
                if self.statusItem.button?.title != title {
                    self.statusItem.button?.title = title
                }
            }
            .store(in: &cancellables)
    }

    // 每次点开菜单时重建内容（状态实时）
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state = NSMenuItem(
            title: model.busy ? "正在切换…" : (model.isOn ? "● 合盖后继续运行" : "○ 合盖后正常休眠"),
            action: nil, keyEquivalent: ""
        )
        state.isEnabled = false
        menu.addItem(state)

        let toggle = NSMenuItem(
            title: model.isOn ? "改为：合盖后正常休眠" : "改为：合盖后继续运行",
            action: #selector(toggleAction), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(.separator())

        let idle = NSMenuItem(
            title: "空闲休眠：\(model.idleSleepText)",
            action: nil, keyEquivalent: ""
        )
        idle.isEnabled = false
        menu.addItem(idle)

        if model.idleSleepText.hasPrefix("永不") {
            let fix = NSMenuItem(
                title: "修复：空闲休眠恢复为 10 分钟",
                action: #selector(fixAction), keyEquivalent: ""
            )
            fix.target = self
            menu.addItem(fix)
        }

        if let error = model.lastError {
            menu.addItem(.separator())
            let errItem = NSMenuItem(title: error, action: nil, keyEquivalent: "")
            errItem.isEnabled = false
            menu.addItem(errItem)
        }

        menu.addItem(.separator())

        let hint = NSMenuItem(
            title: "🌙=合盖休眠（省电）｜☀️=合盖运行（发热耗电）",
            action: nil, keyEquivalent: ""
        )
        hint.isEnabled = false
        menu.addItem(hint)

        let quit = NSMenuItem(title: "退出", action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleAction() { model.toggle() }
    @objc private func fixAction() { model.restoreIdleSleep() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = StatusBarController()
    }
}

@main
struct KeepAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
