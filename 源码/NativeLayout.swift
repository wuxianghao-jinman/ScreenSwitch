import Foundation
import CoreGraphics
import ColorSync
import Darwin

struct SavedScreen: Codable {
    let id: UInt32
    let uuid: String
    let builtIn: Bool
    let x: Int32
    let y: Int32
}

struct SavedLayout: Codable {
    let screens: [SavedScreen]
    var internalScreen: SavedScreen? { screens.first(where: \.builtIn) }
}

// Independently implemented from the CoreGraphics SDK transaction contract.
// BetterDisplay 4.3.7's public binary imports CGSConfigureDisplayEnabled and
// its adjacent CGCompleteDisplayConfiguration calls pass option 2.
// SDK option 2 is kCGConfigurePermanently; the earlier app used option 1.
final class NativeLayout {
    typealias Configure = @convention(c) (OpaquePointer?, UInt32, Bool) -> Int32
    typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    private let library: UnsafeMutableRawPointer
    private let configure: Configure
    private let list: List

    init() throws {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW | RTLD_LOCAL) else {
            throw NSError(domain: "ScreenSwitch", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法加载显示接口"])
        }
        guard let function = dlsym(handle, "CGSConfigureDisplayEnabled"), let enumerate = dlsym(handle, "CGSGetDisplayList") else {
            dlclose(handle)
            throw NSError(domain: "ScreenSwitch", code: 2, userInfo: [NSLocalizedDescriptionKey: "缺少显示配置接口"])
        }
        library = handle
        configure = unsafeBitCast(function, to: Configure.self)
        list = unsafeBitCast(enumerate, to: List.self)
    }
    deinit { dlclose(library) }

    func ids() throws -> [UInt32] {
        var ids = [UInt32](repeating: 0, count: 128); var count: UInt32 = 0
        let result = list(128, &ids, &count)
        guard result == 0, count < 128 else { throw error("读取显示器失败", result) }
        return Array(ids.prefix(Int(count)))
    }

    func uuid(_ id: UInt32) -> String? {
        guard let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, value) as String
    }

    func capture() throws -> SavedLayout {
        let screens = try ids().filter { CGDisplayIsActive($0) != 0 }.map { id -> SavedScreen in
            guard let uuid = uuid(id) else { throw error("无法稳定标识显示器", 3) }
            let bounds = CGDisplayBounds(id)
            return SavedScreen(id: id, uuid: uuid, builtIn: CGDisplayIsBuiltin(id) != 0,
                               x: Int32(bounds.origin.x), y: Int32(bounds.origin.y))
        }
        return SavedLayout(screens: screens)
    }

    func hasExternal() throws -> Bool {
        try ids().contains { CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 && CGDisplayIsAsleep($0) == 0 }
    }

    func disable(_ saved: SavedLayout) throws {
        guard let internalScreen = saved.internalScreen, CGDisplayIsBuiltin(internalScreen.id) != 0,
              uuid(internalScreen.id) == internalScreen.uuid, try hasExternal() else {
            throw error("目标身份或外接屏检查未通过", 4)
        }
        try change(internalScreen.id, false, anchor: externalMain(in: saved))
    }

    /// Returns false when the built-in screen is active again but the saved
    /// positions could not be re-applied after several attempts.
    @discardableResult
    func restore(_ saved: SavedLayout) throws -> Bool {
        guard let original = saved.internalScreen else { throw error("恢复快照缺少内建屏", 5) }
        let all = try ids()
        let id = all.first(where: { CGDisplayIsBuiltin($0) != 0 && uuid($0) == original.uuid }) ?? original.id
        if all.contains(id), let currentUUID = uuid(id), currentUUID != original.uuid {
            throw error("原显示器编号已被另一块屏幕使用，已取消自动恢复", 6)
        }
        // Set only the already-active external main's origin in the enable
        // transaction; the built-in keeps its remembered position, so one
        // reconfiguration usually restores the whole layout. Setting the
        // inactive built-in's origin here is rejected with code 1001; any
        // leftover mismatch is fixed by the arrange pass below.
        if CGDisplayIsActive(id) == 0 { try change(id, true, anchor: externalMain(in: saved)) }
        for _ in 0..<20 {
            if CGDisplayIsActive(id) != 0 { break }
            usleep(100_000)
        }
        guard CGDisplayIsActive(id) != 0 else { throw error("内建屏尚未恢复活动状态", 8) }
        let savedUUIDs = Set(saved.screens.map(\.uuid))
        let matches = { (current: SavedLayout) in saved.screens.allSatisfy { old in
            current.screens.contains { $0.uuid == old.uuid && $0.x == old.x && $0.y == old.y }
        } }
        for attempt in 0...3 {
            var current = try capture()
            // Give WindowServer time to settle after a previous layout commit.
            for _ in 0..<(attempt == 0 ? 0 : 15) where !matches(current) {
                usleep(100_000)
                current = try capture()
            }
            // After unplug, let macOS place the survivors instead of restoring
            // coordinates from an obsolete screen combination.
            guard Set(current.screens.map(\.uuid)) == savedUUIDs else { return true }
            if matches(current) { return true }
            if attempt == 3 { return false }
            try arrange(saved, current: current, builtinID: id, builtinUUID: original.uuid)
        }
        return false
    }

    private func arrange(_ saved: SavedLayout, current: SavedLayout, builtinID: UInt32, builtinUUID: String) throws {
        var config: CGDisplayConfigRef?
        let result = CGBeginDisplayConfiguration(&config)
        guard result == .success, let config else { throw error("无法开始布局恢复", result.rawValue) }
        for screen in saved.screens {
            let currentID = screen.uuid == builtinUUID ? builtinID : current.screens.first(where: { $0.uuid == screen.uuid })?.id
            guard let currentID else { continue }
            let changed = CGConfigureDisplayOrigin(config, currentID, screen.x, screen.y)
            guard changed == .success else {
                CGCancelDisplayConfiguration(config)
                throw error("无法恢复屏幕位置", changed.rawValue)
            }
        }
        let applied = CGCompleteDisplayConfiguration(config, .permanently)
        guard applied == .success else { throw error("布局恢复提交失败", applied.rawValue) }
    }

    func enableBuiltin(_ id: UInt32) throws {
        guard CGDisplayIsBuiltin(id) != 0 else { throw error("无法确认恢复目标是内建屏", 7) }
        if CGDisplayIsActive(id) == 0 { try change(id, true) }
    }

    private func externalMain(in saved: SavedLayout) -> SavedScreen? {
        saved.screens.first { !$0.builtIn && $0.x == 0 && $0.y == 0 }
    }

    // Fade every display to black before the reconfiguration and back in after
    // it, so the resync blank looks like a deliberate transition. A transaction
    // fade effect makes CGSConfigureDisplayEnabled commits fail (1006), so this
    // uses a fade reservation, which the system undoes by itself if we die.
    private func withFade(_ body: () throws -> Void) throws {
        var token: CGDisplayFadeReservationToken = 0
        guard CGAcquireDisplayFadeReservation(5, &token) == .success else { return try body() }
        defer {
            // Give the displays a moment to resync before fading back in.
            usleep(250_000)
            CGDisplayFade(token, 0.45, 1.0, 0.0, 0, 0, 0, 0)
            CGReleaseDisplayFadeReservation(token)
        }
        CGDisplayFade(token, 0.25, 0.0, 1.0, 0, 0, 0, 1)
        try body()
    }

    private func change(_ id: UInt32, _ on: Bool, anchor: SavedScreen? = nil) throws {
        try withFade { try commit(id, on, anchor: anchor) }
    }

    private func commit(_ id: UInt32, _ on: Bool, anchor: SavedScreen?) throws {
        var config: CGDisplayConfigRef?
        let result = CGBeginDisplayConfiguration(&config)
        guard result == .success, let config else { throw error("无法开始显示配置", result.rawValue) }
        // Anchoring a still-active display stops macOS choosing the newly
        // enabled built-in as main. Resolve by UUID, not a reusable numeric ID.
        if let anchor {
            let anchorID: UInt32?
            do { anchorID = try ids().first { uuid($0) == anchor.uuid && CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 } }
            catch { CGCancelDisplayConfiguration(config); throw error }
            if let anchorID {
                let placed = CGConfigureDisplayOrigin(config, anchorID, anchor.x, anchor.y)
                guard placed == .success else { CGCancelDisplayConfiguration(config); throw error("外接主屏位置配置失败", placed.rawValue) }
            }
        }
        let changed = configure(config, id, on)
        guard changed == 0 else {
            CGCancelDisplayConfiguration(config)
            throw error("系统拒绝显示开关", changed)
        }
        let applied = CGCompleteDisplayConfiguration(config, .permanently)
        guard applied == .success else { throw error("显示开关提交失败", applied.rawValue) }
    }

    private func error(_ text: String, _ code: Int32) -> NSError {
        NSError(domain: "ScreenSwitch", code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(text)（\(code)）"])
    }
}
