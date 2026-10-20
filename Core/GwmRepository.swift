import Foundation

/// 车辆数据仓库：统一调度所有网络操作，缓存车况，驱动后台轮询。
///
/// **并发模型**
/// - 所有网络调用走同一个串行队列 —— token 刷新是「单次轮换」的，
///   并发刷新会互相顶掉，必须串行；
/// - 回调统一切回主线程，UI 层不用关心线程；
/// - 轮询任务持有单例句柄，避免慢网络下堆积请求。
///
/// **轮询策略**
/// 前台默认 60 秒一次（官方网关有华为云 WAF，30 秒以下容易被拦）。
/// 连续失败时指数退避到最长 10 分钟，成功后立即恢复常态；
/// 认证彻底失效（refreshToken 也过期）则停止轮询并标记需要重新登录。
///
/// > iOS 限制：应用进入后台后被系统挂起，定时器不会继续跑。真正的后台刷新
/// > 依赖 `BGAppRefreshTask`（见 `BackgroundRefresh`），由系统决定触发时机。
@MainActor
final class GwmRepository: ObservableObject {

    enum SessionState {
        /// 没有任何凭据
        case loggedOut
        /// 有凭据但正在续期
        case restoring
        /// 完整可用
        case active
        /// 凭据存在但续期失败，需要重新短信登录
        case expired
    }

    struct Listener {
        var onLoginStateChanged: ((Bool) -> Void)?
        var onStatusUpdated: ((VehicleStatus?, String?) -> Void)?
        var onRefreshing: ((Bool) -> Void)?
        var onReauthRequired: ((String) -> Void)?
    }

    // MARK: - 单例

    static let shared = GwmRepository()

    // MARK: - 存储键

    private enum Keys {
        static let selectedVin = "doro_selected_vin"
        static let pollEnabled = "doro_poll_enabled"
        static let pollInterval = "doro_poll_interval"
        static let remoteEnabled = "doro_remote_enabled"
    }

    static let minInterval = 30
    static let defaultInterval = 60
    private static let maxBackoffSeconds = 10 * 60

    // MARK: - 状态

    private let defaults = UserDefaults.standard
    private let client = GwmClient()

    private var lastVehicles: [GwmVehicle]?
    private var consecutiveFailures = 0
    private var pollTask: Task<Void, Never>?
    private var pollScheduled = false
    private var restoringTask: Task<Void, Never>?

    // MARK: - 对外可读状态（@Published 驱动 UI）

    @Published private(set) var lastStatus: VehicleStatus?
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdateAt: Date?
    @Published private(set) var sessionState: SessionState = .loggedOut
    @Published private(set) var sessionMessage: String?
    @Published private(set) var loggedIn = false
    @Published private(set) var vehicles: [GwmVehicle] = []
    @Published private(set) var refreshing = false
    @Published private(set) var phone = ""
    @Published private(set) var platform = ""

    private var listener = Listener()

    private init() {
        // 凭据在首次异步恢复时读取，构造函数保持轻量——
        // @MainActor 类型不能在 init 里做跨 actor 的 await。
        if CredentialStore.hasCredentials() {
            sessionState = .restoring
        } else {
            sessionState = .loggedOut
        }
    }

    /// 启动时调用一次：恢复 Keychain 里的会话并静默续期。
    func start() async {
        guard sessionState == .restoring else { return }
        guard let restored = CredentialStore.loadState() else {
            sessionState = .loggedOut
            return
        }
        await client.applyState(restored)
        await restoreSessionQuietly()
    }

    func setListener(_ l: Listener) {
        listener = l
    }

    // MARK: - 静默续期

    /// 静默续期：不需要验证码，直接用 refreshToken 换新的短命会话。
    ///
    /// 这是「登录过一次就不再要求登录」的实现核心。只有 refreshToken
    /// 本身被吊销时才会走到 expired，让用户重新登录。
    private func restoreSessionQuietly() async {
        let snap = await client.loginSnapshot
        if snap.loggedIn {
            // 存下来的会话仍然完整可用（绝大多数情况），直接进入可用态
            sessionState = .active
            sessionMessage = nil
            notifyLoginState()
            startPolling()
            return
        }
        guard snap.hasRefreshable else {
            // 只有 gToken 之类的残缺状态：续不了，按过期处理
            sessionState = .expired
            sessionMessage = "登录凭据不完整，需要重新验证"
            notifyLoginState()
            notifyReauth("登录凭据不完整，请重新用短信验证码登录")
            return
        }
        let ok = await client.reviveSessionQuietly()
        if ok {
            await persistQuietly()
            sessionState = .active
            sessionMessage = nil
            notifyLoginState()
            startPolling()
        } else {
            sessionState = .expired
            sessionMessage = "登录已过期，需要重新验证一次"
            notifyLoginState()
            notifyReauth("登录已过期，请重新用短信验证码登录")
        }
    }

    /// 任何一次成功请求都意味着会话确实可用。
    ///
    /// 用于纠正「状态机还停在 restoring/expired、但实际上已经能正常调通」的情况，
    /// 避免界面因为一个过时的状态标记而白白显示登录框。
    private func markSessionActiveIfNeeded() async {
        let snap = await client.loginSnapshot
        if sessionState != .active && snap.loggedIn {
            sessionState = .active
            sessionMessage = nil
            notifyLoginState()
        }
    }

    private func notifyLoginState() {
        let value = loggedIn
        listener.onLoginStateChanged?(value)
    }

    private func refreshLoginFlag() async {
        let snap = await client.loginSnapshot
        if loggedIn != snap.loggedIn {
            loggedIn = snap.loggedIn
        }
        if phone != snap.phone { phone = snap.phone }
    }

    func addListener(_ l: Listener) {
        // 只保留一个监听者（单窗口 App），合并字段避免覆盖
        if let f = l.onLoginStateChanged { listener.onLoginStateChanged = f }
        if let f = l.onStatusUpdated { listener.onStatusUpdated = f }
        if let f = l.onRefreshing { listener.onRefreshing = f }
        if let f = l.onReauthRequired { listener.onReauthRequired = f }
    }

    private func notifyStatus(_ status: VehicleStatus?, _ error: String?) {
        lastStatus = status
        lastError = error
        listener.onStatusUpdated?(status, error)
    }

    private func setRefreshing(_ value: Bool) {
        refreshing = value
        listener.onRefreshing?(value)
    }

    private func notifyReauth(_ reason: String) {
        listener.onReauthRequired?(reason)
    }

    // MARK: - 配置

    var selectedVin: String? {
        get { defaults.string(forKey: Keys.selectedVin) }
        set { defaults.set(newValue, forKey: Keys.selectedVin) }
    }

    var selectedVehicle: GwmVehicle? {
        guard let vin = selectedVin else { return nil }
        return vehicles.first { $0.vin.caseInsensitiveCompare(vin) == .orderedSame }
    }

    func platformOf(_ vin: String?) async -> String {
        await client.cachedPlatform(vin ?? selectedVin)
    }

    /// 切换当前车辆
    func selectVehicle(_ v: GwmVehicle) {
        selectedVin = v.vin
        lastStatus = nil
        platform = v.platform
        Task {
            await syncPlatform()
            await refreshNow()
        }
    }

    func syncPlatform() async {
        let p = await client.cachedPlatform(selectedVin)
        if platform != p { platform = p }
    }

    var isPollEnabled: Bool {
        defaults.object(forKey: Keys.pollEnabled) as? Bool ?? true
    }

    func setPollEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.pollEnabled)
        if enabled { startPolling() } else { stopPolling() }
    }

    var pollIntervalSeconds: Int {
        defaults.object(forKey: Keys.pollInterval) as? Int ?? Self.defaultInterval
    }

    func setPollIntervalSeconds(_ seconds: Int) {
        defaults.set(max(Self.minInterval, min(3600, seconds)), forKey: Keys.pollInterval)
    }

    var isRemoteEnabled: Bool {
        defaults.object(forKey: Keys.remoteEnabled) as? Bool ?? true
    }

    func setRemoteEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.remoteEnabled)
    }

    // MARK: - 登录

    func requestSmsCode(_ phone: String) async throws {
        try await client.requestSmsCode(phone)
        await refreshLoginFlag()
    }

    /// 短信登录，成功后返回车辆列表并自动选中第一辆。
    func loginSms(_ phone: String, _ code: String) async throws -> [GwmVehicle] {
        // 注意：这里不要再调 requestSmsCode —— 会重新下发验证码并让用户手上这个失效
        await client.setPhone(phone)
        let list = try await client.loginSms(code)
        try await afterLogin(list)
        return list
    }

    /// 密码登录（免验证码），成功后返回车辆列表并自动选中第一辆。
    func loginPassword(_ phone: String, _ password: String) async throws -> [GwmVehicle] {
        let list = try await client.loginPassword(phone, password)
        try await afterLogin(list)
        return list
    }

    private func afterLogin(_ list: [GwmVehicle]) async throws {
        vehicles = list
        if list.count == 1 {
            selectedVin = list[0].vin
        }
        try await persist()
        consecutiveFailures = 0
        sessionState = .active
        sessionMessage = nil
        await refreshLoginFlag()
        notifyLoginState()
        startPolling()
    }

    /// 退出登录：清空凭据与缓存。
    func logout() {
        stopPolling()
        Task {
            CredentialStore.clear()
            await client.clearSession()
            sessionState = .loggedOut
            sessionMessage = nil
            lastStatus = nil
            lastError = nil
            lastUpdateAt = nil
            vehicles = []
            platform = ""
            selectedVin = nil
            await refreshLoginFlag()
            notifyLoginState()
            listener.onStatusUpdated?(nil, nil)
        }
    }

    /// 拉取车辆列表
    func fetchVehicles() async throws -> [GwmVehicle] {
        let list = try await client.getVehicles()
        vehicles = list
        await persistQuietly()
        await syncPlatform()
        return list
    }

    // MARK: - 车况

    /// 立即刷新一次车况
    func refreshNow() async {
        await refresh(userInitiated: true)
    }

    private func refresh(userInitiated: Bool) async {
        let vin = selectedVin
        let snap = await client.loginSnapshot
        guard snap.loggedIn else {
            if userInitiated { notifyStatus(nil, "未登录") }
            return
        }

        setRefreshing(true)
        defer { setRefreshing(false) }

        var target = vin
        if target == nil || target!.isEmpty {
            // 没选车：先拉列表再选第一辆
            do {
                let list = try await client.getVehicles()
                vehicles = list
                if let first = list.first {
                    target = first.vin
                    selectedVin = first.vin
                } else {
                    notifyStatus(nil, "账号下没有车辆")
                    return
                }
            } catch {
                notifyStatus(nil, GwmError.friendly(error))
                return
            }
        }
        guard let vinToUse = target else { return }

        do {
            let status = try await client.getParsedStatus(vinToUse)
            lastStatus = status
            lastUpdateAt = Date()
            consecutiveFailures = 0
            await persistQuietly()
            await markSessionActiveIfNeeded()
            await syncPlatform()
            notifyStatus(status, nil)
            StatusAlertCenter.shared.process(status, repository: self)
        } catch let e as GwmError where e.isAuth {
            // 会话可能只是短命 token 过期，尝试恢复一次
            do {
                try await client.recoverSession()
                let status = try await client.getParsedStatus(vinToUse)
                lastStatus = status
                lastUpdateAt = Date()
                consecutiveFailures = 0
                notifyStatus(status, nil)
                StatusAlertCenter.shared.process(status, repository: self)
            } catch {
                await handleRefreshFailure(error)
            }
        } catch {
            await handleRefreshFailure(error)
        }
    }

    private func handleRefreshFailure(_ error: Error) async {
        consecutiveFailures += 1
        let reason = GwmError.friendly(error)
        notifyStatus(lastStatus, reason)
        // 连续失败不等于登录失效：可能只是网关抖动或被风控限流。
        // 先试着静默续期，续不上才要求用户重新登录——否则好好的登录态
        // 会因为几次网络波动就被判定失效，用户被迫反复登录。
        guard consecutiveFailures >= 3 else { return }
        let revived = await client.reviveSessionQuietly()
        if revived {
            await persistQuietly()
            consecutiveFailures = 0
            sessionState = .active
            sessionMessage = nil
            return
        }
        sessionState = .expired
        sessionMessage = "登录已过期，需要重新验证"
        notifyReauth(reason)
        stopPolling()
    }

    // MARK: - 远控

    /// 发送远控命令，返回命令标识
    func sendCommand(_ controlType: String, _ cmdBody: [String: Any]?) async throws -> String {
        let vin = selectedVin
        let snap = await client.loginSnapshot
        guard snap.loggedIn else { throw GwmError.auth("请先登录") }
        guard let target = vin, !target.isEmpty else { throw GwmError.auth("请先选择车辆") }

        let id = try await client.sendCommand(target, controlType, cmdBody)
        await persistQuietly()
        // 命令经云端转发有延迟，等几秒再拉一次最新状态
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await refresh(userInitiated: false)
        }
        return id
    }

    // MARK: - 轮询调度

    func startPolling() {
        guard pollScheduled == false else { return }
        guard isPollEnabled else { return }
        pollScheduled = true
        scheduleNext(after: 1.5)
    }

    func stopPolling() {
        pollScheduled = false
        pollTask?.cancel()
        pollTask = nil
    }

    private func scheduleNext(after delayOverride: Double? = nil) {
        pollTask?.cancel()
        guard isPollEnabled else {
            pollScheduled = false
            return
        }
        var delay = delayOverride ?? Double(pollIntervalSeconds)
        if delayOverride == nil && consecutiveFailures > 0 {
            let shift = min(consecutiveFailures, 6)
            delay = min(Double(Self.maxBackoffSeconds),
                        Double(pollIntervalSeconds) * pow(2, Double(shift)))
        }
        pollScheduled = true
        pollTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self = self else { return }
            let snap = await self.client.loginSnapshot
            guard snap.loggedIn else {
                self.pollScheduled = false
                return
            }
            await self.refresh(userInitiated: false)
            self.scheduleNext()
        }
    }

    /// 后台刷新（BGAppRefreshTask 触发）：只做一次，不重排定时器。
    func backgroundRefresh() async {
        guard isPollEnabled else { return }
        await refresh(userInitiated: false)
    }

    // MARK: - 持久化

    private func persist() async throws {
        let map = await client.stateMap()
        try CredentialStore.save(map)
    }

    private func persistQuietly() async {
        let map = await client.stateMap()
        try? CredentialStore.save(map)
    }

    func currentPlatformForHint() async -> String {
        await client.cachedPlatform(selectedVin)
    }
}
