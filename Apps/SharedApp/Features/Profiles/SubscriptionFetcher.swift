// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// Downloads subscription bodies for `SubscriptionManager` (Packages/ProfileLibrary). Ephemeral session: the
// address often carries an access token, so nothing is cached and no cookies are kept. Sends only the
// conditional headers of the last success; the HTTP rules (status, size, encoding) are
// `SubscriptionHTTP.interpret`, unit-tested on Linux. Errors name the status or the error code, never the
// address.

import Foundation
import ProfileLibrary

struct URLSessionSubscriptionFetcher: SubscriptionFetching {
    func fetch(_ url: URL, headers: [String: String]) async throws -> SubscriptionHTTP.Result {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = SubscriptionHTTP.timeoutSeconds
        configuration.timeoutIntervalForResource = SubscriptionHTTP.timeoutSeconds * 2
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: SubscriptionHTTP.timeoutSeconds)
        request.httpMethod = "GET"
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch let error as URLError {
            throw SubscriptionHTTP.Failure("ошибка сети \(error.code.rawValue)")
        } catch {
            throw SubscriptionHTTP.Failure("ошибка загрузки (\(type(of: error)))")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SubscriptionHTTP.Failure("ответ не HTTP")
        }
        var headerFields: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headerFields[key] = value }
        }
        // Reads at most one byte past the limit, so an oversized body is refused without holding it all.
        var body = Data()
        if http.statusCode != 304 {
            let declared = http.expectedContentLength
            if declared > Int64(SubscriptionHTTP.maximumBodyBytes) {
                return try SubscriptionHTTP.interpret(status: http.statusCode, headers: headerFields, body: Data(), declaredLength: declared)
            }
            do {
                for try await byte in bytes {
                    body.append(byte)
                    if body.count > SubscriptionHTTP.maximumBodyBytes { break }
                }
            } catch let error as URLError {
                throw SubscriptionHTTP.Failure("ошибка сети \(error.code.rawValue)")
            }
        }
        return try SubscriptionHTTP.interpret(status: http.statusCode, headers: headerFields, body: body)
    }
}
