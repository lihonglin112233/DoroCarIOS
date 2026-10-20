import Foundation
import CommonCrypto

/// GWM 中国区云服务的协议底层工具：JSON 序列化 / AES 信封 / 各层签名。
///
/// 移植自 Android 版 `GwmCrypto.java`（其本身移植自 gwm_cn_ha）。
/// 所有签名逻辑必须**逐字节对齐**，否则服务端校验直接失败，
/// 因此这里刻意不使用 `JSONSerialization` 生成请求体。
///
/// 三处最容易踩的坑：
/// 1. `encodeDotnetJson` —— 服务端用 System.Text.Json 序列化，会把
///    `" & ' + < > `` ` `` 转成 `\u00XX`，且非 ASCII 全部转 `\uXXXX`。
///    用普通 JSON 库生成的 body 签名对不上。
/// 2. `encryptEnvelope` —— OpenSSL `Salted__` 格式，密钥是 MD5 迭代派生
///    （不是标准 PBKDF2）。
/// 3. `beanTechSign` —— 先 Java 风格 URL 编码，再把编码结果里的空白字符删掉，
///    顺序不能反。
enum GwmCrypto {

    // MARK: - 协议常量（逆向自官方 APP）

    static let defaultNoteId = "145765423214576567716671"
    static let beanTechAppKey = "7863128529"
    static let autoAiCkey = "ea49a50f914b8d38af1c84809d302683"

    static let sourceAppVersion = "2.1.5"
    static let sourceAppCode = "2150"
    static let officialUserAgent = "okhttp/4.2.2"
    static let gAppAppId = "GWM-APP-ANDROID-1100018"

    private static let secret32 = "E3*138%pb=GcflmhmsaA4WU^J-f&0Ofe"
    private static let secret36 = "t8X_MybKFjp-Kg^mt99ALe-ArGzJE5mpCOra"
    private static let beanTechSecret = "21382b32fea1d5fa03813d806d2dd64f"
    private static let autoAiPrivateKey = "dad377585f566b548c961a418dcec41a"

    /// G_A 信封的 OpenSSL 口令，keyId 1/2 两套
    private static let envelopePasswords: [Int: String] = [
        1: "Qin.1^0123456789abcdef0123456789abcdef0123456789abcdef012345cdef",
        2: "Gwn*9$0123456789abcdef0123456789abcdef0189abcdef0123456789abcdef",
    ]

    private static let opensslMagic = Array("Salted__".utf8)

    // MARK: - 摘要 / 编码

    static func sha256Hex(_ value: String) -> String {
        bytesToHex(sha256(Array(value.utf8)))
    }

    static func md5Hex(_ value: String) -> String {
        bytesToHex(md5(Array(value.utf8)))
    }

    static func sha256(_ data: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        if data.isEmpty {
            CC_SHA256(UnsafeRawPointer([]), 0, &digest)
        } else {
            data.withUnsafeBytes { buf in
                _ = CC_SHA256(buf.baseAddress, CC_LONG(data.count), &digest)
            }
        }
        return digest
    }

    static func md5(_ data: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        if data.isEmpty {
            CC_MD5(UnsafeRawPointer([]), 0, &digest)
        } else {
            data.withUnsafeBytes { buf in
                _ = CC_MD5(buf.baseAddress, CC_LONG(data.count), &digest)
            }
        }
        return digest
    }

    /// 小写十六进制
    static func bytesToHex(_ bytes: [UInt8]) -> String {
        let table: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                  "8", "9", "a", "b", "c", "d", "e", "f"]
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(table[Int(b >> 4)])
            out.append(table[Int(b & 0x0F)])
        }
        return out
    }

    /// 大写十六进制
    static func toHexUpper(_ bytes: [UInt8]) -> String {
        let table: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                  "8", "9", "A", "B", "C", "D", "E", "F"]
        var out = ""
        out.reserveCapacity(bytes.count * 2)
        for b in bytes {
            out.append(table[Int(b >> 4)])
            out.append(table[Int(b & 0x0F)])
        }
        return out
    }

    // MARK: - .NET 风格 JSON

    /// 按 .NET `System.Text.Json` 默认风格序列化。
    ///
    /// 与常规 JSON 的差异（都会影响签名）：
    /// - 无任何空格
    /// - 非 ASCII 一律 `\uXXXX`（BMP 内 4 位；超出的用代理对）
    /// - HTML 敏感字符 `" & ' + < > ` `` ` `` 转义为 `\u00XX`
    /// - 只对 `\b \t \n \f \r \\` 用短转义
    static func encodeDotnetJson(_ value: Any?) -> String {
        var out = ""
        out.reserveCapacity(128)
        writeDotnetJson(&out, value, depth: 0)
        return out
    }

    private static func writeDotnetJson(_ out: inout String, _ value: Any?, depth: Int) {
        precondition(depth <= 32, "json_depth_invalid")
        guard let value = value else {
            out += "null"
            return
        }
        if let b = value as? Bool {
            out += b ? "true" : "false"
            return
        }
        if let s = value as? String {
            writeDotnetString(&out, s)
            return
        }
        if let n = value as? NSNumber {
            // 区分 bool 已在上面处理；这里按数值输出，整数不带 ".0"
            let d = n.doubleValue
            if d == d.rounded() && !d.isInfinite && abs(d) < 9.0e15 {
                out += String(Int64(d))
            } else {
                out += formatDouble(d)
            }
            return
        }
        if let d = value as? Double {
            if d == d.rounded() && !d.isInfinite && abs(d) < 9.0e15 {
                out += String(Int64(d))
            } else {
                out += formatDouble(d)
            }
            return
        }
        if let i = value as? Int {
            out += String(i)
            return
        }
        if let arr = value as? [Any] {
            out += "["
            for (i, child) in arr.enumerated() {
                if i > 0 { out += "," }
                writeDotnetJson(&out, child, depth: depth + 1)
            }
            out += "]"
            return
        }
        if let dict = value as? [String: Any] {
            // 字典顺序不稳定，调用方一律用有序结构传入；
            // 这里按 key 排序保证可复现（仅在误用 [String: Any] 时生效）
            out += "{"
            for (i, key) in dict.keys.sorted().enumerated() {
                if i > 0 { out += "," }
                writeDotnetString(&out, key)
                out += ":"
                writeDotnetJson(&out, dict[key], depth: depth + 1)
            }
            out += "}"
            return
        }
        if let ordered = value as? OrderedJSON {
            out += "{"
            for (i, pair) in ordered.pairs.enumerated() {
                if i > 0 { out += "," }
                writeDotnetString(&out, pair.key)
                out += ":"
                writeDotnetJson(&out, pair.value, depth: depth + 1)
            }
            out += "}"
            return
        }
        // 兜底：当作字符串
        writeDotnetString(&out, String(describing: value))
    }

    /// Java 的 `Double.toString` 近似：整数补 `.0`，其余用最短往返表示。
    private static func formatDouble(_ d: Double) -> String {
        if d == d.rounded() && !d.isInfinite && abs(d) < 9.0e15 {
            return String(Int64(d)) + ".0"
        }
        return String(d)
    }

    /// HTML 敏感字符集合（.NET 默认 encoder 会转义这些）
    private static func isHtmlSensitive(_ c: Character) -> Bool {
        switch c {
        case "\"", "&", "'", "+", "<", ">", "`": return true
        default: return false
        }
    }

    static func writeDotnetString(_ out: inout String, _ value: String) {
        out += "\""
        for ch in value {
            switch ch {
            case "\u{08}": out += "\\b"; continue
            case "\t": out += "\\t"; continue
            case "\n": out += "\\n"; continue
            case "\u{0C}": out += "\\f"; continue
            case "\r": out += "\\r"; continue
            case "\\": out += "\\\\"; continue
            default: break
            }
            let scalars = ch.unicodeScalars
            let code = scalars.first!.value
            if code >= 0x20 && code <= 0x7E && !isHtmlSensitive(ch) {
                out.append(ch)
            } else if code > 0xFFFF {
                // 增补平面：拆成代理对输出两个 \uXXXX
                let v = code - 0x10000
                appendUnicode(&out, 0xD800 + (v >> 10))
                appendUnicode(&out, 0xDC00 + (v & 0x3FF))
            } else {
                appendUnicode(&out, code)
            }
        }
        out += "\""
    }

    private static func appendUnicode(_ out: inout String, _ code: UInt32) {
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                "8", "9", "A", "B", "C", "D", "E", "F"]
        out += "\\u"
        out.append(hex[Int((code >> 12) & 0xF)])
        out.append(hex[Int((code >> 8) & 0xF)])
        out.append(hex[Int((code >> 4) & 0xF)])
        out.append(hex[Int(code & 0xF)])
    }

    // MARK: - OpenSSL 密钥派生

    /// OpenSSL `EVP_BytesToKey` 的 MD5 变体：
    /// 迭代 MD5 拼到 48 字节，前 32 字节作 key、后 16 字节作 IV。
    static func deriveOpenSslKeyIv(password: String, salt: [UInt8]) -> (key: [UInt8], iv: [UInt8]) {
        let pw = Array(password.utf8)
        var derived: [UInt8] = []
        derived.reserveCapacity(48)
        var previous: [UInt8] = []
        while derived.count < 48 {
            var input: [UInt8] = []
            input.append(contentsOf: previous)
            input.append(contentsOf: pw)
            input.append(contentsOf: salt)
            previous = md5(input)
            derived.append(contentsOf: previous)
        }
        return (Array(derived[0..<32]), Array(derived[32..<48]))
    }

    // MARK: - G_A 信封（AES-CBC）

    /// 用指定 keyId 与 salt 加密成 `G_A(BASE64,keyId)` 信封。
    static func encryptEnvelope(_ plaintext: String, keyId: Int, salt: [UInt8]) throws -> String {
        guard let password = envelopePasswords[keyId] else {
            throw GwmError.crypto("未知 keyId: \(keyId)")
        }
        let (key, iv) = deriveOpenSslKeyIv(password: password, salt: salt)
        let cipher = try aesCBC(encrypt: true, key: key, iv: iv, data: Array(plaintext.utf8))
        var payload: [UInt8] = []
        payload.append(contentsOf: opensslMagic)
        payload.append(contentsOf: salt)
        payload.append(contentsOf: cipher)
        return "G_A(" + Data(payload).base64EncodedString() + "," + String(keyId) + ")"
    }

    /// 随机 salt 版本
    static func encryptEnvelope(_ plaintext: String, keyId: Int) throws -> String {
        var salt = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, 8, &salt)
        return try encryptEnvelope(plaintext, keyId: keyId, salt: salt)
    }

    /// 解开 `G_A(...)` 信封。不是信封则原样返回（服务端有时返回明文 JSON）。
    static func decryptEnvelope(_ wrapped: String) throws -> String {
        guard wrapped.hasPrefix("G_A("), wrapped.hasSuffix(")") else { return wrapped }
        guard let comma = wrapped.lastIndex(of: ",") else {
            throw GwmError.crypto("G_A 信封格式错误")
        }
        let keyIdText = wrapped[wrapped.index(after: comma)..<wrapped.index(before: wrapped.endIndex)]
        guard let keyId = Int(keyIdText.trimmingCharacters(in: .whitespaces)),
              let password = envelopePasswords[keyId] else {
            throw GwmError.crypto("G_A keyId 非法")
        }
        var b64 = String(wrapped[wrapped.index(wrapped.startIndex, offsetBy: 4)..<comma])
        b64 = b64.components(separatedBy: .whitespacesAndNewlines).joined()
        guard let encrypted = Data(base64Encoded: b64) else {
            throw GwmError.crypto("G_A 载荷格式错误")
        }
        let bytes = [UInt8](encrypted)
        guard bytes.count >= 32, bytes.count % 16 == 0 else {
            throw GwmError.crypto("G_A 载荷格式错误")
        }
        guard Array(bytes[0..<8]) == opensslMagic else {
            throw GwmError.crypto("G_A 载荷格式错误")
        }
        let salt = Array(bytes[8..<16])
        let cipherText = Array(bytes[16...])
        let (key, iv) = deriveOpenSslKeyIv(password: password, salt: salt)
        let plain = try aesCBC(encrypt: false, key: key, iv: iv, data: cipherText)
        guard let text = String(bytes: plain, encoding: .utf8) else {
            throw GwmError.crypto("G_A 解密失败：非 UTF-8")
        }
        return text
    }

    private static func aesCBC(encrypt: Bool, key: [UInt8], iv: [UInt8], data: [UInt8]) throws -> [UInt8] {
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let outLength = data.count + kCCBlockSizeAES128
        var out = [UInt8](repeating: 0, count: outLength)
        var moved = 0
        let status = key.withUnsafeBytes { keyBuf -> CCCryptorStatus in
            iv.withUnsafeBytes { ivBuf -> CCCryptorStatus in
                data.withUnsafeBytes { dataBuf -> CCCryptorStatus in
                    CCCrypt(operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            data.isEmpty ? nil : dataBuf.baseAddress, data.count,
                            &out, outLength, &moved)
                }
            }
        }
        guard status == kCCSuccess else {
            throw GwmError.crypto("AES 失败（CCCrypt status=\(status)）")
        }
        return Array(out[0..<moved])
    }

    // MARK: - 签名

    /// G-App 的派生密钥：时间戳奇偶决定是否对 36 字节密钥做 6x6 矩阵转置。
    static func deriveSecret(timestampText: String, deviceId: String?, authorization: String?) -> String {
        let timestamp = Int64(timestampText.trimmingCharacters(in: .whitespaces)) ?? 0
        let index = Int((timestamp % 100_000) % 32)
        var source = secret36
        if (timestamp & 1) == 1 {
            // 奇数时间戳：6x6 矩阵转置
            var sb = ""
            let chars = Array(secret36)
            for column in 0..<6 {
                for row in 0..<6 {
                    sb.append(chars[row * 6 + column])
                }
            }
            source = sb
        }
        let repeated = source + source
        let secretSelection = substring(repeated, from: index, length: 6) ?? ""

        let deviceOffset = Int(timestamp % 8)
        let device = deviceId ?? ""
        let deviceSelection = substring(device, from: deviceOffset, length: 6) ?? ""

        let trimmed = (authorization ?? "").trimmingCharacters(in: .whitespaces)
        let authSelection = trimmed.count > 9 ? (substring(trimmed, from: 3, length: 6) ?? "") : ""

        return secret32 + secretSelection + deviceSelection + authSelection
    }

    /// 按 **Character（可见字符）** 下标取子串，与 Java 的 `String.substring` 对齐。
    static func substring(_ s: String, from offset: Int, length: Int) -> String? {
        let chars = Array(s)
        guard offset >= 0, offset + length <= chars.count else { return nil }
        return String(chars[offset..<(offset + length)])
    }

    /// G-App 服务签名（`Sign` 头）。
    ///
    /// 规范化串 = METHOD + URL + 8 个 `name:value` + (非 GET 才有) `json=body`
    /// + 派生密钥，最后 SHA-256 小写十六进制。
    static func defaultSign(method: String, signingUrl: String, rawBody: String?,
                            headers: [String: String]) -> String {
        let timestamp = headers["Timestamp"] ?? ""
        let authorization = headers["Authorization"] ?? ""
        let deviceId = headers["DeviceId"] ?? ""

        var canonical = method.uppercased() + signingUrl
        let names = ["AppId", "Authorization", "DeviceId", "NoteId",
                     "SourceApp", "SourceAppVer", "SourceType", "Timestamp"]
        for name in names {
            canonical += name.lowercased() + ":" + (headers[name] ?? "")
        }
        if method.uppercased() != "GET" {
            canonical += "json=" + (rawBody ?? "")
        }
        canonical += deriveSecret(timestampText: timestamp, deviceId: deviceId,
                                  authorization: authorization)
        return sha256Hex(canonical)
    }

    /// Java 风格 URL 编码：只保留字母数字与 `-_.*`，空格转 `+`，其余 `%XX`。
    static func javaUrlEncode(_ value: String) -> String {
        let hex: [Character] = ["0", "1", "2", "3", "4", "5", "6", "7",
                                "8", "9", "A", "B", "C", "D", "E", "F"]
        var out = ""
        out.reserveCapacity(value.utf8.count * 2)
        for octet in value.utf8 {
            let c = Int(octet)
            let keep = (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A)
                || (c >= 0x30 && c <= 0x39)
                || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x2A
            if keep {
                out.append(Character(UnicodeScalar(UInt8(c))))
            } else if c == 0x20 {
                out.append("+")
            } else {
                out.append("%")
                out.append(hex[c >> 4])
                out.append(hex[c & 0x0F])
            }
        }
        return out
    }

    /// BeanTech 网关签名（`bt-auth-sign` 头）。
    ///
    /// 注意顺序：先按 Java 风格 URL 编码，**再把编码结果里的空白字符删掉**。
    static func beanTechSign(method: String, path: String, nonce: String,
                            timestamp: String, parameter: String) -> String {
        var decodedPath = "/"
        var first = true
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if !first { decodedPath += "/" }
            first = false
            decodedPath += urlDecode(String(part))
        }
        let authorization = "bt-auth-appkey:" + beanTechAppKey
            + "bt-auth-nonce:" + nonce
            + "bt-auth-timestamp:" + timestamp

        var encoded = javaUrlEncode(method.uppercased() + decodedPath + authorization
                                    + parameter + beanTechSecret)
        encoded = encoded.replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "%20", with: "")
            .replacingOccurrences(of: "%0A", with: "")
            .replacingOccurrences(of: "%09", with: "")
            .replacingOccurrences(of: "%0D", with: "")
        return sha256Hex(encoded)
    }

    /// 严格按 UTF-8 解码 `%XX`；用于 BeanTech 路径还原。
    static func urlDecode(_ value: String) -> String {
        guard value.contains("%") else { return value }
        let chars = Array(value)
        var bytes: [UInt8] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "%", i + 2 < chars.count,
               isHex(chars[i + 1]), isHex(chars[i + 2]) {
                let hexStr = String(chars[(i + 1)...(i + 2)])
                bytes.append(UInt8(hexStr, radix: 16) ?? 0)
                i += 3
            } else {
                bytes.append(contentsOf: Array(String(c).utf8))
                i += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? value
    }

    private static func isHex(_ c: Character) -> Bool {
        switch c {
        case "0"..."9", "a"..."f", "A"..."F": return true
        default: return false
        }
    }

    /// AutoAI 的 HMAC-SHA1 签名（`sign` 头），输出 Base64。
    static func autoAiSign(timestamp: String) -> String {
        let key = "C_KEY=" + autoAiCkey + "&API_KEY=" + autoAiPrivateKey
        let message = "SIGN_BODY=[]&SIGN_TIME=" + timestamp
        let mac = hmacSHA1(key: Array(key.utf8), message: Array(message.utf8))
        return Data(mac).base64EncodedString()
    }

    private static func hmacSHA1(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        key.withUnsafeBytes { keyBuf in
            message.withUnsafeBytes { msgBuf in
                CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA1),
                       keyBuf.baseAddress, key.count,
                       msgBuf.baseAddress, message.count,
                       &digest)
            }
        }
        return digest
    }

    // MARK: - 杂项

    /// AutoAI 时间戳：yyyyMMddHHmmss + 3 位毫秒（UTC+8）。
    static func chinaTimestamp() -> String {
        let now = Date()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        let millis = Int((now.timeIntervalSince1970 * 1000).truncatingRemainder(dividingBy: 1000))
        return String(format: "%04d%02d%02d%02d%02d%02d%03d",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis)
    }

    /// 16 位小写十六进制 nonce（SHA-256 前 16 位）。
    static func randomNonce() -> String {
        var raw = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &raw)
        return String(sha256Hex(toHexUpper(raw)).prefix(16))
    }

    /// BeanTech 的 seqNo：32 位十六进制 + 4 位随机数。
    static func randomSequence() -> String {
        var raw = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &raw)
        var suffix: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, 4, &suffix)
        let tail = 1000 + Int(suffix % 9000)
        return bytesToHex(raw) + String(tail)
    }

    /// 设备 ID：32 位大写十六进制。
    static func randomDeviceId() -> String {
        var raw = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &raw)
        return toHexUpper(raw)
    }

    /// 递归把 JSON 对象的所有 key 转小写（v2.0 / v3.0 网关大小写不一致）。
    static func normalizeKeys(_ obj: Any?) -> Any? {
        if let dict = obj as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                out[k.lowercased()] = normalizeKeys(v)
            }
            return out
        }
        if let arr = obj as? [Any] {
            return arr.map { normalizeKeys($0) }
        }
        return obj
    }
}

/// 有序 JSON 对象：字典在 Swift 里无序，而服务端签名依赖字段顺序，
/// 因此请求体一律用这个类型构造。
struct OrderedJSON {
    private(set) var pairs: [(key: String, value: Any?)] = []

    init() {}

    init(_ pairs: [(String, Any?)]) {
        self.pairs = pairs
    }

    /// 链式追加
    func adding(_ key: String, _ value: Any?) -> OrderedJSON {
        var copy = self
        copy.pairs.append((key, value))
        return copy
    }

    mutating func set(_ key: String, _ value: Any?) {
        pairs.append((key, value))
    }

    mutating func merge(_ other: [String: Any]) {
        for (k, v) in other {
            pairs.append((k, v))
        }
    }
}
