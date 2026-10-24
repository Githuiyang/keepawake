// KeepAwake —— 菜单栏常驻「合盖休眠 / 合盖运行」开关
//
// 只在顶部菜单栏显示文字标签（无 Dock 图标、无弹窗）：
//   🌙 合盖休眠（默认，省电） / ☀️ 合盖运行（合盖继续跑）
// 点击标签即可切换，免密（sudoers.d/keepawake 已配置）。
//
// 底层：
//   开 = pmset -a disablesleep 1
//   关 = pmset -a disablesleep 0 + sleep 10（恢复正常休眠）

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

@main
struct KeepAwakeApp: App {
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
            // 文字标签 + 彩色 emoji，避免小图标被刘海或拥挤的菜单栏挤掉
            Text(KeepAwakeModel.shared.isOn ? "☀️ 合盖运行" : "🌙 合盖休眠")
        }
        .menuBarExtraStyle(.menu)
    }
}
