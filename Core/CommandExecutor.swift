import Foundation

/// 远程指令执行器：下发 → 按车况轮询校验 → 给出结果反馈。
///
/// **为什么需要这一层**
/// 远控接口的返回值只是"请求受理号"，不代表车执行了。用户真正想知道的是
/// "车门到底锁上没、车窗到底关上没"。这里统一做三件事：
/// 1. **连带动作**：锁车时若车况显示车窗/天窗未关，自动追加关窗指令。
/// 2. **逐条下发、串行等待**：每条指令等受理成功再发下一条。
///    车端对并发远控的处理不可靠，同一时刻两条指令容易互相顶掉。
/// 3. **按车况验证**：下发后每 4 秒刷新一次车况，比对目标字段是否变成期望值。
///    达到就立即回报"成功"，不必等满超时。
///
/// **为什么轮询上限是 ~48 秒**
/// 车端执行（唤醒 TBOX → 下发到车 → 车执行 → 状态上报）通常 10~30 秒，
/// 地下车库信号差时会到 40 秒以上。超时后不谎报成功，而是明确告诉用户
/// "车况没变化，可能车没收到"。
@MainActor
final class CommandExecutor {

    /// 车况轮询间隔：太密伤电瓶与云端配额，太疏反馈慢
    private static let verifyInterval: TimeInterval = 4.0
    /// 总等待上限
    private static let verifyTimeout: TimeInterval = 48.0

    struct Result {
        /// 全部成功
        let success: Bool
        /// 部分成功（如锁车成功但车窗未关）
        let partial: Bool
        /// 结果说明（已组织成可直接展示的句子）
        let message: String
        /// 涉及的步骤（含被动追加的关窗）
        let steps: [CommandOutcome.Step]
        /// 车况是否最终印证成功
        let verified: Bool
    }

    /// 下发过程中的进度回调
    var onProgress: ((String) -> Void)?

    private let repo: GwmRepository
    private let alerts: StatusAlertCenter

    init(repo: GwmRepository, alerts: StatusAlertCenter = .shared) {
        self.repo = repo
        self.alerts = alerts
    }

    /// 执行一个动作。
    /// - Parameters:
    ///   - action: 语义动作
    ///   - extraBody: 额外参数（如空调温度），可为 nil
    ///   - runMinutes: 仅远程启动用：发动机运行时长（分钟）
    func run(_ action: VehicleActions.Action, extraBody: [String: Any]? = nil,
             runMinutes: Int = VehicleActions.defaultRunMinutes) async -> Result {
        var steps: [CommandOutcome.Step] = []
        var types: [String] = []
        var bodies: [[String: Any]?] = []

        // 下发前的车况快照：用于区分"本次真的关上了"和"本来就没开"
        let before = repo.lastStatus

        // ---- 空调类动作的前置闸门：车没启动就别发 ----
        if action.needsEngine {
            let v = HvacGuard.canTurnOn(before)
            guard v.allowed else {
                return Result(success: false, partial: false, message: v.message, steps: [], verified: false)
            }
        }

        // ---- 远程启动/熄火的前置闸门 ----
        if action == .engineStart {
            let v = EngineGuard.canStart(before)
            guard v.allowed else {
                return Result(success: false, partial: false, message: v.message, steps: [], verified: false)
            }
        } else if action == .engineStop {
            let v = EngineGuard.canStop(before)
            guard v.allowed else {
                return Result(success: false, partial: false, message: v.message, steps: [], verified: false)
            }
        }

        types.append(action.controlType)
        steps.append(VehicleActions.stepOf(action, celsius: tempOf(extraBody)))

        // 远程启动必须带时长参数，否则平台报 -106 参数错误
        var mainBody = extraBody
        if action == .engineStart {
            var body = VehicleActions.bodyOf(action, runMinutes: runMinutes) ?? [:]
            if let extraBody = extraBody {
                body.merge(extraBody) { _, new in new }
            }
            mainBody = body
        } else if action == .acOn {
            // 开空调必须带温度/时长/allowStartEng
            var body = VehicleActions.acBodyOf(tempOf(extraBody))
            if let extraBody = extraBody {
                body.merge(extraBody) { _, new in new }
            }
            mainBody = body
        }
        bodies.append(mainBody)

        // ---- 锁车连带关窗：基于当前车况决定 ----
        if action == .lock {
            var planned: [String] = []
            if let s = before {
                if !(CommandOutcome.sideWindowsClosed(s) == true) {
                    types.append(GwmClient.Cmd.windowClose)
                    bodies.append(nil)
                    steps.append(.init(controlType: GwmClient.Cmd.windowClose, label: "关车窗",
                                       probe: CommandOutcome.sideWindowsClosed))
                    planned.append("车窗")
                }
                if s.sunroof == true {
                    types.append(GwmClient.Cmd.skylightClose)
                    bodies.append(nil)
                    steps.append(.init(controlType: GwmClient.Cmd.skylightClose, label: "关天窗",
                                       probe: CommandOutcome.skylightClosed))
                    planned.append("天窗")
                }
            } else {
                // 车况还没拉到：不知道窗开没开，但为了让"锁车走人"这个意图
                // 真正成立，宁可多发一条关窗指令（重复关窗无副作用）
                types.append(GwmClient.Cmd.windowClose)
                bodies.append(nil)
                steps.append(.init(controlType: GwmClient.Cmd.windowClose, label: "关车窗",
                                   probe: CommandOutcome.sideWindowsClosed))
                types.append(GwmClient.Cmd.skylightClose)
                bodies.append(nil)
                steps.append(.init(controlType: GwmClient.Cmd.skylightClose, label: "关天窗",
                                   probe: CommandOutcome.skylightClosed))
            }
            if !planned.isEmpty && before != nil {
                onProgress?("检测到" + planned.joined(separator: "、") + "未关闭，一并下发")
            }
        }

        // ---- 逐条串行下发 ----
        for index in types.indices {
            let type = types[index]
            let label = labelOf(steps, type: type, index: index)
            if index > 0 { onProgress?("正在下发：\(label)…") }
            do {
                _ = try await repo.sendCommand(type, bodies[index])
                if index < types.count - 1 {
                    // 给车端一点间隔，避免两条远控在 TBOX 侧撞车
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                }
            } catch {
                let message = GwmError.friendly(error)
                if index == 0 {
                    // 主指令失败 = 整体失败
                    return Result(success: false, partial: false,
                                  message: "\(steps[0].label)下发失败：\(message)",
                                  steps: steps, verified: false)
                }
                // 连带指令失败只降级为"部分完成"
                onProgress?("\(label)下发失败，继续校验其他项")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }

        // ---- 按车况验证 ----
        return await verify(steps: steps, before: before)
    }

    private func labelOf(_ steps: [CommandOutcome.Step], type: String, index: Int) -> String {
        if let hit = steps.first(where: { $0.controlType == type }) { return hit.label }
        return index < steps.count ? steps[index].label : type
    }

    private func verify(steps: [CommandOutcome.Step], before: VehicleStatus?) async -> Result {
        let startAt = Date()
        var round = 0
        while true {
            await repo.refreshNow()
            try? await Task.sleep(nanoseconds: UInt64(Self.verifyInterval * 1_000_000_000))

            let s = repo.lastStatus
            let state = CommandOutcome.judgeAll(steps, s)
            let elapsed = Date().timeIntervalSince(startAt)
            let mainLabel = steps.first?.label ?? "指令"

            if state == .done {
                // 成功文案带上"本次真的关上的连带项"，本来就关着的不念
                let extra = CommandOutcome.sideEffects(steps: steps, before: before, after: s)
                return Result(success: true, partial: false,
                              message: mainLabel + "成功" + extra, steps: steps, verified: true)
            }
            if state == .unverifiable && round >= 2 {
                // 车况里根本没有可判断的字段（老车型字段缺失）：只能确认已下发
                let isTemp = steps.first?.label.hasPrefix("调温至") ?? false
                let note = isTemp ? "（该车型不回读设定温度，无法确认是否生效）" : "（该车型无状态可校验）"
                return Result(success: true, partial: false,
                              message: mainLabel + "：指令已下发" + note,
                              steps: steps, verified: false)
            }
            if elapsed > Self.verifyTimeout {
                let anyDone = !CommandOutcome.done(steps, s).isEmpty
                let msg = CommandOutcome.feedback(actionLabel: mainLabel, steps: steps,
                                                  status: s, timedOut: true)
                return Result(success: false, partial: anyDone, message: msg,
                              steps: steps, verified: false)
            }
            round += 1
        }
    }

    /// 从 cmdBody 里取目标温度
    private func tempOf(_ body: [String: Any]?) -> Float? {
        guard let v = body?["temperature"] as? NSNumber else { return nil }
        return v.floatValue
    }
}
