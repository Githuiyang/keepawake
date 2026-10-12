// KeepAwake —— 菜单栏「合盖不休眠」开关
//
// 开启：pmset -a disablesleep 1  → 合上盖子机器继续运行（发热、耗电增加）
// 关闭：pmset -a disablesleep 0 + sleep 10 → 恢复正常休眠（修复之前 sleep 0 导致的永不休眠）
//
// 权限：修改 pmset 需要 root。优先尝试免密 sudo（若配置过 sudoers.d/keepawake），
// 失败则弹系统管理员密码框（osascript with administrator privileges）。

import AppKit
import SwiftUI

final class KeepAwakeModel: ObservableObject {
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
            let ok = Self.runAdminShell("pmset -a sleep 10")
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
            if line.hasPrefix("sleep ") {
                let value = line.replacingOccurrences(of: "sleep", with: "").trimmingCharacters(in: .whitespaces)
                if first {
                    first = false
                    if value == "0" { return "永不（耗电根源）" }
                    return "\(value) 分钟"
                }
            }
        }
        return "?"
    }

    // 设置：先试免密 sudo（配置过 sudoers 时零弹窗），失败则弹系统密码框
    static func setDisablesSleep(_ on: Bool) -> Bool {
        let cmd = on
            ? "pmset -a disablesleep 1"
            : "pmset -a disablesleep 0; pmset -a sleep 10"
        return runAdminShell(cmd)
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
    @StateObject private var model = KeepAwakeModel()

    var body: some Scene {
        MenuBarExtra {
            if model.busy {
                Text("正在切换…")
            } else {
                Button(model.isOn ? "关闭合盖不休眠" : "开启合盖不休眠") {
                    model.toggle()
                }
            }
            Divider()
            Text(model.isOn ? "状态：● 合盖继续运行中" : "状态：○ 正常休眠（合盖即睡）")
            Text("空闲休眠：\(model.idleSleepText)")
            if model.idleSleepText.hasPrefix("永不") {
                Button("修复：空闲休眠恢复为 10 分钟") {
                    model.restoreIdleSleep()
                }
            }
            if let error = model.lastError {
                Divider()
                Text(error)
            }
            Divider()
            Text("开启时会发热耗电，用完记得关")
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: model.isOn ? "sun.max.fill" : "moon")
        }
        .menuBarExtraStyle(.menu)
    }
}
