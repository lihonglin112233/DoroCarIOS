import SwiftUI

/// 主界面：车辆状态提醒 + 车况 + 手动远控。
///
/// 状态监控在 App 前台时按 60 秒轮询；退到后台由系统按 `BGAppRefreshTask`
/// 的时机唤醒（见 `BackgroundRefresh`）。界面只是订阅者：
/// 控制器不可见时提醒照发通知。
///
/// 对应 Android 版 `MainActivity`（894 行），这里按语义拆成若干子视图，
/// 但保留原有的交互顺序与文案。
struct MainView: View {

    @EnvironmentObject private var repo: GwmRepository
    @EnvironmentObject private var alerts: StatusAlertCenter

    @State private var executor: CommandExecutor?

    // 登录表单
    @State private var phone = ""
    @State private var password = ""
    @State private var code = ""
    @State private var loginBusy = false
    @State private var loginStatus: String?
    @State private var loginStatusIsError = false
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?

    // 温度
    @State private var pendingTemp: Float = TempControl.defaultC
    @State private var tempZone: TempControl.Zone = .both

    // 远程启动
    @State private var runMinutes = VehicleActions.defaultRunMinutes

    // 提示与确认
    @State private var toast: String?
    @State private var confirmDialog: ConfirmRequest?
    @State private var showHelp = false
    @State private var showVehiclePicker = false

    /// 待确认的危险操作
    struct ConfirmRequest: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let action: () -> Void
    }

    var body: some View {
        ZStack {
            Palette.bgRoot.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)

                alertStrip
                    .padding(.horizontal, 16)

                alertFeed
                    .padding(.horizontal, 16)
                    .padding(.top, 10)

                bottomPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if let toast = toast {
                VStack {
                    Text(toast)
                        .font(.system(size: 13))
                        .foregroundColor(Palette.textPrimary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color(hex: 0x2A3446))
                        )
                    Spacer()
                }
                .padding(.top, 60)
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // 视图第一次出现时初始化执行器（依赖 repo 实例）
            if executor == nil {
                executor = CommandExecutor(repo: repo)
            }
            await repo.start()
            syncPendingTemp()
        }
        .onChange(of: repo.lastStatus) { _ in
            syncPendingTemp()
        }
        .alert(item: $confirmDialog) { req in
            Alert(title: Text(req.title),
                  message: Text(req.message),
                  primaryButton: .destructive(Text(req.confirmLabel)) { req.action() },
                  secondaryButton: .cancel(Text("取消")))
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
        .sheet(isPresented: $showVehiclePicker) {
            VehiclePickerView()
                .environmentObject(repo)
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("小哈车控")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(Palette.textPrimary)

                Button {
                    if repo.vehicles.count > 1 { showVehiclePicker = true }
                } label: {
                    HStack(spacing: 4) {
                        Text(vehicleSubtitle)
                            .font(.system(size: 12))
                            .foregroundColor(Palette.textSecondary)
                        if repo.vehicles.count > 1 {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Palette.textHint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                showHelp = true
            } label: {
                Text("能说什么")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color(hex: 0x1A2130)))
                    .overlay(Capsule().stroke(Palette.cardStroke, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private var vehicleSubtitle: String {
        guard repo.loggedIn else {
            return repo.sessionState == .restoring ? "正在恢复登录…" : "未登录"
        }
        guard let v = repo.selectedVehicle else { return "已登录" }
        return v.subtitle(effectivePlatform: repo.platform.isEmpty ? nil : repo.platform)
    }

    // MARK: - 状态提醒条

    private var alertStrip: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(repo.isPollEnabled ? Palette.stateOk : Palette.textHint)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(alerts.unreadCount > 0 ? "状态提醒 (\(alerts.unreadCount))" : "状态提醒")
                    .font(.system(size: 14))
                    .foregroundColor(Palette.textPrimary)
                Text(repo.isPollEnabled ? "正在监控车况变化，最新动态见下方" : "开启后自动监控车况变化并推送通知")
                    .font(.system(size: 11))
                    .foregroundColor(Palette.textHint)
            }

            Spacer()

            Button {
                togglePoll()
            } label: {
                Text(repo.isPollEnabled ? "停止监控" : "开启监控")
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!repo.loggedIn)
        }
        .doroCard()
    }

    private func togglePoll() {
        let next = !repo.isPollEnabled
        repo.setPollEnabled(next)
        if next {
            alerts.requestAuthorizationIfNeeded()
            BackgroundRefresh.schedule(after: repo.pollIntervalSeconds)
            pushAlert("已开启后台监控：车况变化会在这里提醒并推送通知", good: false)
        } else {
            pushAlert("已停止后台监控，不再推送状态提醒", good: false)
        }
    }

    // MARK: - 提醒流

    private var alertFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(alerts.alerts) { a in
                        Text(a.text)
                            .font(.system(size: 13.5))
                            .foregroundColor(a.good ? Palette.stateOk : Palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Palette.voiceBubbleSys)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(a.good ? Palette.stateOk.opacity(0.55) : Palette.cardStroke,
                                            lineWidth: 1)
                            )
                            .id(a.id)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: alerts.alerts.first?.id) { newValue in
                guard let id = newValue else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - 底部面板

    private var bottomPanel: some View {
        ScrollView {
            VStack(spacing: 12) {
                statusRow
                if !repo.loggedIn {
                    if repo.sessionState == .restoring {
                        Text("正在恢复登录…")
                            .font(.system(size: 12))
                            .foregroundColor(Palette.textHint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Divider1()
                        loginForm
                    }
                } else {
                    Divider1()
                    controlPanel
                }
            }
            .doroCard()
        }
        .frame(maxHeight: repo.loggedIn ? 420 : 360)
    }

    private var statusRow: some View {
        HStack(spacing: 0) {
            metric("门锁", value: lockText, color: lockColor)
            metric("电量", value: batteryText, color: Palette.textPrimary)
            metric("续航", value: rangeText, color: Palette.textPrimary)
            metric("车内", value: cabinText, color: Palette.textPrimary)
        }
    }

    private func metric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundColor(Palette.textHint)
            Text(value)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lockText: String {
        guard let s = repo.lastStatus, let locked = s.doorsLocked else { return "--" }
        return locked ? "已锁" : "未锁"
    }

    private var lockColor: Color {
        guard let s = repo.lastStatus, let locked = s.doorsLocked else { return Palette.textHint }
        return locked ? Palette.stateOk : Palette.stateWarn
    }

    private var batteryText: String {
        guard let s = repo.lastStatus else { return "--" }
        if let p = s.batteryPercent { return "\(Int(p.rounded()))%" }
        if let g = s.fuelGauge, !g.isEmpty { return "\(g)/8" }
        return "--"
    }

    private var rangeText: String {
        guard let r = repo.lastStatus?.fuelRange else { return "--" }
        return "\(Int(r.rounded()))km"
    }

    private var cabinText: String {
        guard let t = repo.lastStatus?.cabinTemp else { return "--" }
        return String(format: "%.1f°", t)
    }

    // MARK: - 登录表单

    private var loginForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登录长城账号")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Palette.pink)

            Text("使用长城汽车 App 的注册手机号，验证码与官方 App 通用")
                .font(.system(size: 11))
                .foregroundColor(Palette.textHint)

            DoroTextField(placeholder: "手机号", text: $phone, keyboard: .phonePad, maxLength: 11)
                .padding(.top, 2)

            DoroTextField(placeholder: "密码（填了就用密码登录，可免验证码）",
                          text: $password, isSecure: true)

            HStack(spacing: 8) {
                DoroTextField(placeholder: "验证码", text: $code, keyboard: .numberPad, maxLength: 6)
                Button {
                    sendCode()
                } label: {
                    Text(countdown > 0 ? "\(countdown) 秒后重发" : "获取验证码")
                        .font(.system(size: 12))
                        .foregroundColor(Palette.pink)
                        .frame(width: 100, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(hex: 0x1E2636))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Palette.cardStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(countdown > 0 || loginBusy)
            }

            Button {
                doLogin()
            } label: {
                Text(loginBusy ? "登录中…" : "登录")
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Palette.pink, Color(hex: 0xFFB3C8)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .foregroundColor(Palette.bgRoot)
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(loginBusy)

            if let status = loginStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundColor(loginStatusIsError ? Palette.stateErr : Palette.stateOk)
            }
        }
    }

    private func sendCode() {
        guard phone.count == 11 else {
            showToast("请输入 11 位手机号")
            return
        }
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task {
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
        }
        Task {
            do {
                try await repo.requestSmsCode(phone)
                showToast("验证码已发送，请查收")
            } catch {
                countdownTask?.cancel()
                countdown = 0
                loginStatus = "发送失败：" + GwmError.friendly(error)
                loginStatusIsError = true
            }
        }
    }

    private func doLogin() {
        guard phone.count == 11 else {
            showToast("请输入 11 位手机号")
            return
        }
        if password.isEmpty && code.isEmpty {
            showToast("请填写验证码，或输入密码登录")
            return
        }
        loginBusy = true
        loginStatus = nil
        Task {
            defer { loginBusy = false }
            do {
                if !password.isEmpty {
                    // 有密码优先走密码登录（免验证码）
                    _ = try await repo.loginPassword(phone, password)
                } else {
                    _ = try await repo.loginSms(phone, code)
                }
                loginStatus = "登录成功"
                loginStatusIsError = false
                showToast("登录成功")
                password = ""
                code = ""
                await repo.refreshNow()
                if repo.isPollEnabled {
                    alerts.requestAuthorizationIfNeeded()
                    BackgroundRefresh.schedule(after: repo.pollIntervalSeconds)
                }
            } catch {
                loginStatus = "登录失败：" + GwmError.friendly(error)
                loginStatusIsError = true
            }
        }
    }

    // MARK: - 控制面板

    private var controlPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            engineSection
            Divider1()
            lockSection
            Divider1()
            hvacSection
            tempSection
            logoutButton
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "远程启动")
                Spacer()
                Text(engineStateText)
                    .font(.system(size: 12))
                    .foregroundColor(engineRunningNow ? Palette.stateOk : Palette.textHint)
            }

            HStack(spacing: 8) {
                Button {
                    confirmEngineStart()
                } label: {
                    Text("启动发动机")
                }
                .buttonStyle(ControlButtonStyle(enabled: !engineRunningNow, highlighted: true))
                .disabled(engineRunningNow)

                Button {
                    confirmEngineStop()
                } label: {
                    Text("熄火")
                }
                .buttonStyle(ControlButtonStyle(enabled: engineRunningNow))
                .disabled(!engineRunningNow)

                Button {
                    cycleRunMinutes()
                } label: {
                    Text("\(runMinutes) 分钟")
                        .font(.system(size: 12))
                }
                .buttonStyle(ControlButtonStyle())
            }

            Text(EngineGuard.hint(repo.lastStatus))
                .font(.system(size: 11))
                .foregroundColor(Palette.textHint)
        }
    }

    private var engineRunningNow: Bool {
        repo.lastStatus?.isEngineRunning ?? false
    }

    private var engineStateText: String {
        guard let s = repo.lastStatus else { return "--" }
        return "● " + s.engineText
    }

    private func cycleRunMinutes() {
        let options = VehicleActions.runMinuteOptions
        let idx = options.firstIndex(of: runMinutes) ?? 0
        runMinutes = options[(idx + 1) % options.count]
    }

    private func confirmEngineStart() {
        let v = EngineGuard.canStart(repo.lastStatus)
        guard v.allowed else {
            pushAlert(v.message, good: false)
            showToast(v.message)
            return
        }
        if v.needsConfirm {
            confirmDialog = ConfirmRequest(
                title: "确认远程启动？",
                message: v.message + "\n\n发动机将运行 \(runMinutes) 分钟。",
                confirmLabel: "启动"
            ) {
                doEngineStart()
            }
            return
        }
        doEngineStart()
    }

    private func doEngineStart() {
        pushAlert("（手动）远程启动 · \(runMinutes) 分钟", good: false)
        Task {
            let result = await executor?.run(.engineStart, runMinutes: runMinutes)
            if let r = result {
                pushAlert(r.message, good: r.success)
                if r.verified { await repo.refreshNow() }
            }
        }
    }

    private func confirmEngineStop() {
        let v = EngineGuard.canStop(repo.lastStatus)
        guard v.allowed else {
            pushAlert(v.message, good: false)
            showToast(v.message)
            return
        }
        confirmDialog = ConfirmRequest(
            title: "确认远程熄火？",
            message: "车辆将立即熄火，空调等附件也会停止工作。",
            confirmLabel: "熄火"
        ) {
            perform(.engineStop)
        }
    }

    private var lockSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton("锁车", .lock)
                actionButton("解锁", .unlock)
            }
            HStack(spacing: 8) {
                actionButton("鸣笛", .whistle)
                actionButton("闪灯", .flash)
                actionButton("关窗", .windowClose)
            }
        }
    }

    private func actionButton(_ title: String, _ action: VehicleActions.Action) -> some View {
        Button {
            perform(action)
        } label: {
            Text(title)
        }
        .buttonStyle(ControlButtonStyle())
    }

    // MARK: - 空调

    private var hvacSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(text: "空调控制")
                Spacer()
                Text(acStateText)
                    .font(.system(size: 12))
                    .foregroundColor(acColor)
            }

            // 启动状态提示条：不满足条件时这里是用户唯一能看到的解释
            Text(acHintText)
                .font(.system(size: 12))
                .foregroundColor(acHintColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(hex: 0x151B27))
                )

            HStack(spacing: 8) {
                Button {
                    runIfEngine(.acOn)
                } label: {
                    Text("开空调")
                }
                .buttonStyle(ControlButtonStyle(enabled: canTurnOnAc))
                .disabled(!canTurnOnAc)

                Button {
                    perform(.acOff)
                } label: {
                    Text("关空调")
                }
                .buttonStyle(ControlButtonStyle(enabled: hvacSupported))
                .disabled(!hvacSupported)
            }

            HStack(spacing: 8) {
                Button { runIfEngine(.defrostFront) } label: { Text("前除霜") }
                    .buttonStyle(ControlButtonStyle(enabled: canUseAux))
                    .disabled(!canUseAux)
                Button { runIfEngine(.defrostRear) } label: { Text("后除霜") }
                    .buttonStyle(ControlButtonStyle(enabled: canUseAux))
                    .disabled(!canUseAux)
                Button { runIfEngine(.steerHeat) } label: { Text("方向盘加热") }
                    .buttonStyle(ControlButtonStyle(enabled: canUseAux))
                    .disabled(!canUseAux)
            }

            Text(acCabinText)
                .font(.system(size: 11))
                .foregroundColor(Palette.textHint)
        }
    }

    private var hvacSupported: Bool {
        HvacGuard.platformSupportsHvac(repo.platform)
    }

    private var auxSupported: Bool {
        HvacGuard.platformSupportsAux(repo.platform)
    }

    private var canTurnOnAc: Bool {
        hvacSupported && HvacGuard.isVehicleStarted(repo.lastStatus)
    }

    private var canUseAux: Bool {
        canTurnOnAc && auxSupported
    }

    private var acStateText: String {
        guard let s = repo.lastStatus else { return "--" }
        guard let ac = s.airConditioner else { return "该车型无空调状态" }
        return ac ? "● 空调运行中" : "○ 空调已关闭"
    }

    private var acColor: Color {
        guard let s = repo.lastStatus, let ac = s.airConditioner else { return Palette.textHint }
        return ac ? Palette.stateOk : Palette.textHint
    }

    private var acHintText: String {
        if !auxSupported {
            return HvacGuard.unsupportedPlatformText(repo.platform)
        }
        return HvacGuard.hint(repo.lastStatus)
    }

    private var acHintColor: Color {
        if !auxSupported { return Palette.stateWarn }
        return HvacGuard.isVehicleStarted(repo.lastStatus) ? Palette.stateOk : Palette.textSecondary
    }

    private var acCabinText: String {
        var parts: [String] = []
        if let t = repo.lastStatus?.cabinTemp {
            parts.append(String(format: "车内温度 %.1f°C", t))
        } else {
            parts.append("车内温度 --")
        }
        if let s = repo.lastStatus {
            if s.acAutoMode == true { parts.append("AUTO") }
            if s.frontDefroster == true { parts.append("前除霜") }
            if s.rearDefroster == true { parts.append("后除霜") }
            if s.steerWheelHeat == true { parts.append("方向盘加热") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 温度

    private var tempSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("设定温度")
                    .font(.system(size: 12))
                    .foregroundColor(Palette.textSecondary)
                Spacer()
                Button {
                    tempZone = tempZone.next
                } label: {
                    Text(tempZone.label)
                        .font(.system(size: 11))
                        .foregroundColor(Palette.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(Color(hex: 0x1E2636))
                        )
                        .overlay(Capsule().stroke(Palette.cardStroke, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Button {
                    stepTemp(-1)
                } label: {
                    Text("−")
                        .font(.system(size: 24))
                        .foregroundColor(Palette.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(hex: 0x1E2636))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Palette.cardStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdjustTemp || TempControl.atMin(pendingTemp))
                .opacity(canAdjustTemp && !TempControl.atMin(pendingTemp) ? 1 : 0.4)

                Spacer()

                Text(TempControl.format(pendingTemp))
                    .font(.system(size: 30, weight: .bold).monospacedDigit())
                    .foregroundColor(Palette.textPrimary)

                Spacer()

                Button {
                    stepTemp(+1)
                } label: {
                    Text("+")
                        .font(.system(size: 24))
                        .foregroundColor(Palette.textPrimary)
                        .frame(width: 52, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color(hex: 0x1E2636))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Palette.cardStroke, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAdjustTemp || TempControl.atMax(pendingTemp))
                .opacity(canAdjustTemp && !TempControl.atMax(pendingTemp) ? 1 : 0.4)
            }

            Button {
                applyTemp()
            } label: {
                Text("下发设定温度")
            }
            .buttonStyle(ControlButtonStyle(enabled: canAdjustTemp))
            .disabled(!canAdjustTemp)

            Text(tempHintText)
                .font(.system(size: 11))
                .foregroundColor(tempHintColor)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x151B27))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.cardStroke, lineWidth: 1)
        )
    }

    private var canAdjustTemp: Bool {
        canTurnOnAc
    }

    private var tempHintText: String {
        guard let s = repo.lastStatus else { return "车辆启动后才能调温" }
        if !HvacGuard.isVehicleStarted(s) { return "车辆启动后才能调温" }
        if let set = s.acTempSet {
            return "当前设定 " + TempControl.format(Float(set))
        }
        return "该车型不回读设定温度，下发后无法确认是否生效"
    }

    private var tempHintColor: Color {
        guard let s = repo.lastStatus, HvacGuard.isVehicleStarted(s), s.acTempSet != nil else {
            return Palette.textHint
        }
        return Palette.stateOk
    }

    private func stepTemp(_ dir: Int) {
        let next = dir > 0 ? TempControl.up(pendingTemp) : TempControl.down(pendingTemp)
        if abs(next - pendingTemp) < 0.001 {
            showToast(dir > 0 ? "已到最高温" : "已到最低温")
            return
        }
        pendingTemp = next
    }

    /// 车端有回读时，把待发值对齐到实际设定值，避免"显示的和车里的不一致"
    private func syncPendingTemp() {
        if let set = repo.lastStatus?.acTempSet {
            pendingTemp = TempControl.normalize(Float(set))
        }
    }

    private func applyTemp() {
        guard HvacGuard.platformSupportsHvac(repo.platform) else {
            let msg = HvacGuard.unsupportedPlatformText(repo.platform)
            pushAlert(msg, good: false)
            showToast(msg)
            return
        }
        let v = TempControl.canSet(repo.lastStatus, pendingTemp)
        guard v.allowed else {
            pushAlert(v.message, good: false)
            showToast(v.message)
            return
        }
        let target = TempControl.normalize(pendingTemp)
        pushAlert("（手动）调温至 \(TempControl.format(target)) · \(tempZone.label)", good: false)

        // 车况不回读设定温度时，先如实说明这条指令验不了
        let response = TempControl.responseOf(repo.lastStatus)
        if !response.verifiable {
            pushAlert("· " + response.note, good: false)
        }

        Task {
            let body = TempControl.bodiesOf(target, zone: tempZone.rawValue)
            let result = await executor?.run(.acTempSet, extraBody: body)
            if let r = result {
                pushAlert(r.message, good: r.success)
                if r.verified { await repo.refreshNow() }
            }
        }
    }

    // MARK: - 通用动作

    private func perform(_ action: VehicleActions.Action) {
        pushAlert("（手动）\(action.label)", good: false)
        Task {
            let result = await executor?.run(action)
            if let r = result {
                pushAlert(r.message, good: r.success)
                if r.verified { await repo.refreshNow() }
            }
        }
    }

    /// 需要「车辆已启动」的空调动作。
    ///
    /// 按钮本身的禁用态已经拦了一道，这里是第二道——防止车况刚好在过去
    /// 这几十毫秒里变成熄火，此时车况快照已过期。
    private func runIfEngine(_ action: VehicleActions.Action) {
        let ok = action == .acOn
            ? HvacGuard.platformSupportsHvac(repo.platform)
            : HvacGuard.platformSupportsAux(repo.platform)
        guard ok else {
            let msg = HvacGuard.unsupportedPlatformText(repo.platform)
            pushAlert(msg, good: false)
            showToast(msg)
            return
        }
        let v = HvacGuard.canTurnOn(repo.lastStatus)
        guard v.allowed else {
            pushAlert(v.message, good: false)
            showToast(v.message)
            return
        }
        if action == .acOn {
            // 开空调带上当前设定温度，车端才知道吹到多少度
            let t = TempControl.normalize(pendingTemp)
            pushAlert("（手动）开空调 · 设定 \(TempControl.format(t))", good: false)
            Task {
                let body = TempControl.bodiesOf(t, zone: tempZone.rawValue)
                let result = await executor?.run(.acOn, extraBody: body)
                if let r = result {
                    pushAlert(r.message, good: r.success)
                    if r.verified { await repo.refreshNow() }
                }
            }
            return
        }
        perform(action)
    }

    private var logoutButton: some View {
        Button {
            confirmDialog = ConfirmRequest(
                title: "退出登录",
                message: "退出后将停止状态提醒与远控，需重新用短信验证码登录。",
                confirmLabel: "退出"
            ) {
                BackgroundRefresh.cancel()
                repo.setPollEnabled(false)
                repo.logout()
                alerts.clearUnread()
                pushAlert("已退出登录", good: false)
            }
        } label: {
            Text("退出登录")
                .font(.system(size: 12))
                .foregroundColor(Palette.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(hex: 0x1E2636))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - 提示

    /// 写入提醒流（本地产生的事件，不发系统通知）
    private func pushAlert(_ text: String, good: Bool) {
        alerts.appendLocal(StatusAlert(item: "操作", text: text, good: good))
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            withAnimation { toast = nil }
        }
    }
}
