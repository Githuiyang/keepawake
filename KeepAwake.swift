// KeepAwake —— 「合盖休眠 / 合盖运行」开关
//
// 三个入口都能切换：
//   1. 菜单栏文字标签（🌙 合盖休眠 / ☀️ 合盖运行）
//   2. Dock 图标（月亮）点击弹出小面板
//   3. 启动时自动弹出面板
//
// 开启：pmset -a disablesleep 1            → 合盖继续运行（发热耗电增加）
// 关闭：pmset -a disablesleep 0 + sleep 10 → 恢复正常休眠
//
// 权限：优先免密 sudo（配置过 sudoers.d/keepawake），失败弹系统密码框。

import AppKit
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

    // 单独修复：把空闲休眠恢复为 10 分钟（针对之前 sleep 0 导致的永不休眠）
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

    // 读取当前 disablesleep（读取不需要 sudo）
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

    // 读取空闲休眠分钟数（sleep 0 = 永不）
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

    // 设置：优先免密 sudo（配置过 sudoers.d/keepawake 时零弹窗），
    // 免密不可用时退回 osascript 弹系统密码框。
    // 注意：免密路径必须直接调 /usr/bin/pmset（与 sudoers 规则逐字匹配），
    // 不能套 sh -c，否则 sudoers 匹配不上。
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

// MARK: - 主面板（Dock 点击 / 启动时弹出）

struct MainView: View {
    @ObservedObject var model: KeepAwakeModel

    var body: some View {
        VStack(spacing: 14) {
            Text(model.isOn ? "☀️ 合盖后继续运行" : "🌙 合盖后正常休眠")
                .font(.title3.weight(.semibold))

            Text(model.isOn
                 ? "合上盖子电脑不会睡。注意发热耗电，用完切回。"
                 : "合上盖子电脑正常休眠，省电。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if model.busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(model.isOn ? "切换为：合盖休眠" : "切换为：合盖运行") {
                    model.toggle()
                }
                .controlSize(.large)
            }

            if model.idleSleepText.hasPrefix("永不") {
                Button("修复：空闲休眠恢复为 10 分钟") {
                    model.restoreIdleSleep()
                }
                .controlSize(.small)
            }

            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(24)
        .frame(width: 340)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = NSImage(
            systemSymbolName: "moon.circle.fill",
            accessibilityDescription: "KeepAwake"
        )

        let controller = NSHostingController(rootView: MainView(model: .shared))
        let newPanel = NSPanel(contentViewController: controller)
        newPanel.title = "合盖开关"
        newPanel.styleMask = [.titled, .closable, .miniaturizable]
        newPanel.isReleasedWhenClosed = false
        newPanel.center()
        newPanel.makeKeyAndOrderFront(nil)
        self.panel = newPanel
        NSApp.activate(ignoringOtherApps: true)
    }

    // Dock 图标被点击时重新打开面板
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            panel?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

@main
struct KeepAwakeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            if KeepAwakeModel.shared.busy {
                Text("正在切换…")
            } else {
                Button(KeepAwakeModel.shared.isOn ? "改为：合盖后正常休眠" : "改为：合盖后继续运行") {
                    KeepAwakeModel.shared.toggle()
                }
            }
            Divider()
            Text(KeepAwakeModel.shared.isOn ? "当前：● 合盖后继续运行" : "当前：○ 合盖后正常休眠")
            Text("空闲休眠：\(KeepAwakeModel.shared.idleSleepText)")
            if KeepAwakeModel.shared.idleSleepText.hasPrefix("永不") {
                Button("修复：空闲休眠恢复为 10 分钟") {
                    KeepAwakeModel.shared.restoreIdleSleep()
                }
            }
            if let error = KeepAwakeModel.shared.lastError {
                Divider()
                Text(error)
            }
            Divider()
            Text("合盖运行会发热耗电，用完记得切回")
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Text(KeepAwakeModel.shared.isOn ? "☀️ 合盖运行" : "🌙 合盖休眠")
        }
        .menuBarExtraStyle(.menu)
    }
}
