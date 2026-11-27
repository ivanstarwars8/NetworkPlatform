// UNVERIFIED: written on Linux, never compiled or run — requires macOS + Xcode
//
// One HTTPS GET for the timing and certificate tools: URLSession records the phases
// (URLSessionTaskMetrics → NetworkToolbox.HTTPTimestamps), the server-trust challenge hands over the
// certificate chain, which is summarised by NetworkToolbox.CertificateParser, and the system's own trust
// evaluation decides "trusted". The body is read up to HTTPProbeLimits.maximumBodyBytes, then the request is
// cancelled. A fresh ephemeral session per probe: no cache, no cookies, no credentials, no reused connection.

import Foundation
import NetworkToolbox
import Security

struct HTTPSProbeResult: Sendable {
    var statusCode: Int?
    var protocolName: String?
    var remoteAddress: String?
    var timestamps: HTTPTimestamps?
    var bytesRead: Int = 0
    var truncated = false
    var chain: [CertificateSummary] = []
    var trusted: Bool?
    var trustFailure: String?
    var error: String?
}

final class HTTPSProbe: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var result = HTTPSProbeResult()
    private var continuation: CheckedContinuation<HTTPSProbeResult, Never>?
    private var finished = false

    /// Runs one request. Never throws: failures are described in the result.
    static func run(_ url: URL) async -> HTTPSProbeResult {
        let probe = HTTPSProbe()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = HTTPProbeLimits.timeout
        configuration.timeoutIntervalForResource = HTTPProbeLimits.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: probe, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<HTTPSProbeResult, Never>) in
            probe.lock.lock()
            probe.continuation = continuation
            probe.lock.unlock()
            session.dataTask(with: request).resume()
        }
        // The session retains its delegate until invalidated.
        session.invalidateAndCancel()
        return outcome
    }

    // MARK: Delegate

    // The async forms of the challenge and response callbacks: they match the Objective-C requirements
    // whatever Sendable annotations the SDK gives the completion handlers.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            // Client certificates, HTTP authentication: not offered by the tool.
            return (.cancelAuthenticationChallenge, nil)
        }
        let certificates = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let chain = certificates.compactMap { certificate -> CertificateSummary? in
            let data = SecCertificateCopyData(certificate) as Data
            return CertificateParser.summary(der: Array(data))
        }
        var trustError: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &trustError)
        record { result in
            result.chain = chain
            result.trusted = trusted
            if let trustError = trustError {
                result.trustFailure = CFErrorCopyDescription(trustError) as String?
            }
        }
        // The system decides: an untrusted chain ends the request after the chain was recorded.
        return (.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse
    ) async -> URLSession.ResponseDisposition {
        let status = (response as? HTTPURLResponse)?.statusCode
        record { $0.statusCode = status }
        return .allow
    }

    private func record(_ change: (inout HTTPSProbeResult) -> Void) {
        lock.lock()
        change(&result)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        result.bytesRead += data.count
        let over = result.bytesRead >= HTTPProbeLimits.maximumBodyBytes
        if over { result.truncated = true }
        lock.unlock()
        if over { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        let stamps = HTTPTimestamps(
            fetchStart: transaction.fetchStartDate,
            domainLookupStart: transaction.domainLookupStartDate,
            domainLookupEnd: transaction.domainLookupEndDate,
            connectStart: transaction.connectStartDate,
            secureConnectionStart: transaction.secureConnectionStartDate,
            secureConnectionEnd: transaction.secureConnectionEndDate,
            connectEnd: transaction.connectEndDate,
            requestStart: transaction.requestStartDate,
            responseStart: transaction.responseStartDate,
            responseEnd: transaction.responseEndDate,
            reusedConnection: transaction.isReusedConnection
        )
        lock.lock()
        result.timestamps = stamps
        result.protocolName = transaction.networkProtocolName
        if let address = transaction.remoteAddress {
            if let port = transaction.remotePort {
                result.remoteAddress = SocketEndpoint(address: address, port: UInt16(clamping: port))?.displayText ?? address
            } else {
                result.remoteAddress = address
            }
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        if let error = error as NSError? {
            let cancelledByLimit = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled && result.truncated
            if !cancelledByLimit {
                result.error = Self.describe(error)
            }
        }
        let continuation = finished ? nil : self.continuation
        finished = true
        self.continuation = nil
        let value = result
        lock.unlock()
        continuation?.resume(returning: value)
    }

    private static func describe(_ error: NSError) -> String {
        guard error.domain == NSURLErrorDomain else { return error.localizedDescription }
        switch error.code {
        case NSURLErrorTimedOut: return "Сервер не ответил за \(Int(HTTPProbeLimits.timeout)) с."
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "Имя узла не разрешилось. Проверьте адрес."
        case NSURLErrorCannotConnectToHost: return "Соединение отклонено: на порту никто не слушает."
        case NSURLErrorNotConnectedToInternet: return "Нет подключения к сети."
        case NSURLErrorSecureConnectionFailed: return "Не удалось установить TLS-соединение."
        case NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
             NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return "Система не доверяет сертификату сервера, запрос остановлен."
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "Система запретила соединение: требуются современные настройки TLS."
        default: return error.localizedDescription
        }
    }
}
