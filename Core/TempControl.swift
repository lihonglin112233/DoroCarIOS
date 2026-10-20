import Foundation

/// 空调温度设定的规划层：把「23.5℃」翻译成一条远控指令。
///
/// 协议里没有 `AIR_CONDITIONER_TEMP_SET` 这样的语义动作，只有
/// `AIR_CONDITIONER_START` 一个入口——温度必须塞进它的 `cmdBody`。
/// 这里做三件事把它变可控：
/// 1. **把猜测收在一个地方**：字段名、单位、分区都写在 `bodiesOf` 里；
/// 2. **红线留好**：不确定就等于没做，`canSet` 在车况缺失、车辆未启动、
///    温度越界时一律拒绝，宁可不发也不发错；
/// 3. **回读诚实**：`responseOf` 明确告诉上层"这次调温车况里查不到验证字段"，
///    文案就不能说"已调到 23℃"。
///
/// 温度统一按摄氏度存储与显示，华氏度只在展示层换算。
enum TempControl {

    /// 可设定下限（℃）。
    ///
    /// 17~31℃ 是官方 APP 的远程空调区间（整数档），协议侧按整数下发，
    /// 超出范围车端不认。
    static let minC: Float = 17.0
    /// 可设定上限（℃）
    static let maxC: Float = 31.0
    /// 单步：官方 APP 是整数档，0.5 只用于界面平滑，下发前取整
    static let stepC: Float = 0.5
    /// 默认值：多数车型上电后的初始设定
    static let defaultC: Float = 24.0

    /// 远程空调默认运行时长（秒），与官方 APP 一致
    static let defaultDurationSeconds = 15 * 60

    /// 空调分区
    enum Zone: String {
        case driver = "DRIVER"
        case passenger = "PASSENGER"
        /// 主副驾同温（同步模式）
        case both = "BOTH"

        var label: String {
            switch self {
            case .driver: return "主驾"
            case .passenger: return "副驾"
            case .both: return "全车"
            }
        }

        /// 全车 → 主驾 → 副驾 → 全车
        var next: Zone {
            switch self {
            case .both: return .driver
            case .driver: return .passenger
            case .passenger: return .both
            }
        }
    }

    static let zoneBoth = Zone.both.rawValue

    /// 空调指令体的字段，来自官方 APP 反向实测：
    /// ```
    /// controlType = AIR_CONDITIONER_START
    /// cmdBody = { allowStartEng: 1, operationTime: 900, temperature: 24 }
    /// ```
    private static let keyTemp = "temperature"
    /// 允许远程启动发动机来带动空调（燃油车必需，否则车没着空调不工作）
    private static let allowStartEng = 1

    // MARK: - 规格

    static func inRange(_ celsius: Float) -> Bool {
        celsius >= minC - 0.001 && celsius <= maxC + 0.001
    }

    /// 按 0.5℃ 取整并夹到区间内
    static func normalize(_ celsius: Float) -> Float {
        var v = (celsius / stepC).rounded() * stepC
        v = max(minC, min(maxC, v))
        // 避免 22.500000001 这种浮点尾巴
        return (v * 10).rounded() / 10.0
    }

    /// 升一档，已到顶则不变
    static func up(_ celsius: Float) -> Float {
        normalize(normalize(celsius) + stepC)
    }

    /// 降一档，到底则不变
    static func down(_ celsius: Float) -> Float {
        normalize(normalize(celsius) - stepC)
    }

    static func atMax(_ celsius: Float) -> Bool { normalize(celsius) >= maxC }
    static func atMin(_ celsius: Float) -> Bool { normalize(celsius) <= minC }

    // MARK: - 前置闸门

    struct Verdict {
        let allowed: Bool
        let message: String
    }

    /// 能否调温。复用 `HvacGuard.canTurnOn` 的"车辆必须已启动"判断——
    /// 调温本质也是空调附件动作，车没启动时下发同样会被车端丢弃。
    static func canSet(_ status: VehicleStatus?, _ celsius: Float) -> Verdict {
        guard inRange(celsius) else {
            return Verdict(allowed: false, message: String(format: "温度超出可调范围（%.0f~%.0f℃）", minC, maxC))
        }
        // 车没启动 / 车况缺失，交给同一个空调闸门判定，避免两套口径
        let hvac = HvacGuard.canTurnOn(status)
        return Verdict(allowed: hvac.allowed, message: hvac.message)
    }

    // MARK: - 报文

    /// 组装开空调 + 设定温度的 cmdBody。
    ///
    /// 为什么用 `AIR_CONDITIONER_START` 而不是某个温度指令：协议里没有独立的
    /// 温度 controlType，官方 APP 也是"开机时带上目标温度"。
    /// 若空调已经开着，重复下发 START 是无害的（幂等），顺带把温度改掉。
    static func bodiesOf(_ celsius: Float, zone: String) -> [String: Any] {
        // 协议侧温度是整数档，界面的 0.5 步进只是手感，下发前取整
        let t = Int(normalize(celsius).rounded())
        return [
            keyTemp: t,
            "allowStartEng": allowStartEng,
            "operationTime": defaultDurationSeconds,
        ]
    }

    /// 该动作的展示文案，如「调温至 23°C」
    static func labelOf(_ celsius: Float) -> String {
        "调温至 " + format(celsius)
    }

    // MARK: - 展示

    /// 摄氏度 → 展示串（带 °C）
    static func format(_ celsius: Float) -> String {
        format(celsius, fahrenheit: false)
    }

    /// 摄氏度 → 展示串。fahrenheit 为 true 时换算成华氏度（车机配置为 °F 时用）。
    static func format(_ celsius: Float, fahrenheit: Bool) -> String {
        let v = normalize(celsius)
        let whole = abs(v - v.rounded()) < 0.001
        if fahrenheit {
            let f = v * 9 / 5 + 32
            // 华氏度保留整数，避免 73.4°F 这种噪声
            return String(format: "%.0f°F", f)
        }
        return String(format: whole ? "%.0f°C" : "%.1f°C", v)
    }

    static func zoneLabel(_ zone: String) -> String {
        Zone(rawValue: zone)?.label ?? Zone.both.label
    }

    // MARK: - 回读

    struct Response {
        /// 能否从车况验证"设定温度真的变成了目标值"
        let verifiable: Bool
        /// 说明（给界面/日志用）
        let note: String
    }

    /// 车况里有没有回读的设定温度。
    ///
    /// `VehicleStatus` 目前只有 `cabinTemp`（车内实测温度），多数车型没有
    /// "空调设定温度"字段。实测温度受阳光、车窗、乘员影响，不能拿来判断
    /// 设定值是否生效——所以这里如实返回不可验证。
    static func responseOf(_ status: VehicleStatus?) -> Response {
        guard let status = status else {
            return Response(verifiable: false, note: "车况还没拉到，无法验证温度")
        }
        if status.acTempSet == nil {
            return Response(verifiable: false, note: "该车型不上报空调设定温度，只能确认已下发")
        }
        return Response(verifiable: true, note: "可验证")
    }
}
