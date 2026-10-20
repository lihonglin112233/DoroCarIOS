import Foundation
import UserNotifications

/// 一条状态变化提醒
struct StatusAlert: Identifiable, Equatable {
    let id = UUID()
    /// 变化项的中文名，如「门锁」
    let item: String
    /// 变化后的口语描述，如「车辆已闭锁」
    let text: String
    /// 是否偏安全的方向（闭锁/关窗 = true）。用于配色
    let good: Bool
}

/// 车辆状态提醒（对应哈弗 App 的「状态提醒」卡片）。
///
/// 工作方式：每次拿到新车况，和上一次的快照逐项比对；
/// 哪些项变了，就生成一条提醒（发系统通知 + 追加到界面提醒流）。
///
/// **为什么要比对而不是每次都报**：60 秒轮询一次，如果车况没变也报，
/// 一晚上就是几百条「车辆已闭锁」通知，用户必然关掉通知权限。
/// 只有「状态发生变化」才值得打扰。
///
/// **首次快照不提醒**：刚登录时上一次状态是空的，全部字段都算
/// "从无到有"，若照常提醒会一瞬间炸出十几条。首帧只记快照不播报。
@MainActor
final class StatusAlertCenter: ObservableObject {

    static let shared = StatusAlertCenter()

    /// 提醒流（最新在前，最多保留 50 条）
    @Published private(set) var alerts: [StatusAlert] = []
    /// 未读数量（进入前台时清零）
    @Published private(set) var unreadCount = 0
    /// 是否已请求过通知权限
    private var requestedAuthorization = false

    private struct Snapshot {
        var doorsLocked: Bool?
        var windowOpen: Bool?
        var trunkOpen: Bool?
        var engineRunning: Bool?
        var acOn: Bool?
        var batteryPercent: Double?
        var fuelRange: Double?
    }

    private var last: Snapshot?

    private init() {}

    func clearUnread() {
        unreadCount = 0
    }

    /// 追加一条本地产生的提醒（手动操作的反馈、帮助文案等），不发系统通知。
    func appendLocal(_ alert: StatusAlert) {
        alerts.insert(alert, at: 0)
        if alerts.count > 50 {
            alerts = Array(alerts.prefix(50))
        }
    }

    /// 每次车况刷新后调用；返回本轮产生的提醒。
    @discardableResult
    func process(_ status: VehicleStatus?, repository: GwmRepository) -> [StatusAlert] {
        guard let status = status else { return [] }
        guard repository.isPollEnabled else { return [] }
        guard let newAlerts = diff(status) else { return [] } // 首帧
        for a in newAlerts {
            alerts.insert(a, at: 0)
            unreadCount += 1
            postNotification(a, repository: repository)
        }
        if alerts.count > 50 {
            alerts = Array(alerts.prefix(50))
        }
        return newAlerts
    }

    /// 纯比对逻辑：只算"这次相比上次变了什么"。
    /// 返回 nil 表示首帧（没有上一次快照）。
    private func diff(_ s: VehicleStatus) -> [StatusAlert]? {
        let now = snapshotOf(s)
        let prev = last
        last = now
        guard let prev = prev else { return nil }

        var out: [StatusAlert] = []

        if let a = prev.doorsLocked, let b = now.doorsLocked, a != b {
            out.append(StatusAlert(item: "门锁", text: b ? "车辆已闭锁" : "车辆已解锁", good: b))
        }
        if let a = prev.windowOpen, let b = now.windowOpen, a != b {
            out.append(StatusAlert(item: "车窗", text: b ? "检测到车窗被打开" : "车窗已全部关闭", good: !b))
        }
        if let a = prev.trunkOpen, let b = now.trunkOpen, a != b {
            out.append(StatusAlert(item: "后备箱", text: b ? "后备箱已打开" : "后备箱已关闭", good: !b))
        }
        if let a = prev.engineRunning, let b = now.engineRunning, a != b {
            out.append(StatusAlert(item: "发动机", text: b ? "发动机已启动" : "发动机已熄火", good: b))
        }
        if let a = prev.acOn, let b = now.acOn, a != b {
            out.append(StatusAlert(item: "空调", text: b ? "空调已开启" : "空调已关闭", good: b))
        }
        // 电量：每跌 10% 提醒一次（PHEV/纯电）
        if let a = prev.batteryPercent, let b = now.batteryPercent {
            let nowStep = Int(floor(b / 10))
            let prevStep = Int(floor(a / 10))
            if nowStep < prevStep && b <= 30 {
                out.append(StatusAlert(item: "电量",
                                       text: "电量已低于 \((nowStep + 1) * 10)%（当前 \(Int(b.rounded()))%）",
                                       good: false))
            }
        }
        // 续航：每跌 50km 提醒一次
        if let a = prev.fuelRange, let b = now.fuelRange, b < a {
            let nowStep = Int(floor(b / 50))
            let prevStep = Int(floor(a / 50))
            if nowStep < prevStep && b <= 100 {
                out.append(StatusAlert(item: "续航",
                                       text: "续航不足 \((nowStep + 1) * 50) km（当前 \(Int(b.rounded())) km）",
                                       good: false))
            }
        }
        return out
    }

    private func snapshotOf(_ s: VehicleStatus) -> Snapshot {
        Snapshot(doorsLocked: s.doorsLocked,
                 windowOpen: s.hasOpenWindow,
                 trunkOpen: s.doorTrunk,
                 engineRunning: s.isEngineRunning,
                 acOn: s.airConditioner,
                 batteryPercent: s.batteryPercent,
                 fuelRange: s.fuelRange)
    }

    // MARK: - 通知

    /// 请求通知权限（只请求一次）
    func requestAuthorizationIfNeeded() {
        guard !requestedAuthorization else { return }
        requestedAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func postNotification(_ a: StatusAlert, repository: GwmRepository) {
        let content = UNMutableNotificationContent()
        content.title = "状态提醒"
        content.body = a.item + "：" + a.text
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
