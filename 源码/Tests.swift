import Foundation

final class FakeBackend: DisplayBackend {
    var values: [Display]
    var changes: [(Bool, UInt32)] = []
    var ignoreOff = false
    var rejectOff = false
    var rejectOn = false
    var readFails = false
    var changeHook: ((Bool) -> Void)?
    var prepareFails = false
    func prepareForSwitch() throws {
        if prepareFails { throw SwitchError("模拟恢复快照失败") }
    }
    init(_ values: [Display]) { self.values = values }
    func displays() throws -> [Display] {
        if readFails { throw SwitchError("模拟读取失败") }
        return values
    }
    func setEnabled(_ enabled: Bool, id: UInt32) throws {
        changes.append((enabled, id))
        if (!enabled && rejectOff) || (enabled && rejectOn) { throw SwitchError("模拟接口拒绝") }
        if enabled || !ignoreOff {
            values = values.map { d in
                d.id == id ? Display(id: id, uuid: d.uuid, builtIn: d.builtIn, active: enabled, asleep: false) : d
            }
        }
        changeHook?(enabled)
    }
    func waitForUpdate() {}
}

func check(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    print("PASS: \(name)")
}

func mustFail(_ name: String, _ action: () throws -> Void) {
    do { try action(); check(false, name) }
    catch { print("PASS: \(name)") }
}

@main struct Tests {
    static func main() throws {
        let builtIn = Display(id: 1, uuid: "internal", builtIn: true, active: true, asleep: false)
        let external = Display(id: 2, uuid: "external", builtIn: false, active: true, asleep: false)
        let asleep = Display(id: 2, uuid: "external", builtIn: false, active: true, asleep: true)
        do {
            let b = FakeBackend([builtIn]); let c = DisplayController(backend: b)
            mustFail("没有外接屏时拒绝关闭") { try c.turnOff() }
            check(b.changes.isEmpty, "拒绝后不调用显示修改接口")
        }
        do {
            let b = FakeBackend([builtIn, asleep]); let c = DisplayController(backend: b)
            mustFail("外接屏处于睡眠时拒绝关闭") { try c.turnOff() }
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            c.prepareRecovery = { _ in throw SwitchError("恢复进程启动失败") }
            mustFail("恢复进程启动失败时拒绝关闭") { try c.turnOff() }
            check(!b.changes.contains(where: { !$0.0 }), "恢复未就绪时不关闭屏幕")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            c.prepareRecovery = { _ in b.values = [builtIn] }
            mustFail("关闭前外接屏突然拔除时取消") { try c.turnOff() }
            check(!b.changes.contains(where: { !$0.0 }), "竞态不会发出关闭请求")
        }
        do {
            let b = FakeBackend([builtIn, external]); b.ignoreOff = true
            let c = DisplayController(backend: b)
            mustFail("接口成功但屏幕未关闭时报告失败") { try c.turnOff() }
            check(c.target == nil && b.values[0].active, "无效关闭不保留已关闭状态")
        }
        do {
            let b = FakeBackend([builtIn, external]); b.rejectOff = true
            let c = DisplayController(backend: b)
            mustFail("显示接口拒绝时报告失败") { try c.turnOff() }
            check(c.target == nil, "失败后停止恢复进程")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            try c.turnOff()
            check(c.target != nil && !b.values[0].active, "模拟原生内建屏断开")
            b.values.removeAll(where: { !$0.builtIn })
            try c.tick()
            check(b.values[0].active && c.target == nil, "拔掉最后一个外接屏时恢复")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            try c.turnOff(); b.values[0] = builtIn
            try c.tick()
            check(c.target == nil && b.changes.count == 2, "系统重新连接内建屏时完成恢复流程")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            try c.turnOff()
            b.values[0] = Display(id: 9, uuid: "internal", builtIn: true, active: false, asleep: false)
            try c.restore()
            check(b.changes.last!.1 == 9 && b.values[0].active, "恢复时使用更新后的显示器 ID")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            try c.turnOff(); b.rejectOn = true
            var finished = false; c.finishRecovery = { finished = true }
            mustFail("恢复接口失败时不伪报成功") { try c.restore() }
            check(c.target != nil && !finished, "恢复失败时保留后台救援")
            b.rejectOn = false; try c.restore()
            check(c.target == nil && finished, "后续重试可完成恢复")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            b.changeHook = { enabled in if !enabled { b.values.removeAll(where: { !$0.builtIn }) } }
            mustFail("关闭过程中外接屏消失时回滚") { try c.turnOff() }
            check(b.values[0].active && c.target == nil, "中途失去外接屏后恢复内屏")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            b.readFails = true
            mustFail("无法读取屏幕时拒绝操作") { try c.turnOff() }
            check(b.changes.isEmpty, "读取失败不会修改屏幕")
        }
        do {
            let b = FakeBackend([builtIn, external]); b.prepareFails = true
            let c = DisplayController(backend: b)
            mustFail("恢复快照无法准备时拒绝关闭") { try c.turnOff() }
            check(b.changes.isEmpty, "没有快照时不修改显示配置")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            c.prepareRecovery = { _ in
                b.values[0] = Display(id: 1, uuid: "different", builtIn: true, active: true, asleep: false)
            }
            mustFail("切换前目标身份改变时拒绝关闭") { try c.turnOff() }
            check(!b.changes.contains(where: { !$0.0 }), "不关闭身份已经改变的屏幕")
        }
        do {
            let b = FakeBackend([builtIn, external]); let c = DisplayController(backend: b)
            var prepared = false
            c.preflight = { throw SwitchError("模拟冲突") }
            c.prepareRecovery = { _ in prepared = true }
            mustFail("前置检查未通过时拒绝关闭") { try c.turnOff() }
            check(b.changes.isEmpty && !prepared && c.target == nil, "前置检查失败不启动恢复也不修改屏幕")
        }
        check(ConflictCheck.names(runningBundleIDs: ["com.apple.finder", "pro.betterdisplay.BetterDisplay", "fyi.lunar.Lunar"]) == ["BetterDisplay", "Lunar"], "识别冲突的显示器工具")
        check(ConflictCheck.names(runningBundleIDs: ["com.apple.finder"]).isEmpty, "无冲突工具时不阻止")
        check(!SystemVersionGate.needsTest(current: SystemVersionGate.baseline, verified: []), "已现场验证的系统版本无需测试")
        check(SystemVersionGate.needsTest(current: "25B1", verified: []), "新系统版本需要安全测试")
        check(!SystemVersionGate.needsTest(current: "25B1", verified: ["25B1"]), "安全测试通过后放行")
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenSwitchAgentTest-\(getpid())")
            setenv("SCREENSWITCH_AGENT_DIR", dir.path, 1)
            defer { try? FileManager.default.removeItem(at: dir); unsetenv("SCREENSWITCH_AGENT_DIR") }
            try LoginRescue.install(executable: "/Applications/屏幕开关.app/Contents/MacOS/ScreenSwitch")
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: LoginRescue.url), format: nil) as? [String: Any]
            check(plist?["ProgramArguments"] as? [String] == ["/Applications/屏幕开关.app/Contents/MacOS/ScreenSwitch", "--login-restore"]
                  && plist?["RunAtLoad"] as? Bool == true, "登录恢复项指向本程序的登录恢复模式")
            let first = try FileManager.default.attributesOfItem(atPath: LoginRescue.url.path)[.modificationDate] as? Date
            usleep(20_000)
            try LoginRescue.install(executable: "/Applications/屏幕开关.app/Contents/MacOS/ScreenSwitch")
            let second = try FileManager.default.attributesOfItem(atPath: LoginRescue.url.path)[.modificationDate] as? Date
            check(first == second, "内容相同时不重复写入登录恢复项")
            try LoginRescue.install(executable: "/moved/ScreenSwitch")
            let moved = try PropertyListSerialization.propertyList(from: Data(contentsOf: LoginRescue.url), format: nil) as? [String: Any]
            check((moved?["ProgramArguments"] as? [String])?.first == "/moved/ScreenSwitch", "程序移动后更新登录恢复项路径")
        }
        print("全部安全逻辑测试通过。")
    }
}
