import Foundation

/// 车况模型。
///
/// 字段名与 Android 版一一对应，[`VehicleStatus.parse`] 负责把服务端
/// `getLastStatus` 返回的原始 JSON 映射过来。
///
/// 协议里各个字段以字符串 "0"/"1" 表达状态，且**语义不统一**：
/// - 门锁：`"0"` = 已锁（反向语义）
/// - 车门：`"1"` = 打开
/// - 车窗：非关闭值即为开（全开/半开/翘起都算开）
struct VehicleStatus: Equatable {
    var acquisitionTime: String?
    var gpsSwitchOn: String?
    var tboxStatus: String?
    var fuelGauge: String?

    // 油电
    var fuelVolume: Double?
    var fuelRange: Double?
    var batteryPercent: Double?
    var evRange: Double?
    var mileage: Double?
    var avgFuelConsumption: Double?
    var avgEnergyConsumption: Double?
    var batteryVoltage: Double?

    // 温度
    var cabinTemp: Double?
    /// 空调设定温度（多数车型不上报）
    var acTempSet: Double?

    // 动力
    var engineState: String?
    var powerState: String?
    var gear: String?

    // 门锁 / 车门
    var doorsLocked: Bool?
    var doorFrontLeft: Bool?
    var doorFrontRight: Bool?
    var doorRearLeft: Bool?
    var doorRearRight: Bool?
    var doorTrunk: Bool?
    var hood: Bool?

    // 车窗 / 天窗
    var windowFrontLeft: Bool?
    var windowFrontRight: Bool?
    var windowRearLeft: Bool?
    var windowRearRight: Bool?
    var sunroof: Bool?
    var windshieldHeat: Bool?

    // 空调
    var airConditioner: Bool?
    var acAutoMode: Bool?
    var frontDefroster: Bool?
    var rearDefroster: Bool?

    // 灯光
    var lowBeam: Bool?
    var highBeam: Bool?

    // 座椅 / 方向盘
    var steerWheelHeat: Bool?
    var cabinClean: Bool?
    var seatHeatDriver: Bool?
    var seatVentDriver: Bool?
    var seatHeatPassenger: Bool?
    var seatVentPassenger: Bool?
    var seatHeatRearLeft: Bool?
    var seatHeatRearRight: Bool?

    // 胎压
    var tirePressureFl: Double?
    var tirePressureFr: Double?
    var tirePressureRl: Double?
    var tirePressureRr: Double?
    var tireAlarmFl: Bool?
    var tireAlarmFr: Bool?
    var tireAlarmRl: Bool?
    var tireAlarmRr: Bool?
    var tireTempFl: Double?
    var tireTempFr: Double?
    var tireTempRl: Double?
    var tireTempRr: Double?

    // 安全
    var antitheft: Bool?
    var oilAlarm: Bool?

    init() {}

    // MARK: - 派生状态

    /// 引擎是否在运行/启动中
    var isEngineRunning: Bool {
        engineState == "1" || engineState == "2"
    }

    var engineText: String {
        switch engineState {
        case nil: return "未知"
        case "0": return "熄火"
        case "1": return "启动中"
        case "2": return "运行中"
        default: return "未知"
        }
    }

    /// 是否有任一车门/后备箱/引擎盖打开
    var hasOpenDoor: Bool {
        Self.isTrue(doorFrontLeft) || Self.isTrue(doorFrontRight)
            || Self.isTrue(doorRearLeft) || Self.isTrue(doorRearRight)
            || Self.isTrue(doorTrunk) || Self.isTrue(hood)
    }

    /// 是否有任车窗/天窗打开
    var hasOpenWindow: Bool {
        Self.isTrue(windowFrontLeft) || Self.isTrue(windowFrontRight)
            || Self.isTrue(windowRearLeft) || Self.isTrue(windowRearRight)
            || Self.isTrue(sunroof)
    }

    /// 是否有胎压异常
    var hasTireAlarm: Bool {
        Self.isTrue(tireAlarmFl) || Self.isTrue(tireAlarmFr)
            || Self.isTrue(tireAlarmRl) || Self.isTrue(tireAlarmRr)
    }

    /// 车况是否为空（未拿到任何有效数据）
    var isEmpty: Bool {
        engineState == nil && mileage == nil && fuelRange == nil
            && doorsLocked == nil && tirePressureFl == nil
    }

    private static func isTrue(_ b: Bool?) -> Bool { b == true }

    // MARK: - 解析

    /// 解析 getLastStatus 返回的 data 对象。
    static func parse(_ raw: [String: Any]?) -> VehicleStatus {
        let s = VehicleStatus()
        guard let raw = raw, !raw.isEmpty else { return s }

        let data = (GwmCrypto.normalizeKeys(raw) as? [String: Any]) ?? [:]
        let vs = (data["vehiclestatusinfo"] as? [String: Any]) ?? [:]

        // 顶级字段（v3.0 / gtsp 把油表、GPS 开关、TBOX 挪进了 vehicleStatusInfo）
        s.acquisitionTime = asString(first(data["acquisitiontime"], vs["acquisitiontime"]))
        s.gpsSwitchOn = asString(first(vs["gpsswitchon"], data["gpsswitchon"]))
        s.tboxStatus = asString(first(data["tboxstatus"], vs["tboxstate"], vs["tboxstatus"]))
        s.fuelGauge = asString(first(vs["oilqty"], data["oilqty"]))

        // 油电
        s.fuelVolume = parseValue(vs["remainoil"])
        s.fuelRange = parseValue(vs["premileage"])
        s.batteryPercent = parseValue(vs["remainelectricpercent"])
        s.mileage = parseValue(vs["mileage"])
        if let charge = vs["charge"] as? [String: Any] {
            s.evRange = parseValue(charge["evcontnsdistance"])
        }
        s.avgFuelConsumption = parseValue(vs["avgfuelconse"])
        s.avgEnergyConsumption = parseValue(vs["avrgegycns"])
        s.batteryVoltage = parseValue(vs["bmspackvolt"])

        // 温度（gtsp 改名 inCarTemperature）
        s.cabinTemp = parseValue(first(vs["cbntemp"], vs["incartemperature"]))

        // 空调设定温度（目前协议未上报，键名先预埋）
        // 注意不能拿 cabinTemp 顶替：实测温度不等于设定值
        var setTemp = parseValue(first(vs["actemp"], vs["settemp"], vs["hvactemp"],
                                       vs["drvtemp"], vs["drvtemptarget"]))
        // 部分车型回传的是 ×10 整数（245 表示 24.5℃）
        if let t = setTemp, t > 60 { setTemp = t / 10.0 }
        // 落在合理区间才认，防止把别的字段误读成温度
        if let t = setTemp, t < 10 || t > 40 { setTemp = nil }
        s.acTempSet = setTemp

        // 引擎 / 档位（gtsp 档位改名 gearSts）
        s.engineState = asString(vs["enginests"])
        s.powerState = asString(vs["power"])
        s.gear = asString(first(vs["hcugearsts"], vs["gearsts"]))

        // 门锁：字段 "0"=已锁（反向语义）
        s.doorsLocked = toBoolInverted(vs["escllocksts"])
        if s.doorsLocked == nil, let door0 = vs["door"] as? [String: Any] {
            s.doorsLocked = toBoolInverted(door0["maindrvedoorlocksts"])
        }

        // 车门："1"=开
        if let door = vs["door"] as? [String: Any] {
            s.doorFrontLeft = toBool(door["maindrvedoorsts"])
            s.doorFrontRight = toBool(door["vicedoorsts"])
            s.doorRearLeft = toBool(door["lbdoorsts"])
            s.doorRearRight = toBool(door["rbdoorsts"])
            s.doorTrunk = toBool(first(door["backdoorsts"], door["tailgateopenupsts"]))
        }
        s.hood = toBool(vs["enginedoorsts"])

        // 车窗 / 天窗：非关闭值即为开
        if let windows = vs["windows"] as? [String: Any] {
            s.windowFrontLeft = windowPosToBool(windows["lfwinposnsts"], closed: "1")
            s.windowFrontRight = windowPosToBool(windows["rfwinposnsts"], closed: "1")
            s.windowRearLeft = windowPosToBool(windows["lbwinposnsts"], closed: "1")
            s.windowRearRight = windowPosToBool(windows["rbwinposnsts"], closed: "1")
            s.sunroof = windowPosToBool(windows["skylightsts"], closed: "3")
            s.windshieldHeat = toBool(windows["fwinheatsts"])
        }

        // 空调 / 除霜（gtsp 自动模式改名 acAutoModeSts）
        s.airConditioner = toBool(vs["airconditionsts"])
        s.acAutoMode = toBool(first(vs["airconditionautomodenasts"], vs["acautomodests"]))
        s.frontDefroster = toBool(vs["frontfrost"])
        s.rearDefroster = toBool(vs["backfrost"])

        // 灯光
        if let lighting = vs["lighting"] as? [String: Any] {
            s.lowBeam = toBool(lighting["nearbeamsts"])
            s.highBeam = toBool(lighting["farbeamsts"])
        }

        // 座椅 / 方向盘（gtsp 方向盘加热改名 steerWheelHeatDst）
        s.steerWheelHeat = toBool(first(vs["steerwheelheat"], vs["steerwheelheatdsts"]))
        s.cabinClean = toBool(vs["cabinclean"])
        if let seat = vs["seat"] as? [String: Any] {
            s.seatHeatDriver = toBool(seat["maindriverseatheatsts"])
            s.seatVentDriver = toBool(seat["maindriverseatventsts"])
            s.seatHeatPassenger = toBool(seat["viceseatheatsts"])
            s.seatVentPassenger = toBool(seat["viceseatventsts"])
            s.seatHeatRearLeft = toBool(seat["lbseatheatsts"])
            s.seatHeatRearRight = toBool(seat["rbseatheatsts"])
        }

        // 胎压（lf=前左 rf=前右 lb=后左 rb=后右）
        if let tire = vs["tirepress"] as? [String: Any] {
            s.tirePressureFl = parseValue(tire["lftirepressval"])
            s.tirePressureFr = parseValue(tire["rftirepressval"])
            s.tirePressureRl = parseValue(tire["lbtirepressval"])
            s.tirePressureRr = parseValue(tire["rbtirepressval"])
            // gtsp 把报警字段改名为 *TirePressSts（旧名 *TirePressIndcrSts）
            s.tireAlarmFl = toBool(first(tire["lftirepressindcrsts"], tire["lftirepresssts"]))
            s.tireAlarmFr = toBool(first(tire["rftirepressindcrsts"], tire["rftirepresssts"]))
            s.tireAlarmRl = toBool(first(tire["lbtirepressindcrsts"], tire["lbtirepresssts"]))
            s.tireAlarmRr = toBool(first(tire["rbtirepressindcrsts"], tire["rbtirepresssts"]))
        }
        if let tireTemp = vs["tiretemp"] as? [String: Any] {
            s.tireTempFl = parseValue(tireTemp["lftiretempval"])
            s.tireTempFr = parseValue(tireTemp["rftiretempval"])
            s.tireTempRl = parseValue(tireTemp["lbtiretempval"])
            s.tireTempRr = parseValue(tireTemp["rbtiretempval"])
        }

        // 安全
        s.antitheft = toBool(vs["vehicleantitheftstatus"])
        s.oilAlarm = toBool(vs["oilalarmsts"])

        return s
    }

    // MARK: - 基础工具

    static func asString(_ o: Any?) -> String? {
        guard let o = o else { return nil }
        if let s = o as? String {
            let t = s.trimmed
            return t.isEmpty ? nil : t
        }
        if let n = o as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            if d == d.rounded() { return String(n.int64Value) }
        }
        let s = String(describing: o)
        return s.isEmpty ? nil : s
    }

    /// 返回第一个非 nil 的值（新旧网关字段名/层级兜底）
    static func first(_ values: Any?...) -> Any? {
        for v in values where v != nil { return v }
        return nil
    }

    /// 解析 `"273,kPa"` / `"77,L"` 这种「值,单位」格式，取逗号前数值。
    /// `"--"` / nil / 空串 视为未知。
    static func parseValue(_ value: Any?) -> Double? {
        guard let value = value else { return nil }
        if value is NSNull { return nil }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            return n.doubleValue
        }
        guard let raw = value as? String else { return nil }
        let s = raw.trimmed
        if s.isEmpty || s == "--" || s.lowercased() == "null" { return nil }
        let head = s.split(separator: ",").first.map(String.init) ?? s
        return Double(head.trimmed)
    }

    /// 字符串状态转 bool：`"1"`=开，`"0"`=关，其它=未知。
    static func toBool(_ value: Any?) -> Bool? {
        toBool(value, trueValue: "1", falseValue: "0")
    }

    static func toBool(_ value: Any?, trueValue: String, falseValue: String) -> Bool? {
        guard let s = statusText(value) else { return nil }
        if s == trueValue { return true }
        if s == falseValue { return false }
        return nil
    }

    /// 反向语义：`"0"`=true（已锁/已关），`"1"`=false。
    static func toBoolInverted(_ value: Any?) -> Bool? {
        guard let s = statusText(value) else { return nil }
        if s == "0" { return true }
        if s == "1" { return false }
        return nil
    }

    /// 车窗/天窗多态值：等于 closed 为关，其余任何有效值都算开
    /// （全开、半开、翘起等中间态一律视为「开」）。
    static func windowPosToBool(_ value: Any?, closed: String) -> Bool? {
        guard let s = statusText(value) else { return nil }
        return s == closed ? false : true
    }

    private static func statusText(_ value: Any?) -> String? {
        guard let value = value else { return nil }
        if value is NSNull { return nil }
        if let b = value as? Bool { return b ? "1" : "0" }
        var s: String
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            s = (d == d.rounded()) ? String(n.int64Value) : n.stringValue
        } else if let str = value as? String {
            s = str.trimmed
        } else {
            s = String(describing: value).trimmed
        }
        if s.isEmpty || s == "--" || s.lowercased() == "null" { return nil }
        return s
    }

    // MARK: - 摘要文案

    /// 供 UI 展示的「车门/车窗/锁」摘要
    var securitySummary: String {
        var parts: [String] = []
        parts.append(doorsLocked == nil ? "门锁未知" : (doorsLocked! ? "已锁车" : "未锁车"))
        if hasOpenDoor { parts.append("有车门未关") }
        if hasOpenWindow { parts.append("有车窗未关") }
        if hasTireAlarm { parts.append("胎压异常") }
        return parts.joined(separator: " · ")
    }

    /// 调试用一行摘要
    var summary: String {
        [
            "引擎=\(engineText)",
            "续航=\(fuelRange.map { "\($0)km" } ?? "-")",
            "油量=\(fuelVolume.map { "\($0)L" } ?? "-")",
            "里程=\(mileage.map { "\($0)km" } ?? "-")",
            "车门锁=\(doorsLocked.map { $0 ? "已锁" : "未锁" } ?? "-")",
            "车门开=\(hasOpenDoor)",
            "窗开=\(hasOpenWindow)",
        ].joined(separator: " ")
    }
}
