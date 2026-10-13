import Foundation
import CoreGraphics
import Darwin

struct Display: Equatable {
    let id: UInt32
    let uuid: String?
    let builtIn: Bool
    let active: Bool
    let asleep: Bool
    var usableExternal: Bool { !builtIn && active && !asleep }
}

struct SwitchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

enum Snapshot {
    static let key = "restoreLayout.v1"
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.synchronize()
    }
}

/// A per-user launch agent that runs `--login-restore` at each login. It does
/// nothing unless a recovery snapshot was left behind, e.g. after a restart
/// or after both processes were killed while the built-in screen was off.
enum LoginRescue {
    static let label = "local.wuxianghao.ScreenSwitch.login-restore"
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["SCREENSWITCH_AGENT_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("\(label).plist") }
    static var installed: Bool { FileManager.default.fileExists(atPath: url.path) }

    static func install(executable: String) throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--login-restore"],
            "RunAtLoad": true,
            "LimitLoadToSessionType": "Aqua",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        if (try? Data(contentsOf: url)) == data { return }
        // Only write the file; launchd picks it up at the next login. Loading it
        // now would run the restore immediately.
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// The private display API was field-tested on one macOS build. Other builds
/// must pass a short self-reverting test before normal use.
enum SystemVersionGate {
    static let baseline = "25A8353"
    static let key = "verifiedOSBuilds"

    static func currentBuild() -> String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buffer)
    }
    static func needsTest(current: String, verified: [String]) -> Bool {
        current != baseline && !verified.contains(current)
    }
    static var verified: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func markVerified(_ build: String) {
        guard !verified.contains(build) else { return }
        UserDefaults.standard.set(verified + [build], forKey: key)
        UserDefaults.standard.synchronize()
    }
}

/// Other display managers also commit display configurations and may undo or
/// fight ours.
enum ConflictCheck {
    static let known = ["pro.betterdisplay.BetterDisplay": "BetterDisplay", "fyi.lunar.Lunar": "Lunar"]
    static func names(runningBundleIDs: [String]) -> [String] {
        Array(Set(runningBundleIDs.compactMap { known[$0] })).sorted()
    }
}

protocol DisplayBackend {
    func displays() throws -> [Display]
    func prepareForSwitch() throws
    func setEnabled(_ enabled: Bool, id: UInt32) throws
    func waitForUpdate()
}

final class SystemDisplayBackend: DisplayBackend {
    private let native: NativeLayout
    private let preferences = UserDefaults.standard
    private(set) var savedLayout: SavedLayout?
    /// Set when the last restore re-enabled the screen but not its position.
    var warning: String?

    init() throws {
        native = try NativeLayout()
        if let data = preferences.data(forKey: Snapshot.key) {
            let saved = try? JSONDecoder().decode(SavedLayout.self, from: data)
            if saved?.screens.filter(\.builtIn).count == 1 { savedLayout = saved }
        }
    }

    func displays() throws -> [Display] {
        let ids = try native.ids()
        var result = ids.filter { $0 != 0 }.map { id in
            Display(id: id, uuid: native.uuid(id), builtIn: CGDisplayIsBuiltin(id) != 0,
                    active: CGDisplayIsActive(id) != 0, asleep: CGDisplayIsAsleep(id) != 0)
        }
        if !result.contains(where: \.builtIn), let saved = savedLayout?.internalScreen {
            result.append(Display(id: saved.id, uuid: saved.uuid, builtIn: true, active: false, asleep: true))
        }
        return result
    }

    func prepareForSwitch() throws {
        guard savedLayout == nil else { throw SwitchError("有上次的恢复快照，请先点击恢复本机屏幕。") }
        let saved = try native.capture()
        guard saved.internalScreen != nil, try native.hasExternal() else {
            throw SwitchError("请先连接并唤醒外接屏，使用扩展显示模式。")
        }
        guard let executable = Bundle.main.executablePath else { throw SwitchError("无法确定程序位置，已取消关闭。") }
        do { try LoginRescue.install(executable: executable) }
        catch { throw SwitchError("无法写入登录恢复项，已取消关闭：\(error.localizedDescription)") }
        savedLayout = saved
        // Keep a recovery snapshot for the companion script after both processes
        // have exited. It contains display IDs, UUIDs and positions only.
        preferences.set(try JSONEncoder().encode(saved), forKey: Snapshot.key)
        guard preferences.synchronize() else { throw SwitchError("恢复快照未能保存，已取消关闭。") }
    }

    func setEnabled(_ enabled: Bool, id: UInt32) throws {
        if enabled {
            var placed = true
            if let savedLayout { placed = try native.restore(savedLayout) }
            else { try native.enableBuiltin(id) }
            guard try native.ids().contains(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }) else {
                throw SwitchError("恢复后未检测到活动内建屏，请再次恢复或合上再打开上盖。")
            }
            savedLayout = nil
            Snapshot.clear()
            warning = placed ? nil : "本机屏幕已恢复，但屏幕位置未能完全还原，请在系统设置中调整。"
        } else {
            guard let savedLayout else { throw SwitchError("缺少恢复快照，已取消关闭。") }
            try native.disable(savedLayout)
        }
    }

    func waitForUpdate() { usleep(100_000) }
}

final class DisplayController {
    let backend: DisplayBackend
    private(set) var target: Display?
    /// Checks that must pass before anything is touched (conflicts, OS build).
    var preflight: () throws -> Void = {}
    var prepareRecovery: (Display) throws -> Void = { _ in }
    var finishRecovery: () -> Void = {}

    init(backend: DisplayBackend) { self.backend = backend }

    func turnOff() throws {
        guard target == nil else { throw SwitchError("请先恢复本机屏幕。") }
        try preflight()
        let before = try backend.displays()
        guard let builtIn = before.first(where: { $0.builtIn && $0.active }) else {
            throw SwitchError("未找到正在使用的本机屏幕。")
        }
        guard before.contains(where: \.usableExternal) else {
            throw SwitchError("请先连接并唤醒外接屏；镜像模式下请先改为扩展显示。")
        }
        try backend.prepareForSwitch()
        target = builtIn
        do {
            try prepareRecovery(builtIn)
            let latest = try backend.displays()
            guard latest.contains(where: \.usableExternal) else {
                throw SwitchError("外接屏已断开，已取消关闭。")
            }
            guard let fresh = latest.first(where: { $0.builtIn && $0.active }), fresh.uuid == builtIn.uuid else {
                throw SwitchError("内建屏身份在切换前发生变化，已取消关闭。")
            }
            target = fresh
            try backend.setEnabled(false, id: fresh.id)
            guard try verify({ !$0.contains(where: { $0.builtIn && $0.active }) && $0.contains(where: \.usableExternal) }) else {
                throw SwitchError("系统未能移除本机屏幕，已尝试恢复。")
            }
        } catch {
            let original = error.localizedDescription
            do { try restore() }
            catch { throw SwitchError("\(original)\n恢复也失败：\(error.localizedDescription)\n请运行随附恢复工具，或合上再打开上盖。") }
            throw SwitchError(original)
        }
    }

    func restore() throws {
        let current = try backend.displays()
        guard let builtIn = current.first(where: \.builtIn) ?? target else {
            throw SwitchError("未找到本机屏幕，无法恢复。")
        }
        // Always enter the backend: it may still have positions to restore even
        // if macOS has already reactivated the built-in screen on wake.
        try backend.setEnabled(true, id: builtIn.id)
        guard try verify({ $0.contains(where: { $0.builtIn && $0.active }) }) else {
            throw SwitchError("恢复请求未生效，请再次恢复或合上再打开上盖。")
        }
        target = nil
        finishRecovery()
    }

    func tick() throws {
        guard target != nil else { return }
        let current = try backend.displays()
        if current.contains(where: { $0.builtIn && $0.active }) || !current.contains(where: \.usableExternal) {
            try restore()
        }
    }

    private func verify(_ predicate: ([Display]) -> Bool) throws -> Bool {
        for _ in 0..<20 {
            if predicate(try backend.displays()) { return true }
            backend.waitForUpdate()
        }
        return false
    }
}

final class RecoverySession {
    private var process: Process?
    private var input: Pipe?
    func start(target: Display, saved: SavedLayout) throws {
        guard process == nil else { throw SwitchError("恢复进程尚未结束，请稍后重试。") }
        let child = Process(); let stdinPipe = Pipe(); let stdoutPipe = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--watchdog", try JSONEncoder().encode(saved).base64EncodedString()]
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice
        try child.run()
        let ready = stdoutPipe.fileHandleForReading.availableData
        guard String(data: ready, encoding: .utf8)?.hasPrefix("READY") == true else {
            try? stdinPipe.fileHandleForWriting.close()
            throw SwitchError("恢复进程无法启动，已取消关闭屏幕。")
        }
        process = child; input = stdinPipe
    }
    var running: Bool { process?.isRunning == true }
    func stop() {
        try? input?.fileHandleForWriting.write(contentsOf: Data("Q".utf8))
        try? input?.fileHandleForWriting.close()
        input = nil; process = nil
    }
}

func runWatchdog(saved: SavedLayout) -> Int32 {
    do {
        let native = try NativeLayout()
        guard let target = saved.internalScreen, native.uuid(target.id) == target.uuid, try native.hasExternal() else { return 2 }
        let flags = fcntl(STDIN_FILENO, F_GETFL)
        guard flags >= 0, fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK) == 0 else { return 2 }
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        var parentGone = false; var attempts = 0
        while true {
            var byte: UInt8 = 0
            let count = read(STDIN_FILENO, &byte, 1)
            if count == 1 && byte == 81 { return 0 }
            if count == 0 { parentGone = true }
            if parentGone || (try? native.hasExternal()) != true {
                do {
                    try native.restore(saved)
                    guard try native.ids().contains(where: { CGDisplayIsBuiltin($0) != 0 && CGDisplayIsActive($0) != 0 }) else {
                        throw SwitchError("恢复后尚未检测到内建屏。")
                    }
                    // While the app is alive it owns the snapshot and finishes
                    // its own restore once it sees this helper has exited.
                    if parentGone { Snapshot.clear() }
                    return 0
                } catch {
                    fputs("恢复失败：\(error.localizedDescription)\n", stderr)
                }
                // Keep trying for about a minute; the login agent and the
                // companion script remain as later fallbacks.
                if parentGone { attempts += 1; if attempts >= 120 { return 3 } }
            }
            usleep(500_000)
        }
    } catch { return 2 }
}

func runLoginRestore() -> Int32 {
    // WindowServer may still be bringing displays up right after login.
    for attempt in 0..<30 {
        do {
            let backend = try SystemDisplayBackend()
            guard backend.savedLayout != nil else { return 0 }
            try DisplayController(backend: backend).restore()
            return 0
        } catch {
            fputs("登录恢复失败：\(error.localizedDescription)\n", stderr)
            if attempt < 29 { sleep(2) }
        }
    }
    return 3
}
