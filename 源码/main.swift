import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var controller: DisplayController?
    private let recovery = RecoverySession()
    private var timer: Timer?
    private var errorText: String?
    private var observers: [NSObjectProtocol] = []
    private var menuOpen = false
    private var testing = false
    private var hotKey: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.wuxianghao.ScreenSwitch").count > 1 {
            NSApp.terminate(nil)
            return
        }
        do {
            let backend = try SystemDisplayBackend()
            let model = DisplayController(backend: backend)
            model.prepareRecovery = { [weak self] display in
                guard let self else { throw SwitchError("程序已退出。") }
                guard let saved = backend.savedLayout else { throw SwitchError("恢复快照不可用。") }
                try self.recovery.start(target: display, saved: saved)
            }
            model.finishRecovery = { [weak self] in self?.recovery.stop() }
            model.preflight = { [weak self] in try self?.preflight() }
            controller = model
        } catch { errorText = error.localizedDescription }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "屏幕开关"
        statusItem.button?.setAccessibilityLabel("屏幕开关")
        registerHotKey()
        updateMenu()
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkState() }
        RunLoop.main.add(timer!, forMode: .common)
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.controller?.target != nil else { return }
            do { try self.controller?.restore(); self.errorText = nil }
            catch { self.errorText = error.localizedDescription }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.checkState() })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.checkState() }
        })
    }

    private var systemBackend: SystemDisplayBackend? { controller?.backend as? SystemDisplayBackend }
    private var hasSnapshot: Bool { systemBackend?.savedLayout != nil }

    private func conflicts() -> [String] {
        ConflictCheck.names(runningBundleIDs: NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    private var untestedBuild: String? {
        let build = SystemVersionGate.currentBuild()
        return SystemVersionGate.needsTest(current: build, verified: SystemVersionGate.verified) ? build : nil
    }

    private func preflight() throws {
        let running = conflicts()
        if !running.isEmpty {
            throw SwitchError("检测到 \(running.joined(separator: "、")) 正在运行。请先退出它，以免显示配置互相覆盖。")
        }
        if !testing, let build = untestedBuild {
            throw SwitchError("macOS 已更新（\(build)），尚未在此版本验证。请先使用菜单中的「安全测试」。")
        }
    }

    // ⌃⌥⌘R restores the built-in screen without needing to find the menu bar.
    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.hotKeyRestore() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey),
                                         EventHotKeyID(signature: 0x53535754, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { hotKey = nil }
    }

    private func hotKeyRestore() {
        let internalOn = (try? controller?.backend.displays())?.contains(where: { $0.builtIn && $0.active }) ?? false
        guard controller?.target != nil || hasSnapshot || !internalOn else { NSSound.beep(); return }
        perform { try controller?.restore() }
    }

    private func checkState() {
        do {
            if controller?.target != nil && !recovery.running { try controller?.restore() }
            try controller?.tick()
        } catch { errorText = error.localizedDescription }
        // Avoid replacing a menu while the user is choosing an action.
        if !menuOpen { updateMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; updateMenu(menu) }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    private func updateMenu(_ existing: NSMenu? = nil) {
        let menu = existing ?? NSMenu()
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.delegate = self
        let displays: [Display]
        do { displays = try controller?.backend.displays() ?? [] }
        catch { displays = []; errorText = error.localizedDescription }
        let internalOn = displays.contains(where: { $0.builtIn && $0.active })
        let externalCount = displays.filter(\.usableExternal).count
        statusItem.button?.image = NSImage(systemSymbolName: internalOn ? "laptopcomputer" : "laptopcomputer.slash", accessibilityDescription: "屏幕开关")
        if statusItem.button?.image == nil { statusItem.button?.title = "屏" }
        let heading = NSMenuItem(title: "屏幕开关", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        let state = internalOn ? "本机屏幕：已开启" : (controller?.target != nil ? "本机屏幕：已关闭" : "本机屏幕：未检测到活动屏幕")
        let info = NSMenuItem(title: "\(state) · 外接屏 \(externalCount)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        let running = conflicts()
        let build = untestedBuild
        if !running.isEmpty { menu.addItem(note("请先退出 \(running.joined(separator: "、"))")) }
        if let build { menu.addItem(note("系统已更新（\(build)），请先安全测试")) }
        let canSwitch = controller != nil && internalOn && externalCount > 0 && controller?.target == nil && !hasSnapshot && running.isEmpty && !testing
        let off = item("关闭本机屏幕", #selector(turnOff))
        off.isEnabled = canSwitch && build == nil
        menu.addItem(off)
        let on = item(hotKey == nil ? "恢复本机屏幕" : "恢复本机屏幕（⌃⌥⌘R）", #selector(restore))
        on.isEnabled = controller != nil && (controller?.target != nil || hasSnapshot || displays.contains(where: { $0.builtIn && !$0.active }))
        menu.addItem(on)
        let test = item("安全测试（关闭 5 秒后自动恢复）", #selector(safetyTest))
        test.isEnabled = canSwitch
        menu.addItem(test)
        if let errorText {
            menu.addItem(.separator())
            let error = NSMenuItem(title: String(errorText.split(separator: "\n").first ?? "操作失败"), action: nil, keyEquivalent: "")
            error.isEnabled = false
            menu.addItem(error)
        }
        menu.addItem(.separator())
        menu.addItem(item("使用说明…", #selector(showHelp)))
        menu.addItem(item("恢复并退出", #selector(quit)))
        if existing == nil { statusItem.menu = menu }
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func turnOff() { perform { try controller?.turnOff() } }
    @objc private func restore() { perform { try controller?.restore() } }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func safetyTest() {
        let build = SystemVersionGate.currentBuild()
        testing = true
        perform { try controller?.turnOff() }
        guard controller?.target != nil else { testing = false; updateMenu(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            if self.controller?.target != nil { self.perform { try self.controller?.restore() } }
            self.testing = false
            guard self.controller?.target == nil, !self.hasSnapshot else { self.updateMenu(); return }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "安全测试已恢复"
            alert.informativeText = "测试期间本机屏幕是否黑屏、外接屏是否正常显示，现在两屏是否都已恢复？\n\n确认正常后，将在此系统版本（\(build)）启用「关闭本机屏幕」。"
            alert.addButton(withTitle: "正常")
            alert.addButton(withTitle: "不正常")
            if alert.runModal() == .alertFirstButtonReturn { SystemVersionGate.markVerified(build) }
            else { self.errorText = "安全测试未通过，请勿在此系统版本使用。" }
            self.updateMenu()
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorText = systemBackend?.warning
            systemBackend?.warning = nil
        }
        catch {
            errorText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "屏幕切换未完成"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "知道了")
            alert.runModal()
        }
        updateMenu()
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "屏幕开关 · 1.3"
        alert.informativeText = "连接并唤醒外接屏，使用扩展显示模式，然后点击“关闭本机屏幕”。保持上盖打开即可继续使用自带键盘和触控板。\n\n切换时屏幕可能短暂黑屏并重新同步，稳定后只有外接屏显示。点击“恢复本机屏幕”或按 ⌃⌥⌘R 恢复两屏；同一组屏幕会恢复原主屏和位置。\n\n拔掉外接屏、正常退出或程序异常退出时，会尝试恢复本机屏幕。睡眠前会恢复，唤醒后如需关闭请再次点击。重启或重新登录后，如有未恢复的快照，会自动恢复本机屏幕。\n\n如遇黑屏，可按 ⌃⌥⌘R，合上再打开上盖，运行随附的“恢复本机屏幕.command”，或注销后重新登录。\n\nBetterDisplay、Lunar 运行时不能关闭本机屏幕。macOS 更新后，需先通过“安全测试”。\n\n工具会保存并修改系统显示器配置，恢复时还原。使用未公开接口，系统更新后可能失效。请勿同时使用其他显示器开关工具。\n\n个人使用工具，由 Codex 辅助开发；不联网。仅在本地保存显示器身份与位置，以便恢复。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller?.target != nil || (controller?.backend as? SystemDisplayBackend)?.savedLayout != nil else { return .terminateNow }
        do { try controller?.restore(); return .terminateNow }
        catch {
            errorText = error.localizedDescription
            perform { throw SwitchError("本机屏幕恢复失败，程序将继续运行以便重试。\n\(error.localizedDescription)") }
            return .terminateCancel
        }
    }
}

// Writing to the recovery helper after it has exited must not kill the app.
signal(SIGPIPE, SIG_IGN)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "--watchdog", arguments.count == 2, let data = Data(base64Encoded: arguments[1]), let saved = try? JSONDecoder().decode(SavedLayout.self, from: data) {
    exit(runWatchdog(saved: saved))
} else if arguments == ["--login-restore"] {
    exit(runLoginRestore())
} else if arguments == ["--status"] || arguments == ["--restore"] || arguments == ["--probe"] {
    do {
        let backend = try SystemDisplayBackend()
        if arguments == ["--restore"] {
            try DisplayController(backend: backend).restore()
            print("本机屏幕已恢复。")
        } else if arguments == ["--probe"] {
            let model = DisplayController(backend: backend)
            let rescue = RecoverySession()
            model.prepareRecovery = { display in
                guard let saved = backend.savedLayout else { throw SwitchError("恢复快照不可用。") }
                try rescue.start(target: display, saved: saved)
            }
            model.finishRecovery = { rescue.stop() }
            try model.turnOff()
            print("测试：原生内建屏断开请求已提交。请观察实际屏幕，10秒后恢复。")
            fflush(stdout)
            usleep(10_000_000)
            try model.restore()
            print("测试：内建屏与原布局已请求恢复。")
        } else {
            let displays = try backend.displays()
            print("显示接口：可用；显示器数量：\(displays.count)")
            for display in displays {
                let bounds = CGDisplayBounds(display.id)
                print("id=\(display.id) builtin=\(display.builtIn) active=\(display.active) asleep=\(display.asleep) main=\(CGDisplayIsMain(display.id) != 0) origin=(\(bounds.origin.x),\(bounds.origin.y))")
            }
            print("hasRecoverySnapshot=\(backend.savedLayout != nil)")
            let build = SystemVersionGate.currentBuild()
            print("osBuild=\(build) verified=\(!SystemVersionGate.needsTest(current: build, verified: SystemVersionGate.verified))")
            print("loginRescue=\(LoginRescue.installed ? LoginRescue.url.path : "none")")
        }
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(2) }
} else if arguments.isEmpty {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
} else {
    fputs("用法：ScreenSwitch [--status | --restore | --probe | --login-restore]\n", stderr)
    exit(1)
}
