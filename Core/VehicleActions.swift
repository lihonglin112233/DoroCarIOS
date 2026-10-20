import Foundation

/// 语义动作 ↔ 协议 controlType 的映射。
///
/// 界面上按"人话"触发（锁车、开空调），协议层按 controlType 下发。
/// 中间这层存在的意义：连带动作用的是语义（锁车要带关窗），
/// 而校验用的是"期望的车况值"——两者都不该散落在 UI 里。
enum VehicleActions {

    enum Action: String, CaseIterable {
        case lock = "LOCK"
        case unlock = "UNLOCK"
        case windowClose = "WINDOW_CLOSE"
        case whistle = "WHISTLE"
        case flash = "FLASH"
        case acOn = "AC_ON"
        case acOff = "AC_OFF"
        case defrostFront = "DEFROST_FRONT"
        case defrostRear = "DEFROST_REAR"
        case steerHeat = "STEER_HEAT"
        case engineStart = "ENGINE_START"
        case engineStop = "ENGINE_STOP"
        /// 设定空调温度：协议里没有独立的温度 controlType，
        /// 走 `AIR_CONDITIONER_START` 带 cmdBody
        case acTempSet = "AC_TEMP_SET"

        var label: String {
            switch self {
            case .lock: return "锁车"
            case .unlock: return "解锁"
            case .windowClose: return "关车窗"
            case .whistle: return "鸣笛"
            case .flash: return "闪灯"
            case .acOn: return "开空调"
            case .acOff: return "关空调"
            case .defrostFront: return "前除霜"
            case .defrostRear: return "后除霜"
            case .steerHeat: return "方向盘加热"
            case .engineStart: return "远程启动"
            case .engineStop: return "远程熄火"
            case .acTempSet: return "调温"
            }
        }

        var controlType: String {
            switch self {
            case .lock: return GwmClient.Cmd.lock
            case .unlock: return GwmClient.Cmd.unlock
            case .windowClose: return GwmClient.Cmd.windowClose
            case .whistle: return GwmClient.Cmd.whistle
            case .flash: return GwmClient.Cmd.flash
            case .acOn: return GwmClient.Cmd.acStart
            case .acOff: return GwmClient.Cmd.acStop
            case .defrostFront: return GwmClient.Cmd.defrostFrontStart
            case .defrostRear: return GwmClient.Cmd.defrostBackStart
            case .steerHeat: return GwmClient.Cmd.steerHeatStart
            case .engineStart: return GwmClient.Cmd.engineStart
            case .engineStop: return GwmClient.Cmd.engineStop
            case .acTempSet: return GwmClient.Cmd.acStart
            }
        }

        /// 该动作是否需要「车辆已启动」才允许执行。
        ///
        /// 空调、除霜、方向盘加热都属于整车通电后才工作的附件，
        /// 熄火状态下下发大概率被车端丢弃，所以统一走 `HvacGuard` 拦一道。
        /// 关空调不在此列：能把空调关掉总是安全的。
        var needsEngine: Bool {
            switch self {
            case .acOn, .acTempSet, .defrostFront, .defrostRear, .steerHeat: return true
            default: return false
            }
        }
    }

    /// 远程启动的默认运行时长（分钟）
    static let defaultRunMinutes = 15
    /// 可选的运行时长档位
    static let runMinuteOptions = [10, 15, 20, 30]

    /// 该动作对应的校验步骤（探针）
    static func stepOf(_ action: Action, celsius: Float? = nil) -> CommandOutcome.Step {
        let temp = celsius ?? TempControl.defaultC
        switch action {
        case .lock:
            return .init(controlType: action.controlType, label: action.label, probe: CommandOutcome.Probe.locked)
        case .unlock:
            return .init(controlType: action.controlType, label: action.label,
                         probe: .init("解锁") { s in s.map { $0.doorsLocked == false } })
        case .windowClose:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.sideWindowsClosed)
        case .acOn:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.acOn)
        case .acOff:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.acOff)
        case .defrostFront:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.frontDefrostOn)
        case .defrostRear:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.rearDefrostOn)
        case .steerHeat:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.steerHeatOn)
        case .engineStart:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.engineRunning)
        case .engineStop:
            return .init(controlType: action.controlType, label: action.label,
                         probe: CommandOutcome.Probe.engineOff)
        case .whistle, .flash:
            return .init(controlType: action.controlType, label: action.label, probe: nil)
        case .acTempSet:
            // 有设定温度回读就验到目标值，没有就只能确认已下发
            return .init(controlType: action.controlType, label: TempControl.labelOf(temp),
                         probe: CommandOutcome.Probe.tempAt(temp))
        }
    }

    /// 远程启动的附加参数。
    ///
    /// 远程启动必须带时长：gtsp 的 AutoAI 通道会把它换算成
    /// `engineParams.runTime`（分钟），缺了直接报 -106 参数错误。
    static func bodyOf(_ action: Action, runMinutes: Int) -> [String: Any]? {
        guard action == .engineStart else { return nil }
        let minutes = max(1, min(30, runMinutes))
        // GwmClient 读的是秒，这里统一按秒传，避免两处单位不一致
        return ["operationTime": minutes * 60, "runMinutes": minutes]
    }

    /// 开空调的附加参数。
    ///
    /// 官方 APP 的空调开启不是光发一个 controlType 就完事，要把
    /// 「允许启动发动机」「运行时长」「目标温度」一起带上。
    static func acBodyOf(_ celsius: Float?) -> [String: Any] {
        TempControl.bodiesOf(celsius ?? TempControl.defaultC, zone: TempControl.zoneBoth)
    }
}
