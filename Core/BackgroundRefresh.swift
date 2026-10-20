import Foundation
import BackgroundTasks

/// 后台刷新。
///
/// Android 版用前台服务保证每 60 秒轮询一次；iOS **没有等价能力**：
/// 应用退到后台后很快被挂起，定时器停止。这里用 `BGAppRefreshTask` 尽力而为：
/// 系统根据用户使用习惯决定何时唤醒（通常一天几次到几十次不定），
/// 每次唤醒允许执行约 30 秒。
///
/// 现实影响：**后台状态下"实时"提醒会明显弱于 Android 版**。
/// 这不是代码问题，是平台策略。前台使用不受影响。
enum BackgroundRefresh {

    static let taskIdentifier = "com.dorocar.car.refresh"

    /// 在 App 启动时调用，注册后台任务处理器
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            // 注册回调在后台队列，跳回主线程处理（仓库层是 @MainActor）
            Task { @MainActor in
                handle(refreshTask)
            }
        }
    }

    /// 申请一次后台刷新
    static func schedule(after seconds: Int) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // 系统会把 earliestBeginDate 当作"不早于"的建议值
        request.earliestBeginDate = Date(timeIntervalSinceNow: TimeInterval(max(60, seconds)))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // 模拟器、未开启 Background Modes、超配额等情况都会失败，
            // 失败不影响前台轮询，不向用户报错。
            #if DEBUG
            print("[BackgroundRefresh] submit failed: \(error)")
            #endif
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    @MainActor
    private static func handle(_ task: BGAppRefreshTask) {
        // 先排下一次，保证链条不断
        schedule(after: GwmRepository.shared.pollIntervalSeconds)

        let work = Task { @MainActor in
            if Task.isCancelled {
                task.setTaskCompleted(success: false)
                return
            }
            await GwmRepository.shared.backgroundRefresh()
            task.setTaskCompleted(success: !Task.isCancelled)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }
}
