import Foundation

/// 车辆条目
struct GwmVehicle: Codable, Identifiable, Equatable {
    var vin: String
    var modelName: String?
    var seriesName: String?
    var nickname: String?
    var brandName: String?
    var platform: String

    var id: String { vin }

    init(vin: String, modelName: String? = nil, seriesName: String? = nil,
         nickname: String? = nil, brandName: String? = nil, platform: String = "") {
        self.vin = vin
        self.modelName = modelName
        self.seriesName = seriesName
        self.nickname = nickname
        self.brandName = brandName
        self.platform = platform
    }

    /// 顶部主标题：优先昵称，其次车系、车型，最后用 VIN 后 6 位兜底
    var displayName: String {
        if let n = nickname, !n.trimmed.isEmpty { return n }
        if let s = seriesName, !s.trimmed.isEmpty { return s }
        if let m = modelName, !m.trimmed.isEmpty { return m }
        if vin.count >= 6 { return "车辆 " + String(vin.suffix(6)) }
        return "我的车辆"
    }

    /// 副标题：VIN（脱敏）+ 车型 + 平台
    func subtitle(effectivePlatform: String?) -> String {
        var parts: [String] = []
        if !vin.isEmpty { parts.append(GwmVehicle.maskVin(vin)) }
        if let m = modelName, !m.trimmed.isEmpty, m != nickname { parts.append(m) }
        let p = (effectivePlatform?.trimmed.isEmpty == false) ? effectivePlatform! : platform
        if !p.trimmed.isEmpty { parts.append(p) }
        return parts.joined(separator: " · ")
    }

    /// VIN 脱敏：只显示后 6 位，避免截图泄露完整车架号
    static func maskVin(_ vin: String) -> String {
        guard vin.count > 6 else { return vin }
        return "VIN …" + String(vin.suffix(6))
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// GWM 中国区车联网客户端。
///
/// 移植自 Android 版 `GwmClient`（原始协议来自 gwm_cn_ha）。
/// 三段式登录链路：
/// ```
///   手机号+短信验证码
///        ↓
///   G-App (gapp-api.gwmapp-h.com)     → gToken / gRefreshToken / ssoToken / userId
///        ↓
///   ├─ BeanTech (gw-app-gateway)      → accessToken（车况查询 + 车控）
///   └─ AutoAI   (gsp/tsp 代理)        → tokenId（gtsp/navinfo 平台车控）
/// ```
///
/// 线程模型：所有公开方法都是 `async`，由调用方（`GwmRepository`）串行调度。
/// **必须串行**——token 刷新是单次轮换的，并发刷新会互相顶掉。
actor GwmClient {

    // MARK: - 端点

    private static let gAppBase = "https://gapp-api.gwmapp-h.com/"
    private static let beanTechBase = "https://gw-app-gateway.gwmapp-h.com/"
    private static let autoAiDirect = "https://ti.gwm.com.cn:8443/tsp/ead"

    private static let smsRequestUrl = gAppBase + "api-guser/v5/user/login-sms/send"
    private static let smsLoginUrl = gAppBase + "api-guser/v5/user/sms-login"
    private static let pwdLoginUrl = gAppBase + "api-guser/v5/user/pwd-login"
    private static let refreshUrl = gAppBase + "api-guser/v5/token/refresh"
    private static let discoveryUrl = gAppBase + "gcar/v1/app/android/vehicle/query-vehicle-list"
    private static let autoAiLoginUrl = gAppBase + "tsp/v1/proxy/navinfo/GW.M.APP_LOGIN"

    private static let btLoginPath = "/app-api/api/v1.0/userAuth/loginSSOAccount"
    private static let btStatusPath = "/app-api/api/v3.0/vehicle/getLastStatus"
    private static let btSendPath = "/app-api/api/v1.0/vehicle/T5/sendCmd"
    private static let btTimelyPath = "/app-api/api/v3.0/vehicle/remote-ctrl/timely"
    private static let btResultPath = "/app-api/api/v1.0/vehicle/getRemoteCtrlResultT5"

    // MARK: - 远控指令

    enum Cmd {
        static let lock = "VEHICLE_LOCK"
        static let unlock = "VEHICLE_UNLOCK"
        static let windowClose = "WINDOW_CLOSE"
        static let whistle = "WHISTLE"
        static let flash = "FLASH"
        static let whistleFlash = "WHISTLE_FLASH"
        static let engineStart = "ENGINE_START"
        static let engineStop = "ENGINE_STOP"
        /// 官方 APP 拼写就是 SKYLIGNT（缺一个 H），照抄不能改
        static let skylightClose = "SKYLIGNT_CLOSE"
        static let acStart = "AIR_CONDITIONER_START"
        static let acStop = "AIR_CONDITIONER_STOP"
        static let defrostFrontStart = "DEFROST_FRONT_START"
        static let defrostFrontStop = "DEFROST_FRONT_STOP"
        static let defrostBackStart = "DEFROST_BACK_START"
        static let defrostBackStop = "DEFROST_BACK_STOP"
        static let steerHeatStart = "STEERING_WHEEL_HEATING"
        static let steerHeatStop = "STEERING_WHEEL_HEATLESS"
        static let seatHeatStart = "SEAT_HEATING_START"
        static let seatHeatStop = "SEAT_HEATING_STOP"
        static let seatVentStart = "SEAT_VENTILATION_START"
        static let seatVentStop = "SEAT_VENTILATION_STOP"

        /// 鸣笛/闪灯走即时通道，不带 cmdBody
        static let timely: Set<String> = [whistle, flash, whistleFlash]
    }

    /// gtsp / navinfo 平台支持的指令（AutoAI 通用指令码）。
    ///
    /// 这套码表来自对官方 APP 的逆向实测：gtsp 平台下「空调开启/空调关闭」是
    /// **独立指令**，不是"远程启动"的别名。
    static let autoAiCmdCodes: [String: Int] = [
        Cmd.unlock: 1,
        Cmd.lock: 2,
        Cmd.windowClose: 3,
        Cmd.whistleFlash: 5,
        Cmd.engineStart: 15,
        Cmd.engineStop: 16,
        Cmd.whistle: 19,
        Cmd.flash: 20,
        Cmd.skylightClose: 28,
        Cmd.acStart: 17,
        Cmd.acStop: 18,
    ]

    private static let autoAiOpenCommand = "GW.M.SET_AND_OPEN_COMMAND"
    private static let autoAiSendCommonCommand = "GW.M.SEND_COMMON_COMMAND"

    // MARK: - 会话状态

    private(set) var phone: String = ""
    /// 32 位大写十六进制，首次登录生成后固定
    private(set) var deviceId: String = GwmCrypto.randomDeviceId()

    private(set) var gToken: String?
    private(set) var gRefreshToken: String?
    private(set) var ssoToken: String?
    private(set) var ptToken: String?
    private(set) var userId: String?
    private(set) var beanId: String?

    private(set) var btAccessToken: String?
    private(set) var btRefreshToken: String?
    private(set) var btBeanId: String?

    private(set) var autoTokenId: String?
    private(set) var autoUserId: String?

    /// VIN → 平台（beantech / navinfo / gtsp）
    private var platformCache: [String: String] = [:]
    /// belongPlatform 标 beantech、但 T5/sendCmd 实测 550002 的 VIN（实际为 gtsp）
    private var t5BrokenVins: Set<String> = []

    private let http = HTTPClient()
    private var timeoutSeconds = 20

    init() {}

    func setTimeoutSeconds(_ seconds: Int) {
        timeoutSeconds = max(5, seconds)
    }

    // MARK: - 会话判定

    private static func notEmpty(_ s: String?) -> Bool {
        guard let s = s else { return false }
        return !s.isEmpty
    }

    var hasGApp: Bool {
        Self.notEmpty(gToken) && Self.notEmpty(gRefreshToken) && Self.notEmpty(userId)
    }

    var isLoggedIn: Bool {
        hasGApp && Self.notEmpty(beanId) && Self.notEmpty(btAccessToken)
            && Self.notEmpty(autoTokenId) && Self.notEmpty(autoUserId)
    }

    /// 是否拥有「可以长期续期」的登录凭据。
    ///
    /// 与 `isLoggedIn` 的区别：后者要求下游两个短命会话当前有效；
    /// 本属性只看 refreshToken。只要它还在，就能在不打扰用户的前提下换出新会话。
    var hasRefreshableSession: Bool { hasGApp }

    /// 供跨隔离读取的快照（仓库层 `await client.loginSnapshot` 使用）
    var loginSnapshot: (loggedIn: Bool, phone: String, hasRefreshable: Bool) {
        (isLoggedIn, phone, hasGApp)
    }

    // MARK: - 会话生命周期

    func setPhone(_ value: String) {
        phone = value.trimmed
    }

    /// 从 Keychain 恢复的字典重建会话状态。
    func applyState(_ m: [String: Any]) {
        let st = SessionState.decode(m)
        phone = st.phone
        deviceId = st.deviceId
        gToken = st.gToken
        gRefreshToken = st.gRefreshToken
        ssoToken = st.ssoToken
        ptToken = st.ptToken
        userId = st.userId
        beanId = st.beanId
        btAccessToken = st.btAccessToken
        btRefreshToken = st.btRefreshToken
        btBeanId = st.btBeanId
        autoTokenId = st.autoTokenId
        autoUserId = st.autoUserId
        platformCache = st.platformCache
        t5BrokenVins = st.t5BrokenVins
    }

    /// 退出登录：清空全部会话状态
    func clearSession() {
        phone = ""
        gToken = nil
        gRefreshToken = nil
        ssoToken = nil
        ptToken = nil
        userId = nil
        beanId = nil
        btAccessToken = nil
        btRefreshToken = nil
        btBeanId = nil
        autoTokenId = nil
        autoUserId = nil
        platformCache.removeAll()
        t5BrokenVins.removeAll()
    }

    // MARK: - 序列化（供 Keychain 加密存储）

    /// 序列化为字典（供 Keychain 加密存储）。
    /// 因为读取的是 actor 隔离状态，必须在 actor 上下文内调用（即 `await client.stateMap()`）。
    func stateMap() -> [String: Any] {
        var m: [String: Any] = [:]
        m["phone"] = phone
        m["device_id"] = deviceId
        m["g_token"] = gToken
        m["g_refresh_token"] = gRefreshToken
        m["sso_token"] = ssoToken
        m["pt_token"] = ptToken
        m["user_id"] = userId
        m["bean_id"] = beanId
        m["bt_access_token"] = btAccessToken
        m["bt_refresh_token"] = btRefreshToken
        m["bt_bean_id"] = btBeanId
        m["auto_token_id"] = autoTokenId
        m["auto_user_id"] = autoUserId
        m["platforms"] = platformCache
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ";")
        m["t5broken"] = t5BrokenVins.joined(separator: ";")
        return m
    }

    /// 会话的纯数据结构（跨隔离传递用；actor 实例不能直接读私有字段）
    struct SessionState {
        var phone = ""
        var deviceId = ""
        var gToken: String?
        var gRefreshToken: String?
        var ssoToken: String?
        var ptToken: String?
        var userId: String?
        var beanId: String?
        var btAccessToken: String?
        var btRefreshToken: String?
        var btBeanId: String?
        var autoTokenId: String?
        var autoUserId: String?
        var platformCache: [String: String] = [:]
        var t5BrokenVins: Set<String> = []

        static func decode(_ m: [String: Any]?) -> SessionState {
            var st = SessionState()
            guard let m = m else {
                st.deviceId = GwmCrypto.randomDeviceId()
                return st
            }
            st.phone = (m["phone"] as? String) ?? ""
            let device = (m["device_id"] as? String) ?? ""
            st.deviceId = device.isEmpty ? GwmCrypto.randomDeviceId() : device
            st.gToken = strOrNil(m["g_token"])
            st.gRefreshToken = strOrNil(m["g_refresh_token"])
            st.ssoToken = strOrNil(m["sso_token"])
            st.ptToken = strOrNil(m["pt_token"])
            st.userId = strOrNil(m["user_id"])
            st.beanId = strOrNil(m["bean_id"])
            st.btAccessToken = strOrNil(m["bt_access_token"])
            st.btRefreshToken = strOrNil(m["bt_refresh_token"])
            st.btBeanId = strOrNil(m["bt_bean_id"])
            st.autoTokenId = strOrNil(m["auto_token_id"])
            st.autoUserId = strOrNil(m["auto_user_id"])

            let platforms = (m["platforms"] as? String) ?? ""
            for part in platforms.split(separator: ";") {
                if let eq = part.firstIndex(of: "=") {
                    let k = String(part[part.startIndex..<eq])
                    let v = String(part[part.index(after: eq)...])
                    st.platformCache[k] = v
                }
            }
            let broken = (m["t5broken"] as? String) ?? ""
            for vin in broken.split(separator: ";") where !vin.isEmpty {
                let v = String(vin)
                st.t5BrokenVins.insert(v)
                // 恢复时同步把平台固定为 gtsp，防止恢复窗口内按旧平台发指令
                st.platformCache[v] = "gtsp"
            }
            return st
        }

        private static func strOrNil(_ o: Any?) -> String? {
            guard let o = o else { return nil }
            if o is NSNull { return nil }
            let s = String(describing: o)
            return s.isEmpty || s == "null" ? nil : s
        }
    }

    // MARK: - 静默续期

    /// 静默恢复：不打扰用户、不需验证码，把过期的短命会话重新换出来。
    ///
    /// 顺序按代价从低到高：先重初始化下游服务，失败再走整体 refresh。
    func reviveSessionQuietly() async -> Bool {
        guard hasGApp else { return false }
        do {
            try await initializeServices()
            if isLoggedIn { return true }
        } catch {
            // 继续走 refresh
        }
        do {
            try await refresh()
            return isLoggedIn
        } catch {
            return false
        }
    }

    /// 会话失效时按代价从低到高恢复：先重初始化，再 refreshToken。
    func recoverSession() async throws {
        do {
            try await initializeServices()
            if isLoggedIn { return }
        } catch let e as GwmError {
            if case .auth = e {
                // 短命会话失效，继续尝试刷新
            } else if case .schema = e {
                //
            } else {
                throw e
            }
        }
        try await refresh()
    }

    // MARK: - 登录

    /// 请求短信验证码
    func requestSmsCode(_ phoneNumber: String) async throws {
        phone = phoneNumber.trimmed
        var body = OrderedJSON()
        body.set("phone", phone)
        body.set("flag", "LOGIN")
        _ = try await gAppPost("request_verification", Self.smsRequestUrl, body, encryptBody: true)
    }

    /// 用短信验证码完成三段式登录，返回名下车辆列表。
    func loginSms(_ code: String) async throws -> [GwmVehicle] {
        let trimmed = code.trimmed
        guard !trimmed.isEmpty else { throw GwmError.auth("验证码不能为空") }
        var body = OrderedJSON()
        body.set("code", trimmed)
        body.set("phone", phone)
        body.set("deviceToken", "")
        let data = try await gAppPost("login", Self.smsLoginUrl, body, encryptBody: true)
        try applyGAppData(asMap(data))
        try await initializeServices()
        return try await getVehicles()
    }

    /// 用手机号+密码完成三段式登录，返回名下车辆列表。
    func loginPassword(_ phoneNumber: String, _ password: String) async throws -> [GwmVehicle] {
        phone = phoneNumber.trimmed
        guard !phone.isEmpty else { throw GwmError.auth("手机号不能为空") }
        guard !password.isEmpty else { throw GwmError.auth("密码不能为空") }
        var body = OrderedJSON()
        body.set("phone", phone)
        body.set("deviceId", deviceId)
        body.set("password", password)
        body.set("deviceToken", "")
        let data = try await gAppPost("login_pwd", Self.pwdLoginUrl, body, encryptBody: true)
        try applyGAppData(asMap(data))
        try await initializeServices()
        return try await getVehicles()
    }

    /// gToken 自动刷新 + 重新初始化下游两个服务。
    func refresh() async throws {
        guard hasGApp else { throw GwmError.auth("没有可刷新的登录状态，请重新短信登录") }
        var body = OrderedJSON()
        body.set("token", gToken)
        body.set("refreshToken", gRefreshToken)
        let data = try await gAppPost("refresh_token", Self.refreshUrl, body, encryptBody: true)
        try applyGAppData(asMap(data))
        try await initializeServices()
    }

    // MARK: - 车辆列表

    func getVehicles() async throws -> [GwmVehicle] {
        var body = OrderedJSON()
        body.set("vehicleVersion", 13)
        let data = try await gAppPost("acquire_vehicles", Self.discoveryUrl, body, encryptBody: false)

        var value: Any? = ciProp(data, "acquireVehiclesList")
        if value == nil { value = data }
        guard let list = value as? [Any] else { throw GwmError.schema("车辆列表格式异常") }

        var vehicles: [GwmVehicle] = []
        for item in list {
            guard let m = asMap(item) else { continue }
            guard let vinObj = ciProp(m, "vin") else { continue }
            let vin = valueToStr(vinObj)?.trimmed.uppercased() ?? ""
            if vin.isEmpty { continue }
            let platform = (ciString(m, "belongPlatform") ?? "").trimmed
            var v = GwmVehicle()
            v.vin = vin
            v.modelName = ciString(m, "modelName")
            v.seriesName = ciString(m, "appShowSeriesName")
            v.nickname = ciString(m, "vehicleNick")
            v.brandName = ciString(m, "brandName")
            v.platform = platform
            vehicles.append(v)
            // 已实测降级为 gtsp 的 VIN 不被车辆列表覆盖回 beantech——
            // belongPlatform 是后端配置的"名义平台"，可能滞后于实际路由。
            if t5BrokenVins.contains(vin) {
                platformCache[vin] = "gtsp"
            } else {
                platformCache[vin] = platform.lowercased()
            }
        }
        return vehicles
    }

    // MARK: - 车况

    /// 查询车况，返回原始 data（未解析）。
    func getStatus(_ vin: String) async throws -> [String: Any] {
        let upper = vin.trimmed.uppercased()
        guard isLoggedIn else { throw GwmError.auth("未完成登录") }

        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = GwmCrypto.randomNonce()
        let parameter = "vin=" + upper
        let headers = try beanTechHeaders(method: "GET", path: Self.btStatusPath, nonce: nonce,
                                          timestamp: timestamp, parameter: parameter, vin: upper)
        let urlString = Self.beanTechUrl(absolutePath: Self.btStatusPath) + "?vin=" + urlEncode(upper)
        guard let url = URL(string: urlString) else {
            throw GwmError.connection("URL 非法")
        }
        let resp = try await http.send(method: "GET", url: url, headers: headers, body: nil)
        let data = try decodeGAppResponse(resp, "get_last_status")
        return asMap(data) ?? [:]
    }

    /// 查询车况并解析成结构化对象。
    func getParsedStatus(_ vin: String) async throws -> VehicleStatus {
        VehicleStatus.parse(try await getStatus(vin))
    }

    // MARK: - 平台

    /// 只读平台缓存，不触发网络请求。
    func cachedPlatform(_ vin: String?) -> String {
        let upper = (vin ?? "").trimmed.uppercased()
        return platformCache[upper] ?? ""
    }

    func getPlatform(_ vin: String) async throws -> String {
        let upper = vin.trimmed.uppercased()
        if platformCache[upper] == nil {
            _ = try await getVehicles()
        }
        return platformCache[upper] ?? ""
    }

    // MARK: - 远控

    /// 发送远控命令，返回命令标识（seqNo 或 transactionId）。
    /// 会话过期时自动恢复并重试一次。
    func sendCommand(_ vin: String, _ controlType: String,
                     _ cmdBody: [String: Any]?) async throws -> String {
        do {
            return try await sendCommandInner(vin, controlType, cmdBody)
        } catch let e as GwmError {
            guard case .auth(let msg) = e else { throw e }
            // 只对「会话失效」类错误重试，避免验证码错误被误重试
            guard msg.contains("会话") || msg.contains("-101") || msg.contains("认证失败") else {
                throw e
            }
            try await recoverSession()
            return try await sendCommandInner(vin, controlType, cmdBody)
        }
    }

    private func sendCommandInner(_ vin: String, _ controlType: String,
                                  _ cmdBody: [String: Any]?) async throws -> String {
        let upper = vin.trimmed.uppercased()
        guard isLoggedIn else { throw GwmError.auth("未完成登录") }

        var platform = ""
        do {
            platform = try await getPlatform(upper)
        } catch {
            // 平台探测失败按未知处理，仍走 AutoAI
        }

        if platform == "beantech" && !t5BrokenVins.contains(upper) {
            do {
                return try await sendBeanTechCommand(upper, controlType, cmdBody)
            } catch let e as GwmError {
                guard case .auth(let msg) = e else { throw e }
                // 550002 是 gtsp 新 TSP 平台对 T5/sendCmd 的固定拒绝：
                // belongPlatform 仍标 beantech，但后端实际已路由 gtsp。
                // 首次遇到即把该 VIN 降级到 AutoAI 通道并改写平台缓存。
                guard msg.contains("550002") else { throw e }
                t5BrokenVins.insert(upper)
                platformCache[upper] = "gtsp"
            }
        }

        guard let cmdCode = Self.autoAiCmdCodes[controlType] else {
            throw GwmError.auth("平台 \(platform.isEmpty ? "未知" : platform) 暂不支持该指令：\(controlType)")
        }
        let function = (controlType == Cmd.engineStart) ? Self.autoAiOpenCommand : Self.autoAiSendCommonCommand
        var extra: [String: Any]? = nil

        if controlType == Cmd.engineStart {
            // 远程启动必须带 engineParams，否则 AutoAI 报 -106 参数错误
            var minutes = 15
            if let op = cmdBody?["operationTime"] as? NSNumber {
                minutes = max(1, op.intValue / 60)
            }
            extra = ["engineParams": ["runTime": minutes]]
        } else if controlType == Cmd.acStart {
            // 空调开启：官方 APP 把温度与时长放在指令体里。
            // allowStartEng=1 表示"允许为了开空调而启动发动机"（燃油车预冷/预热）
            var body: [String: Any] = ["allowStartEng": 1]
            if let op = cmdBody?["operationTime"] as? NSNumber {
                body["operationTime"] = op.intValue
            } else {
                body["operationTime"] = 15 * 60
            }
            if let t = cmdBody?["temperature"] as? NSNumber {
                body["temperature"] = t.intValue
            }
            extra = body
        }
        return try await sendAutoAiCommand(upper, cmdCode, function, extra)
    }

    /// BeanTech 平台：T5/sendCmd（controlType 字符串）+ timely（鸣笛闪灯）。
    private func sendBeanTechCommand(_ vin: String, _ controlType: String,
                                     _ cmdBody: [String: Any]?) async throws -> String {
        let seqNo = GwmCrypto.randomSequence()
        let timely = Cmd.timely.contains(controlType)

        var entry = OrderedJSON()
        entry.set("controlType", controlType)
        if !timely { entry.set("cmdBody", cmdBody) }

        var payload = OrderedJSON()
        payload.set("vin", vin)
        payload.set("seqNo", seqNo)
        payload.set("sendType", 0)
        payload.set("commands", [entry])
        if !timely { payload.set("isSaveConfig", nil) }

        let body = GwmCrypto.encodeDotnetJson(payload)
        let path = timely ? Self.btTimelyPath : Self.btSendPath
        var headers = try beanTechHeaders(method: "POST", path: path,
                                          nonce: GwmCrypto.randomNonce(),
                                          timestamp: String(Int(Date().timeIntervalSince1970 * 1000)),
                                          parameter: "json=" + body, vin: vin)
        headers["Content-Type"] = "application/json; charset=UTF-8"

        guard let url = URL(string: Self.beanTechUrl(absolutePath: path)) else {
            throw GwmError.connection("URL 非法")
        }
        let resp = try await http.send(method: "POST", url: url, headers: headers, body: body)
        _ = try decodeGAppResponse(resp, "send_cmd")
        return seqNo
    }

    /// AutoAI 通用指令通道（gtsp / navinfo），返回 transactionId。
    private func sendAutoAiCommand(_ vin: String, _ cmdCode: Int, _ function: String,
                                   _ extraBody: [String: Any]?) async throws -> String {
        let tsMs = String(Int(Date().timeIntervalSince1970 * 1000))

        var body = OrderedJSON()
        body.set("flag", 1)
        body.set("signStr", GwmCrypto.md5Hex(vin + (autoTokenId ?? "")))
        body.set("userId", autoUserId)
        body.set("userType", "0")
        body.set("vin", vin)
        body.set("cmdCode", cmdCode)
        if let extraBody = extraBody {
            for (k, v) in extraBody { body.set(k, v) }
        }

        var header = OrderedJSON()
        header.set("brandType", "gwm")
        header.set("cVer", GwmCrypto.sourceAppVersion)
        header.set("fn", function)
        header.set("fv", "0202")
        header.set("mobileId", deviceId)
        header.set("osType", "Android")
        header.set("osVer", "")
        header.set("rs", "2")
        header.set("ts", GwmCrypto.chinaTimestamp())
        header.set("tk", autoTokenId)
        header.set("v", "1.0")

        var wrapper = OrderedJSON()
        wrapper.set("body", body)
        wrapper.set("header", header)

        let payload = GwmCrypto.encodeDotnetJson(wrapper)
        let urlString = Self.autoAiDirect + "?p=" + urlEncodeFull(payload)
        guard let url = URL(string: urlString) else {
            throw GwmError.connection("URL 非法（AutoAI）")
        }
        let headers = autoAiHeaders(tsMs)
        let resp = try await http.send(method: "GET", url: url, headers: headers, body: nil)
        let result = try decodeAutoAiResponse(resp, "send_cmd")
        guard let transactionId = ciProp(result, "transactionId") else {
            throw GwmError.schema("AutoAI 远控响应缺少 transactionId")
        }
        return valueToStr(transactionId) ?? ""
    }

    /// 查询远控命令执行结果。
    func getCommandResult(_ vin: String, _ seqNo: String) async throws -> Any? {
        let upper = vin.trimmed.uppercased()
        guard isLoggedIn else { throw GwmError.auth("未完成登录") }
        let headers = try beanTechHeaders(method: "GET", path: Self.btResultPath,
                                          nonce: GwmCrypto.randomNonce(),
                                          timestamp: String(Int(Date().timeIntervalSince1970 * 1000)),
                                          parameter: "seqno=" + seqNo, vin: upper)
        let urlString = Self.beanTechUrl(absolutePath: Self.btResultPath) + "?seqNo=" + urlEncode(seqNo)
        guard let url = URL(string: urlString) else {
            throw GwmError.connection("URL 非法")
        }
        let resp = try await http.send(method: "GET", url: url, headers: headers, body: nil)
        return try decodeGAppResponse(resp, "get_cmd_result")
    }

    // MARK: - 登录链路内部

    private func applyGAppData(_ data: [String: Any]?) throws {
        guard let data = data else { throw GwmError.schema("G-App 响应格式异常") }
        let gTok = ciProp(data, "gToken") ?? ciProp(data, "token")
        let gRef = ciProp(data, "gRefreshToken") ?? ciProp(data, "refreshToken")
        let sso = ciProp(data, "ssoToken")
        let pt = ciProp(data, "ptToken")
        let uid = ciProp(data, "userId")
        let bid = ciProp(data, "beanId")

        if let gTok = gTok, let gRef = gRef, let uid = uid {
            gToken = valueToStr(gTok)
            gRefreshToken = valueToStr(gRef)
            userId = valueToStr(uid)
        }
        if let sso = sso { ssoToken = valueToStr(sso) }
        if let pt = pt { ptToken = valueToStr(pt) }
        if let bid = bid { beanId = valueToStr(bid) }

        guard hasGApp else {
            throw GwmError.schema("G-App 登录响应缺少必需字段（gToken/gRefreshToken/userId）")
        }
    }

    /// BeanTech + AutoAI 两个下游服务登录。
    private func initializeServices() async throws {
        // ---- BeanTech SSO ----
        guard ssoToken != nil || ptToken != nil else {
            throw GwmError.schema("缺少 ssoToken，无法登录 BeanTech")
        }
        var btBody = OrderedJSON()
        btBody.set("appType", 0)
        btBody.set("deviceId", deviceId)
        btBody.set("phone", phone)
        btBody.set("ssoId", userId)
        btBody.set("ssoToken", ssoToken ?? ptToken)
        let body = GwmCrypto.encodeDotnetJson(btBody)

        let timestamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let nonce = GwmCrypto.randomNonce()
        var headers = beanTechBaseHeaders(nonce: nonce, timestamp: timestamp)
        headers["bt-auth-sign"] = GwmCrypto.beanTechSign(method: "POST", path: Self.btLoginPath,
                                                         nonce: nonce, timestamp: timestamp,
                                                         parameter: "json=" + body)
        if let beanId = beanId { headers["beanId"] = beanId }
        headers["Content-Type"] = "application/json; charset=UTF-8"

        guard let url = URL(string: Self.beanTechUrl(absolutePath: Self.btLoginPath)) else {
            throw GwmError.connection("URL 非法")
        }
        let btResp = try await http.send(method: "POST", url: url, headers: headers, body: body)
        let btData = asMap(try decodeGAppResponse(btResp, "initialize_bean_tech"))
        guard let btData = btData else { throw GwmError.schema("BeanTech 登录响应格式异常") }

        guard let accessToken = ciProp(btData, "accessToken") else {
            throw GwmError.schema("BeanTech 登录响应缺少 accessToken")
        }
        btAccessToken = valueToStr(accessToken)
        if let btRefresh = ciProp(btData, "refreshToken") {
            btRefreshToken = valueToStr(btRefresh)
        }
        btBeanId = ciProp(btData, "beanId").flatMap { valueToStr($0) } ?? beanId

        // ---- AutoAI ----
        guard let ssoToken = ssoToken else {
            throw GwmError.schema("缺少 ssoToken，无法登录 AutoAI")
        }
        let tsMs = String(Int(Date().timeIntervalSince1970 * 1000))

        var autoBody = OrderedJSON()
        autoBody.set("appType", 0)
        autoBody.set("phone", phone)
        autoBody.set("pushId", "0")
        autoBody.set("pushKey", "0")
        autoBody.set("ssoid", userId)
        autoBody.set("ssoTk", ssoToken)

        var autoHeader = OrderedJSON()
        autoHeader.set("brandType", "gwm")
        autoHeader.set("cVer", GwmCrypto.sourceAppVersion)
        autoHeader.set("fn", "GW.M.APP_LOGIN")
        autoHeader.set("fv", "0202")
        autoHeader.set("mobileId", deviceId)
        autoHeader.set("osType", "Android")
        autoHeader.set("osVer", "")
        autoHeader.set("rs", "2")
        autoHeader.set("ts", GwmCrypto.chinaTimestamp())
        autoHeader.set("tk", "")
        autoHeader.set("v", "1.0")

        var wrapper = OrderedJSON()
        wrapper.set("body", autoBody)
        wrapper.set("header", autoHeader)
        let payload = GwmCrypto.encodeDotnetJson(wrapper)
        let urlString = Self.autoAiLoginUrl + "?p=" + urlEncodeFull(payload)
        guard let autoUrl = URL(string: urlString) else {
            throw GwmError.connection("URL 非法（AutoAI 登录）")
        }

        let autoResp = try await http.send(method: "GET", url: autoUrl,
                                           headers: autoAiHeaders(tsMs), body: nil)
        let autoData = try decodeAutoAiResponse(autoResp, "initialize_auto_ai")
        guard let tokenId = ciProp(autoData, "tokenId"),
              let autoUid = ciProp(autoData, "userId") else {
            throw GwmError.schema("AutoAI 登录响应缺少 tokenId/userId")
        }
        autoTokenId = valueToStr(tokenId)
        autoUserId = valueToStr(autoUid)
    }

    // MARK: - 请求头构造

    private func gAppPost(_ operation: String, _ urlString: String,
                          _ logicalBody: OrderedJSON,
                          encryptBody: Bool) async throws -> Any? {
        let logicalJson = GwmCrypto.encodeDotnetJson(logicalBody)
        let rawBody = encryptBody ? try GwmCrypto.encryptEnvelope(logicalJson, keyId: 1) : logicalJson

        // 时间戳截到秒级（官方 APP 行为）
        let seconds = Int(Date().timeIntervalSince1970)
        let timestamp = String(seconds * 1000)

        var signingHeaders: [String: String] = [:]
        signingHeaders["Authorization"] = btAccessToken ?? ""
        signingHeaders["SourceApp"] = "GWM"
        signingHeaders["SourceType"] = "ANDROID"
        signingHeaders["SourceAppVer"] = GwmCrypto.sourceAppVersion
        signingHeaders["Timestamp"] = timestamp
        signingHeaders["DeviceId"] = deviceId
        signingHeaders["AppId"] = GwmCrypto.gAppAppId
        signingHeaders["NoteId"] = GwmCrypto.defaultNoteId

        var headers: [String: String] = [:]
        if let gToken = gToken { headers["G-TOKEN"] = gToken }
        headers["Authorization"] = btAccessToken ?? ""
        if let userId = userId { headers["ssoId"] = userId }
        headers["SourceApp"] = "GWM"
        headers["SourceType"] = "ANDROID"
        headers["SourceAppVer"] = GwmCrypto.sourceAppVersion
        headers["SourceAppCode"] = GwmCrypto.sourceAppCode
        headers["Timestamp"] = timestamp
        headers["DeviceId"] = deviceId
        headers["AppId"] = GwmCrypto.gAppAppId
        if let beanId = beanId { headers["beanId"] = beanId }
        headers["NoteId"] = GwmCrypto.defaultNoteId
        headers["Sign"] = GwmCrypto.defaultSign(method: "POST", signingUrl: urlString,
                                                rawBody: rawBody, headers: signingHeaders)
        headers["Accept-Encoding"] = "gzip"
        headers["User-Agent"] = GwmCrypto.officialUserAgent
        headers["Content-Type"] = "application/json; charset=UTF-8"

        guard let url = URL(string: urlString) else {
            throw GwmError.connection("URL 非法：\(operation)")
        }
        let resp = try await http.send(method: "POST", url: url, headers: headers, body: rawBody)
        return try decodeGAppResponse(resp, operation)
    }

    /// 拼 BeanTech 完整地址：base 自带尾斜杠，用绝对路径必须去掉前导斜杠，否则会出现 //
    private static func beanTechUrl(absolutePath: String) -> String {
        let p = absolutePath.hasPrefix("/") ? String(absolutePath.dropFirst()) : absolutePath
        return beanTechBase + p
    }

    private func beanTechBaseHeaders(nonce: String, timestamp: String) -> [String: String] {
        [
            "bt-auth-appkey": GwmCrypto.beanTechAppKey,
            "bt-auth-nonce": nonce,
            "bt-auth-timestamp": timestamp,
            "rs": "2",
            "appId": "097a7099af30d960",
            "brand": "10",
            "terminal": "GW_APP_GWM",
            "enterPriseId": "CC01",
            "cVer": GwmCrypto.sourceAppVersion,
            "tenantId": "1",
            "operatorRole": "0",
            "Accept-Encoding": "gzip",
            "User-Agent": GwmCrypto.officialUserAgent,
        ]
    }

    private func beanTechHeaders(method: String, path: String, nonce: String,
                                 timestamp: String, parameter: String, vin: String) throws -> [String: String] {
        let bid = btBeanId ?? beanId
        guard Self.notEmpty(btAccessToken), Self.notEmpty(bid), Self.notEmpty(autoTokenId) else {
            throw GwmError.auth("BeanTech 会话不完整，请重新登录")
        }
        var h = beanTechBaseHeaders(nonce: nonce, timestamp: timestamp)
        h["bt-auth-sign"] = GwmCrypto.beanTechSign(method: method, path: path, nonce: nonce,
                                                   timestamp: timestamp, parameter: parameter)
        h["accessToken"] = btAccessToken
        h["beanId"] = bid
        h["vin"] = vin
        h["tokenId"] = autoTokenId
        return h
    }

    private func autoAiHeaders(_ tsMs: String) -> [String: String] {
        [
            "v": "1.0",
            "cid": deviceId,
            "client": "phone",
            "sign": GwmCrypto.autoAiSign(timestamp: tsMs),
            "time": tsMs,
            "ckey": GwmCrypto.autoAiCkey,
            "protocolVer": "2.1.2",
            "brandType": "GWM",
            "Accept-Encoding": "gzip",
            "User-Agent": GwmCrypto.officialUserAgent,
        ]
    }

    // MARK: - 响应解包

    private func decodeGAppResponse(_ resp: HTTPResult, _ operation: String) throws -> Any? {
        try checkHttp(resp, operation)
        guard let root = try? JSONSerialization.jsonObject(with: Data(resp.body.utf8)),
              let map = root as? [String: Any] else {
            throw GwmError.schema("\(operation): 响应不是 JSON 对象")
        }

        if let code = ciString(map, "code"), !code.isEmpty,
           code != "0", code != "000000", code != "200" {
            if code == "1013" {
                throw GwmError.riskControl("触发风控（1013），请在官方 APP 完成验证后再试")
            }
            var desc = ciString(map, "description") ?? ciString(map, "msg")
            if desc == nil || desc!.isEmpty {
                // 有些网关错误（如 70000000）不带描述。附上原始响应片段，
                // 否则用户只看到一个光秃秃的错误码，无从判断。
                desc = "响应: " + Self.summarizeBody(resp.body)
            }
            throw GwmError.auth("\(operation): API 返回错误码 \(code) \(desc!)".trimmed)
        }

        var data: Any? = ciProp(map, "data") ?? map
        if let s = data as? String, s.hasPrefix("G_A(") {
            let plain = try GwmCrypto.decryptEnvelope(s)
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(plain.utf8)) else {
                throw GwmError.schema("\(operation): G_A 信封解密失败")
            }
            data = parsed
        }
        return data
    }

    private func decodeAutoAiResponse(_ resp: HTTPResult, _ operation: String) throws -> Any? {
        try checkHttp(resp, operation)
        guard let root = try? JSONSerialization.jsonObject(with: Data(resp.body.utf8)),
              let map = root as? [String: Any] else {
            throw GwmError.schema("\(operation): 响应不是 JSON 对象")
        }
        guard let headerObj = ciProp(map, "header") else {
            // 无 header → 按 G-App 信封解
            return try decodeGAppResponse(resp, operation)
        }
        let header = asMap(headerObj)
        if let code = header.flatMap({ ciString($0, "c") }), !code.isEmpty, code != "0" {
            if code == "1013" {
                throw GwmError.riskControl("触发风控（1013），请在官方 APP 完成验证后再试")
            }
            let msg = header.flatMap { ciString($0, "m") } ?? ""
            if code == "-114" {
                throw GwmError.auth("\(operation): 上一条远控还在执行中（-114 \(msg)）。车端执行一条远控通常需要 10~30 秒，请稍候再按")
            }
            throw GwmError.auth("\(operation): AutoAI 返回错误码 \(code) \(msg)".trimmed)
        }
        return ciProp(map, "body") ?? map
    }

    private func checkHttp(_ resp: HTTPResult, _ operation: String) throws {
        if resp.statusCode == 401 || resp.statusCode == 403 {
            throw GwmError.auth("\(operation): 认证失败（HTTP \(resp.statusCode)）")
        }
        guard (200...299).contains(resp.statusCode) else {
            throw GwmError.connection("\(operation): HTTP \(resp.statusCode)")
        }
    }

    /// 摘要响应体用于错误信息：压成单行、截断，避免日志爆掉。
    private static func summarizeBody(_ body: String) -> String {
        let one = body.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if one.isEmpty { return "(空)" }
        return one.count > 160 ? String(one.prefix(160)) + "…" : one
    }

    // MARK: - 编码

    /// 路径/参数段编码（保留 -_.~ 与字母数字）。
    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// 整个 payload 做 URL 编码（对应 Python 的 quote(payload, safe="")）。
    private func urlEncodeFull(_ value: String) -> String {
        urlEncode(value).replacingOccurrences(of: "*", with: "%2A")
            .replacingOccurrences(of: "%7E", with: "~")
    }

    // MARK: - 通用小工具

    private func asMap(_ o: Any?) -> [String: Any]? {
        o as? [String: Any]
    }

    /// 大小写不敏感取属性（原始值）。
    private func ciProp(_ obj: Any?, _ name: String) -> Any? {
        guard let map = asMap(obj) else { return nil }
        let folded = name.lowercased()
        for (k, v) in map where k.lowercased() == folded {
            return v
        }
        return nil
    }

    /// 与 Python str() 对齐的值转字符串：JSON 解析出的数字若为整数，
    /// 不能带 ".0" 后缀，否则与 Python 原版不一致。
    private func valueToStr(_ v: Any?) -> String? {
        guard let v = v else { return nil }
        if v is NSNull { return nil }
        if let n = v as? NSNumber {
            // Bool 会被当成 NSNumber，单独排除
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            let d = n.doubleValue
            if d == d.rounded() && !d.isInfinite && abs(d) < 9.0e15 {
                return String(n.int64Value)
            }
            return n.stringValue
        }
        if let s = v as? String { return s }
        return String(describing: v)
    }

    private func ciString(_ obj: Any?, _ name: String) -> String? {
        guard let v = ciProp(obj, name) else { return nil }
        guard let s = valueToStr(v) else { return nil }
        return s.isEmpty ? nil : s
    }
}
