import Foundation

/// 统一错误类型。对应 Android 版的 GwmClient 四个内部异常类。
enum GwmError: LocalizedError {
    /// 认证失败（token 无效、验证码错误、会话过期）
    case auth(String)
    /// 网络或 HTTP 层失败
    case connection(String)
    /// 风控挑战（1013）：需要在官方 APP 完成验证
    case riskControl(String)
    /// 响应结构异常
    case schema(String)
    /// 协议底层（加密、签名）失败
    case crypto(String)

    var errorDescription: String? {
        switch self {
        case .auth(let m): return m
        case .connection(let m): return m
        case .riskControl(let m): return m
        case .schema(let m): return m
        case .crypto(let m): return m
        }
    }

    var isAuth: Bool {
        if case .auth = self { return true }
        return false
    }

    var isRiskControl: Bool {
        if case .riskControl = self { return true }
        return false
    }

    /// 把任意错误翻译成用户能看懂的中文。对应 Android 的 `friendly()`。
    static func friendly(_ error: Error) -> String {
        if let g = error as? GwmError {
            switch g {
            case .riskControl(let m):
                return m.contains("1013") ? "触发风控，请在官方 APP 完成验证后重试" : m
            case .auth(let m):
                return m.isEmpty ? "认证失败" : m
            case .connection(let m):
                return "网络异常：\(m)"
            case .schema(let m):
                return "数据异常：\(m)"
            case .crypto(let m):
                return "加密异常：\(m)"
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return "无法连接服务器，请检查网络"
            case NSURLErrorTimedOut:
                return "连接超时，请稍后重试"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                return "无法连接服务器，请检查网络"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "HTTPS 证书校验失败"
            default:
                return "网络异常：\(ns.localizedDescription)"
            }
        }
        return ns.localizedDescription
    }
}

/// 一次 HTTP 调用的结果
struct HTTPResult {
    let statusCode: Int
    let body: String
}

/// 极简 HTTP 客户端。
///
/// Android 版用 `HttpURLConnection`；这里换成 `URLSession` + async/await。
/// 刻意保留两个 Android 版的行为细节，否则服务端会不高兴：
/// - **不自动跟随重定向**（`HttpURLConnection.setInstanceFollowRedirects(false)`）；
/// - 按 gzip 解压（请求头显式带 `Accept-Encoding: gzip`）。
final class HTTPClient {

    private let session: URLSession

    init(timeoutSeconds: Int = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = TimeInterval(max(5, timeoutSeconds))
        config.timeoutIntervalForResource = TimeInterval(max(5, timeoutSeconds) * 2)
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 让 URLSession 自己处理 gzip；我们仍显式发 Accept-Encoding
        config.httpAdditionalHeaders = nil
        session = URLSession(configuration: config,
                             delegate: NoRedirectDelegate(),
                             delegateQueue: nil)
    }

    func send(method: String, url: URL, headers: [String: String], body: String?) async throws -> HTTPResult {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = TimeInterval(max(5, session.configuration.timeoutIntervalForRequest))
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let body = body {
            request.httpBody = Data(body.utf8)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GwmError.connection(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw GwmError.connection("响应不是 HTTP")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return HTTPResult(statusCode: http.statusCode, body: text)
    }
}

/// 禁止自动重定向：远控请求带一次性签名，跟随重定向会导致签名失效。
private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
