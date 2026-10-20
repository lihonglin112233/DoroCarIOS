import Foundation

/// 判定结论
enum CommandState {
    /// 车况已变成期望值
    case done
    /// 车况还没变（可能车端还在执行，也可能没收到）
    case pending
    /// 该指令没有可观测状态，无法用车辆情况判定
    case unverifiable
}

/// 一句「指令结果」的判定：车到底做了没有。
///
/// **为什么不能只看接口回执**：远控接口返回的是 seqNo（请求受理号），
/// 不是执行结果；gtsp 平台的 T5 结果接口更是查不到。所以判定一律以
/// 「车况里的目标字段有没有变成期望值」为准——这才是用户眼里"车到底锁没锁"。
enum CommandOutcome {

    /// 车况探针：把车况映射成一个可比较的值。返回 nil 表示车况里没有这项数据。
    struct Step {
        let controlType: String
        let label: String
        let probe: Probe?
    }

    typealias Probe = (VehicleStatus?) -> Bool?

    // MARK: - 探针

    static let locked: Probe = { $0?.doorsLocked }
    static let windowsClosed: Probe = { s in s.map { !$0.hasOpenWindow } }

    /// 侧窗（不含天窗）是否全关
    static let sideWindowsClosed: Probe = { s in
        guard let s = s else { return nil }
        if s.windowFrontLeft == nil && s.windowFrontRight == nil
            && s.windowRearLeft == nil && s.windowRearRight == nil {
            return nil
        }
        return !(s.windowFrontLeft == true) && !(s.windowFrontRight == true)
            && !(s.windowRearLeft == true) && !(s.windowRearRight == true)
    }

    /// 天窗是否已关闭
    static let skylightClosed: Probe = { s in
        guard let s = s, let sunroof = s.sunroof else { return nil }
        return !sunroof
    }

    static let engineRunning: Probe = { $0.map { $0.isEngineRunning } }
    static let engineOff: Probe = { $0.map { !$0.isEngineRunning } }
    static let acOn: Probe = { $0?.airConditioner }
    static let acOff: Probe = { s in
        guard let s = s, let ac = s.airConditioner else { return nil }
        return !ac
    }
    static let frontDefrostOn: Probe = { $0?.frontDefroster }
    static let rearDefrostOn: Probe = { $0?.rearDefroster }
    static let steerHeatOn: Probe = { $0?.steerWheelHeat }
    static let trunkOpen: Probe = { $0?.doorTrunk }

    /// 空调设定温度是否已到目标值。
    ///
    /// 读的是 `acTempSet`（设定值回读），不是 `cabinTemp`（车内实测温度）——
    /// 后者受阳光、开窗、乘员影响，达不到目标温度不代表设定没生效。
    /// 车端未上报时返回 nil，判定会落到 unverifiable，文案只敢说"已下发"。
    static func tempAt(_ celsius: Float) -> Probe {
        let target = TempControl.normalize(celsius)
        return { s in
            guard let s = s, let set = s.acTempSet else { return nil }
            // 允许 0.5℃ 的量化误差
            return abs(set - Double(target)) <= Double(TempControl.stepC) + 0.001
        }
    }

    // MARK: - 判定

    static func judge(_ step: Step, _ status: VehicleStatus?) -> CommandState {
        guard let probe = step.probe else { return .unverifiable }
        guard let v = probe(status) else { return .unverifiable }
        return v ? .done : .pending
    }

    /// 判定整批（锁车+关窗+关天窗）是否全部达成
    static func judgeAll(_ steps: [Step], _ status: VehicleStatus?) -> CommandState {
        var anyPending = false
        var anyVerifiable = false
        for st in steps {
            switch judge(st, status) {
            case .pending: anyPending = true
            case .done: anyVerifiable = true
            case .unverifiable: break
            }
        }
        if anyPending { return .pending }
        return anyVerifiable ? .done : .unverifiable
    }

    /// 还没达成的步骤（用于播报"车窗还没关上"这种部分成功）
    static func pending(_ steps: [Step], _ status: VehicleStatus?) -> [Step] {
        steps.filter { judge($0, status) == .pending }
    }

    /// 已达成且有状态可查的步骤
    static func done(_ steps: [Step], _ status: VehicleStatus?) -> [Step] {
        steps.filter { judge($0, status) == .done }
    }

    // MARK: - 文案

    /// 结果文案：按"实际车况"如实报告，不是按"我发了什么指令"。
    static func feedback(actionLabel: String, steps: [Step], status: VehicleStatus?,
                         timedOut: Bool) -> String {
        guard let main = steps.first else { return actionLabel + "：已下发" }

        if judgeAll(steps, status) == .done {
            return actionLabel + "成功" + detail(steps, status)
        }
        guard let status = status else { return actionLabel + "：车况暂时读不到" }

        let pendingSteps = pending(steps, status)
        let doneSteps = done(steps, status)

        // 主指令还没达成时，不能因为连带项"已经关着"就报部分完成。
        // 用户下的是"锁车"，锁没锁上就是没成，此时只该说"在等 / 可能没收到"。
        let mainState = judge(main, status)
        let mainDone = mainState == .done
        let mainUnverifiable = mainState == .unverifiable
        if !mainDone || doneSteps.isEmpty {
            if mainUnverifiable && !timedOut {
                return actionLabel + "已下发（该车型不回读此项，无法确认是否生效）"
            }
            return timedOut
                ? actionLabel + "未生效：车况没有变化，可能车没收到指令"
                : actionLabel + "已下发，车况还没变化，等待车端执行…"
        }

        // 部分成功：锁上了但窗没关
        var msg = actionLabel + "部分完成：" + labels(doneSteps) + "已完成"
        if !pendingSteps.isEmpty {
            msg += "，但" + labels(pendingSteps) + "还没完成"
        }
        return msg
    }

    private static func detail(_ steps: [Step], _ status: VehicleStatus?) -> String {
        let d = done(steps, status)
        guard d.count > 1 else { return "" }
        return "（" + labels(d) + "）"
    }

    private static func labels(_ steps: [Step]) -> String {
        steps.map(\.label).joined(separator: "、")
    }

    /// 生成"锁车已成功，另外还关好了车窗和天窗"这类补充说明。
    ///
    /// 连带项在用户下达锁车指令那一刻可能就已经是关着的（本来就没开），
    /// 此时它"已完成"没有任何信息量，念出来反而像在汇报流水账。
    /// 所以只列本次真正发生了变化的连带项。
    static func sideEffects(steps: [Step], before: VehicleStatus?,
                            after: VehicleStatus?) -> String {
        guard before != nil, after != nil, steps.count > 1 else { return "" }
        var changed: [String] = []
        for i in 1..<steps.count {
            guard let probe = steps[i].probe else { continue }
            let was = probe(before)
            let now = probe(after)
            guard let nowValue = now else { continue }
            // 之前在"未达成"、现在达成 = 本次确实关上了
            if was != true && nowValue == true {
                changed.append(steps[i].label)
            }
        }
        guard !changed.isEmpty else { return "" }
        return "，另外还完成了" + changed.joined(separator: "、")
    }
}
