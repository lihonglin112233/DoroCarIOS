import Foundation

/// 远程启动 / 熄火的前置条件判定。
///
/// 远程启动是整车通电并点火，风险等级和"开空调"完全不同。以下三种情况
/// 必须拦住，且要说清理由，而不是发出去让它失败：
/// - **已经在运行**：重复下发启动，车端要么报错要么无效；
/// - **有车门/后备箱打开**：存在人员误伤与车辆被盗风险；
/// - **电量过低**：纯电车启动高压系统会进一步亏电。
///
/// 熄火则相反：任何时候能熄火都是安全的，不做限制。
enum EngineGuard {

    /// 电量低于此值不建议远程启动（百分比）
    static let minBatteryPercent: Double = 15.0
    /// 小电瓶电压低于此值不建议远程启动（V）
    static let minBatteryVoltage: Double = 11.6

    struct Verdict {
        let allowed: Bool
        /// 是否属于"需要用户确认后仍可继续"的场景（如车门开着）
        let needsConfirm: Bool
        let message: String
    }

    /// 能否远程启动
    static func canStart(_ status: VehicleStatus?) -> Verdict {
        guard let status = status else {
            return Verdict(allowed: false, needsConfirm: false,
                           message: "车况还没读到，无法确认车辆状态，暂时不能远程启动")
        }
        guard status.engineState != nil else {
            return Verdict(allowed: false, needsConfirm: false,
                           message: "该车型没有上报启动状态，无法远程启动")
        }
        if status.isEngineRunning {
            return Verdict(allowed: false, needsConfirm: false,
                           message: "车辆已在\(status.engineText)，无需重复启动")
        }
        // 车门/后备箱/引擎盖未关：存在安全风险，要求用户确认
        if status.hasOpenDoor {
            return Verdict(allowed: true, needsConfirm: true,
                           message: "有车门或后备箱未关闭，远程启动前请确认车内无人、周围安全")
        }
        // 电量过低
        if let battery = status.batteryPercent, battery < minBatteryPercent {
            return Verdict(allowed: false, needsConfirm: false,
                           message: String(format: "电量仅剩 %.0f%%，低于 %.0f%%，不建议远程启动",
                                           battery, minBatteryPercent))
        }
        if let voltage = status.batteryVoltage, voltage < minBatteryVoltage {
            return Verdict(allowed: false, needsConfirm: false,
                           message: String(format: "蓄电池电压仅 %.1fV，可能无法启动", voltage))
        }
        return Verdict(allowed: true, needsConfirm: false, message: "可以远程启动")
    }

    /// 能否远程熄火：始终允许
    static func canStop(_ status: VehicleStatus?) -> Verdict {
        guard let status = status else {
            return Verdict(allowed: true, needsConfirm: false, message: "可以远程熄火")
        }
        if status.engineState != nil && !status.isEngineRunning {
            return Verdict(allowed: false, needsConfirm: false,
                           message: "车辆当前已\(status.engineText)，无需熄火")
        }
        return Verdict(allowed: true, needsConfirm: false, message: "可以远程熄火")
    }

    /// 按钮下方的状态提示
    static func hint(_ status: VehicleStatus?) -> String {
        guard let status = status else { return "车况未同步" }
        guard status.engineState != nil else { return "该车型不上报启动状态" }
        return status.isEngineRunning
            ? "\(status.engineText) · 可远程熄火"
            : "已\(status.engineText) · 可远程启动"
    }
}

/// 空调使能闸门：车没启动，就不许开空调。
///
/// 为什么这条规则必须放在协议层而不是 UI 层：远控空调是「唤醒 TBOX →
/// 车端空调模块通电 → 压缩机启动」，整条链路都建立在整车已上电的前提上。
/// 车在熄火状态下发这条指令，车端大概率静默丢弃，用户看到的却是
/// 「已下发，等待车端执行…」——等了 48 秒再告诉他没生效。
enum HvacGuard {

    struct Verdict {
        let allowed: Bool
        let message: String
    }

    private static let noStatus = "车况还没读到，无法确认车辆是否启动，暂时不能开空调"

    /// 车辆是否处于「已启动」状态。
    ///
    /// 判据是引擎状态 1=启动中 / 2=运行中。纯电车该字段同样有效——
    /// 车机上电动车的 powerState 会折算到 engineState。
    static func isVehicleStarted(_ s: VehicleStatus?) -> Bool {
        s?.isEngineRunning ?? false
    }

    static func canTurnOn(_ status: VehicleStatus?) -> Verdict {
        guard let status = status else {
            return Verdict(allowed: false, message: noStatus)
        }
        guard status.engineState != nil else {
            // 车型不上报引擎状态：宁可拦住，也不要发一条大概率无效的指令
            return Verdict(allowed: false,
                           message: "该车型没有上报启动状态，无法确认车辆已启动，不能远程开空调")
        }
        guard status.isEngineRunning else {
            return Verdict(allowed: false,
                           message: "车辆未启动（当前\(status.engineText)），启动后才能开空调")
        }
        return Verdict(allowed: true, message: "车辆已启动，可以开空调")
    }

    /// 关空调不设启动门槛：不管车在什么状态，能把空调关上总是安全的。
    static func canTurnOff(_ status: VehicleStatus?) -> Verdict {
        Verdict(allowed: true, message: "可以关空调")
    }

    /// 状态栏上的一句话提示，用于按钮下方常驻显示
    static func hint(_ status: VehicleStatus?) -> String {
        guard let status = status else { return "车况未同步" }
        guard status.engineState != nil else { return "该车型不上报启动状态" }
        return isVehicleStarted(status)
            ? "车辆已启动 · 可远程控制空调"
            : "车辆未启动 · 空调不可开启"
    }

    /// 当前平台是否支持远程空调类指令。
    ///
    /// 已经全部支持：gtsp / navinfo（AutoAI 通道）除了锁车、解锁、关窗、
    /// 鸣笛闪灯、远程启动、熄火、关天窗，还有独立的空调开启/关闭指令码。
    static func platformSupportsHvac(_ platform: String) -> Bool { true }

    /// 除霜 / 方向盘加热这类附件的平台支持。
    ///
    /// AutoAI 通道（gtsp / navinfo）目前没有对应的 cmdCode，下发会被拒；
    /// 只有 beantech 走 T5 通道才支持。
    static func platformSupportsAux(_ platform: String) -> Bool {
        let p = platform.lowercased()
        if p.isEmpty { return true }
        return !p.contains("gtsp") && !p.contains("navinfo")
    }

    static func unsupportedPlatformText(_ platform: String) -> String {
        let name = platform.isEmpty ? "未知" : platform
        return "当前车机平台（\(name)）未开放除霜/方向盘加热指令，可改用开空调调节车内温度"
    }
}
