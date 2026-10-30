import CoreGraphics
import Foundation
import ImageIO
import Security

// Twin of windows/LazyScan.Core/Escl/EsclClient.cs: the same job rules and the same tests
// (EsclClientTests), on URLSession. Deliberate differences: each page is downloaded to a file in the
// page spool and read from there, so its compressed bytes are never held in memory next to its pixels;
// a job also stops when the system is about to suspend the app (`suspended`, the iPhone only), keeping
// the pages received; the transport, page directory and page reader are options rather than
// constructor arguments; `ScanError.scannerProblem` carries no detail text, so the "(HTTP 409)" the C#
// error message ends with is only in a stopped batch's reason here.

/// Timeouts, retry timing and transport of an `EsclClient`. Twin of C# `EsclClientOptions`, with what
/// the C# client takes as constructor arguments (its handler and its image decoder).
public struct EsclClientOptions {
    /// Capabilities, status and delete requests: a device that does not answer this soon is treated as
    /// gone.
    public var requestTimeout: TimeInterval
    /// Job requests (the job itself and each page): some devices hold a NextDocument request open until
    /// the page has been scanned, which at high resolution takes far longer than other requests.
    public var jobTimeout: TimeInterval
    /// How long a client's first capabilities request waits for a usable network
    /// (`waitsForConnectivity`; on the iPhone, while the Local Network prompt is up). Every later
    /// request fails at once without one.
    public var connectivityWait: TimeInterval
    /// Waits between 503 answers.
    public var retryPolicy: EsclRetryPolicy
    /// How a retry waits; nil = real time (tests pass a fake clock).
    public var delay: ((TimeInterval) async throws -> Void)?
    /// Starts a clock for one request's retries, giving the time since its first attempt; nil = real
    /// time.
    public var startClock: (() -> (() -> TimeInterval))?
    /// The configuration the client's sessions are copied from; nil = `URLSessionConfiguration.ephemeral`.
    /// Tests add a URLProtocol stub to theirs.
    public var configuration: URLSessionConfiguration?
    /// Where pages are downloaded before they are read; nil = the app's page spool
    /// (`AppStateFiles.standard.spoolDirectory`).
    public var pageDirectory: URL?
    /// Reads a downloaded page; nil = ImageIO (`EsclPageReader.read`).
    public var readPage: ((URL) throws -> CGImage)?

    public init(requestTimeout: TimeInterval = 10, jobTimeout: TimeInterval = 120,
                connectivityWait: TimeInterval = 60, retryPolicy: EsclRetryPolicy = .default) {
        self.requestTimeout = requestTimeout
        self.jobTimeout = jobTimeout
        self.connectivityWait = connectivityWait
        self.retryPolicy = retryPolicy
        self.delay = nil
        self.startClock = nil
        self.configuration = nil
        self.pageDirectory = nil
        self.readPage = nil
    }
}

/// The pages one eSCL job delivered, and why it ended early when it did. Twin of C# `EsclJobResult`.
public struct EsclJobResult: @unchecked Sendable {
    public let pages: [ScannedPage]
    /// Set when a feeder job failed after its first page; the pages are kept.
    public let stop: ScanStop?

    public init(pages: [ScannedPage], stop: ScanStop?) {
        self.pages = pages
        self.stop = stop
    }
}

/// An eSCL request answered with an error status (C#: the `HttpRequestException` of `GetStringAsync`).
public struct EsclHttpError: Error, Equatable, LocalizedError, Sendable {
    public let statusCode: Int

    public init(statusCode: Int) {
        self.statusCode = statusCode
    }

    public var errorDescription: String? {
        "Response status code does not indicate success: \(statusCode)."
    }
}

/// Reads a page a scanner sent (JPEG, PNG, TIFF, ...) with ImageIO, decoded at once so its file can go.
public enum EsclPageReader {
    public static func read(_ file: URL) throws -> CGImage {
        guard let source: CGImageSource = CGImageSourceCreateWithURL(file as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw EsclFormatError("unknown image format")
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let image: CGImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) else {
            throw EsclFormatError("unknown image format")
        }
        return image
    }
}

/// The TLS check of an `EsclClient`'s sessions: the server trust challenge of each connection goes to
/// `validator` (C#: `EsclCertificateValidator.CreateHandler`). An accepted certificate is used as the
/// credential; a refused one cancels the connection before any request is sent, and the validator keeps
/// the refusal for the client to report. Without a validator the system decides. A redirect from HTTPS
/// to plain HTTP is never followed, as .NET never follows one.
public final class EsclTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    public let validator: EsclCertificateValidator?

    public init(validator: EsclCertificateValidator?) {
        self.validator = validator
        super.init()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space: URLProtectionSpace = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust: SecTrust = space.serverTrust,
              let validator = self.validator else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let systemTrusted: Bool = SecTrustEvaluateWithError(trust, nil)
        var certificateDER: Data?
        var subject: String = ""
        if let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first {
            certificateDER = SecCertificateCopyData(leaf) as Data
            if let summary = SecCertificateCopySubjectSummary(leaf) {
                subject = summary as String
            }
        }
        var url: URL? = task.currentRequest?.url
        if url == nil {
            url = task.originalRequest?.url
        }
        if validator.validate(url: url, certificateDER: certificateDER, subject: subject, systemTrusted: systemTrusted) {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let fromScheme: String = task.originalRequest?.url?.scheme?.lowercased() ?? ""
        let toScheme: String = request.url?.scheme?.lowercased() ?? ""
        if fromScheme == "https" && toScheme != "https" {
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }
}

/// The eSCL (AirScan) protocol over HTTP(S) for one scanner: capabilities, status, and scan jobs
/// (create, pull pages until the device reports the end, delete a job cut short). URLSession with an
/// ephemeral configuration: requests time out after `requestTimeout`, job requests after `jobTimeout`;
/// only the first capabilities request waits for connectivity; a job request is never sent twice by
/// the transport (only a 503 answer, which created no job, is asked again, as on Windows). Errors are
/// `ScanError`s, or an `EsclCertificateError` when `validator` refused the scanner's certificate.
/// Twin of C# `EsclClient`. Its sessions are released when the client is.
public final class EsclClient: @unchecked Sendable {
    /// The eSCL root, ending in a slash (`ScannerAddress.baseURL`).
    public let baseURL: URL
    /// The scanner's name in messages.
    public let deviceName: String
    public let validator: EsclCertificateValidator?

    private let options: EsclClientOptions
    private let pageDirectory: URL
    private let readPage: (URL) throws -> CGImage
    private let session: URLSession
    /// The first capabilities request's session: the same, waiting for connectivity.
    private let probeSession: URLSession
    private let lock = NSLock()
    private var probed = false
    private var cleanups: [Task<Void, Never>] = []
    private var currentJob: EsclJobRun?

    public init(baseURL: URL, deviceName: String, validator: EsclCertificateValidator? = nil,
                options: EsclClientOptions = EsclClientOptions()) {
        self.baseURL = baseURL
        self.deviceName = deviceName
        self.validator = validator
        self.options = options
        self.pageDirectory = options.pageDirectory ?? AppStateFiles.standard.spoolDirectory
        self.readPage = options.readPage ?? EsclPageReader.read
        let delegate: EsclTrustDelegate = EsclTrustDelegate(validator: validator)
        self.session = URLSession(configuration: EsclClient.makeConfiguration(options, waits: false),
                                  delegate: delegate, delegateQueue: nil)
        self.probeSession = URLSession(configuration: EsclClient.makeConfiguration(options, waits: true),
                                       delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
        probeSession.finishTasksAndInvalidate()
    }

    /// The device's ScannerCapabilities. Throws `URLError` (no answer, a timeout), `EsclHttpError` (an
    /// error status), `EsclFormatError` (not a capabilities document) or `EsclCertificateError`.
    public func getCapabilities() async throws -> EsclCapabilities {
        let url: URL = resolve("ScannerCapabilities")
        let target: URLSession = takeFirstProbe() ? probeSession : session
        let answer: EsclReply
        do {
            answer = try await EsclClient.fetch(makeRequest(url, method: "GET", timeout: options.requestTimeout), on: target)
        } catch {
            if let rejection = validator?.takeRejection() {
                throw rejection
            }
            throw error
        }
        guard (200..<300).contains(answer.status) else {
            throw EsclHttpError(statusCode: answer.status)
        }
        return try EsclCapabilitiesParser.parse(data: answer.data)
    }

    /// What the device's ScannerStatus says is wrong for `source`; nil when it says nothing or cannot be
    /// read. Throws only `CancellationError`, when the task is cancelled.
    public func getProblem(_ source: ScanSource) async throws -> ScannerProblem? {
        do {
            let answer: EsclReply = try await EsclClient.fetch(
                makeRequest(resolve("ScannerStatus"), method: "GET", timeout: options.requestTimeout), on: session)
            guard (200..<300).contains(answer.status) else {
                _ = validator?.takeRejection()
                return nil
            }
            guard let status: EsclScannerStatus = EsclScannerStatus.parse(data: answer.data) else {
                return nil
            }
            return status.problem(source)
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            _ = validator?.takeRejection()
            return nil // no status to go on: the caller reports the original failure
        }
    }

    /// Runs one scan job: posts `request`, then pulls page documents until the device answers 404 (the
    /// job is complete), retrying 503 answers (`EsclRetry`). Each page is downloaded to a file in the page
    /// directory, read, and its file removed.
    /// - A failure before the first page fails the scan, explained by the device's status when it names a
    ///   problem (an empty feeder, a jam, ...).
    /// - A failure after it (an error answer, a dropped or stalled connection, a page that cannot be read)
    ///   keeps the pages received and reports why in `EsclJobResult.stop`.
    /// - A job that ends without pages is reported as the device's problem when its status names one;
    ///   otherwise an empty page list is returned.
    /// - Any way out but the device's 404 (cancel, error, a batch cut short, the app suspended) deletes the
    ///   job on the device, so it stops feeding and the next scan does not find it busy.
    /// - Cancelling the task throws `ScanError.cancelled`; a request timing out is a communication error.
    ///   When `suspended` says the app is being suspended, a cancel keeps the pages received instead, with
    ///   the `appSuspended` stop (`ScanError.scannerProblem(.appSuspended)` before the first page).
    public func scan(_ request: EsclScanRequest, colorMode: ColorMode, source: ScanSource,
                     progress: ((ScanProgress) -> Void)?, suspended: (() -> Bool)? = nil) async throws -> EsclJobResult {
        do {
            return try await runJob(request, colorMode: colorMode, source: source, progress: progress, suspended: suspended)
        } catch let error as ScanError {
            throw error
        } catch let error as EsclCertificateError {
            throw error
        } catch {
            if Task.isCancelled || error is CancellationError {
                if let isSuspended = suspended, isSuspended() {
                    throw ScanError.scannerProblem(.appSuspended)
                }
                throw ScanError.cancelled
            }
            if let transport = error as? URLError, transport.code == .timedOut {
                // The request's own timeout: the device stopped answering.
                throw ScanError.scannerProblem(.communicationError)
            }
            throw ScanError.scanFailed(error.localizedDescription)
        }
    }

    /// The app is about to be suspended: sends the deletion of the job under way now rather than once the
    /// job winds down, which may be too late. The caller cancels the scan's task too.
    public func abandonJob() {
        lock.lock()
        let run: EsclJobRun? = currentJob
        lock.unlock()
        if let run {
            trackDeletion(of: run)
        }
    }

    /// Returns when the job deletions started so far have finished (they never fail).
    public func whenCleanedUp() async {
        var awaited: Int = 0
        while true {
            lock.lock()
            let pending: [Task<Void, Never>] = Array(cleanups[awaited...])
            lock.unlock()
            if pending.isEmpty {
                return
            }
            for cleanup in pending {
                await cleanup.value
            }
            awaited += pending.count
        }
    }

    // MARK: - Jobs

    private func runJob(_ request: EsclScanRequest, colorMode: ColorMode, source: ScanSource,
                        progress: ((ScanProgress) -> Void)?, suspended: (() -> Bool)?) async throws -> EsclJobResult {
        let scanJobs: URL = resolve("ScanJobs")
        let body: Data = Data(request.toXml().utf8)
        let jobAnswer: EsclReply
        do {
            jobAnswer = try await sendWithRetry {
                try await self.postJob(scanJobs, body: body)
            }
        } catch let error as URLError {
            if let rejection = validator?.takeRejection() {
                throw rejection
            }
            if Task.isCancelled || error.code == .timedOut {
                throw error
            }
            throw ScanError.scanFailed("Could not reach \(deviceName): \(error.localizedDescription)")
        }

        if jobAnswer.status != 201 {
            let failure: EsclJobFailure = try await jobFailure(
                source, status: jobAnswer.status, fallback: "\(deviceName) rejected the scan job (HTTP \(jobAnswer.status)).")
            throw failure.error
        }
        guard let jobURL: URL = EsclJob.resolveLocation(scanJobs, jobAnswer.location) else {
            throw ScanError.scanFailed("\(deviceName) accepted the scan job but did not say where to fetch it.")
        }

        let run: EsclJobRun = EsclJobRun(url: jobURL)
        setCurrentJob(run)
        var pages: [ScannedPage] = []
        var stop: ScanStop?
        var finished: Bool = false
        defer {
            setCurrentJob(nil)
            if !finished {
                trackDeletion(of: run)
            }
        }
        do {
            let next: URL = EsclJob.nextDocument(jobURL)
            pageLoop: while true {
                if Task.isCancelled {
                    throw CancellationError()
                }
                let answer: EsclReply
                do {
                    answer = try await sendWithRetry {
                        try await self.downloadPage(next)
                    }
                } catch {
                    if let rejection = validator?.takeRejection() {
                        throw rejection
                    }
                    if Task.isCancelled || error is CancellationError {
                        throw CancellationError()
                    }
                    var timedOut: Bool = false
                    if let transport = error as? URLError, transport.code == .timedOut {
                        timedOut = true
                    }
                    if pages.isEmpty {
                        if timedOut {
                            throw error
                        }
                        throw ScanError.scanFailed(error.localizedDescription)
                    }
                    // A dropped connection, or the device stalled on this page.
                    stop = ScanStop.from(ScanError.scannerProblem(.communicationError))
                    break pageLoop
                }
                if answer.status == 404 {
                    // Job complete. A feeder job that ends before its first page usually means an empty
                    // feeder: ask the device.
                    finished = true
                    if pages.isEmpty, let problem: ScannerProblem = try await getProblem(source) {
                        throw ScanError.scannerProblem(problem)
                    }
                    break pageLoop
                }
                guard (200..<300).contains(answer.status), let file: URL = answer.file else {
                    let failure: EsclJobFailure = try await jobFailure(
                        source, status: answer.status, fallback: "\(deviceName) returned HTTP \(answer.status).")
                    if pages.isEmpty {
                        throw failure.error
                    }
                    stop = failure.stop
                    break pageLoop
                }
                if EsclClient.isEmptyFile(file) {
                    EsclClient.remove(file)
                    break pageLoop
                }
                progress?(ScanProgress(message: "Transferring page \(pages.count + 1)…"))
                let image: CGImage
                do {
                    image = try readPage(file)
                } catch {
                    EsclClient.remove(file)
                    let unreadable: ScanError = ScanError.scanFailed(
                        "\(deviceName) sent page \(pages.count + 1) in a form that could not be read (\(error.localizedDescription)).")
                    if pages.isEmpty {
                        throw unreadable
                    }
                    stop = ScanStop.from(unreadable)
                    break pageLoop
                }
                EsclClient.remove(file)
                pages.append(ScannedPage(image: image, dpi: request.resolution, colorMode: colorMode))
            }
        } catch {
            // Stopped because the app is being suspended: the pages received are kept.
            let cancelled: Bool = Task.isCancelled || error is CancellationError
            if cancelled, !pages.isEmpty, let isSuspended = suspended, isSuspended() {
                return EsclJobResult(pages: pages, stop: ScanStop.from(ScanError.scannerProblem(.appSuspended)))
            }
            throw error
        }
        return EsclJobResult(pages: pages, stop: stop)
    }

    /// POSTs a job request. The request itself is not cancelled with the task: a device that has already
    /// created the job would keep it (and keep feeding paper) with nobody left to delete it. A cancel
    /// stops the wait instead, and the job is deleted as soon as the device answers with its address.
    private func postJob(_ scanJobs: URL, body: Data) async throws -> EsclReply {
        var post: URLRequest = makeRequest(scanJobs, method: "POST", timeout: options.jobTimeout)
        post.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        post.httpBody = body
        let request: URLRequest = post
        let session: URLSession = self.session
        let sending: Task<EsclReply, Error> = Task.detached {
            try await EsclClient.fetch(request, on: session)
        }
        do {
            return try await EsclClient.waitUnlessCancelled(sending)
        } catch {
            if Task.isCancelled {
                track(Task {
                    await self.deleteOnceCreated(sending, scanJobs: scanJobs)
                })
            }
            throw error
        }
    }

    private func deleteOnceCreated(_ post: Task<EsclReply, Error>, scanJobs: URL) async {
        // A request that failed created no job to delete.
        guard let answer: EsclReply = try? await post.value else { return }
        if answer.status == 201, let job: URL = EsclJob.resolveLocation(scanJobs, answer.location) {
            await deleteQuietly(job)
        }
    }

    /// The error for a failed job request: the scanner's own problem when its status names one (or busy
    /// for a 503 that outlasted the retries), else `fallback`; and the stop it makes after the first page.
    private func jobFailure(_ source: ScanSource, status: Int, fallback: String) async throws -> EsclJobFailure {
        var problem: ScannerProblem? = try await getProblem(source)
        if problem == nil && EsclRetry.isRetryable(status) {
            problem = .busy
        }
        if let named = problem {
            let reason: String = ScannerProblems.describe(named) + " (HTTP \(status))"
            return EsclJobFailure(error: ScanError.scannerProblem(named), stop: ScanStop(reason: reason, problem: named))
        }
        let error: ScanError = ScanError.scanFailed(fallback)
        return EsclJobFailure(error: error, stop: ScanStop.from(error))
    }

    private func deleteQuietly(_ job: URL) async {
        // Best effort.
        _ = try? await EsclClient.fetch(makeRequest(job, method: "DELETE", timeout: options.requestTimeout), on: session)
    }

    private func trackDeletion(of run: EsclJobRun) {
        guard run.claimDeletion() else { return }
        let job: URL = run.url
        track(Task {
            await self.deleteQuietly(job)
        })
    }

    private func track(_ cleanup: Task<Void, Never>) {
        lock.lock()
        cleanups.append(cleanup)
        lock.unlock()
    }

    private func setCurrentJob(_ run: EsclJobRun?) {
        lock.lock()
        currentJob = run
        lock.unlock()
    }

    private func takeFirstProbe() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if probed {
            return false
        }
        probed = true
        return true
    }

    // MARK: - Requests

    private func sendWithRetry(_ send: () async throws -> EsclReply) async throws -> EsclReply {
        var elapsed: (() -> TimeInterval)?
        if let start = options.startClock {
            elapsed = start()
        }
        return try await EsclRetry.send(send,
                                        statusCode: { (reply: EsclReply) -> Int in reply.status },
                                        retryAfter: { (reply: EsclReply) -> TimeInterval? in reply.retryAfter },
                                        policy: options.retryPolicy, delay: options.delay, elapsed: elapsed)
    }

    /// GETs a page into a file of the page directory; an error answer's body is dropped.
    private func downloadPage(_ url: URL) async throws -> EsclReply {
        let result: (URL, URLResponse) = try await session.download(for: makeRequest(url, method: "GET", timeout: options.jobTimeout))
        let downloaded: URL = result.0
        guard let http: HTTPURLResponse = result.1 as? HTTPURLResponse else {
            EsclClient.remove(downloaded)
            throw URLError(.badServerResponse)
        }
        let answer: EsclReply = EsclClient.reply(http, data: Data(), file: nil)
        if !(200..<300).contains(answer.status) {
            EsclClient.remove(downloaded)
            return answer
        }
        let target: URL = pageDirectory.appendingPathComponent("escl-page-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: pageDirectory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: downloaded, to: target)
        } catch {
            EsclClient.remove(downloaded)
            throw error
        }
        return EsclClient.reply(http, data: Data(), file: target)
    }

    private func makeRequest(_ url: URL, method: String, timeout: TimeInterval) -> URLRequest {
        var request: URLRequest = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        return request
    }

    /// `name` under the eSCL root.
    private func resolve(_ name: String) -> URL {
        let text: String = baseURL.absoluteString
        if text.hasSuffix("/"), let url = URL(string: text + name) {
            return url
        }
        if let url = URL(string: name, relativeTo: baseURL) {
            return url.absoluteURL
        }
        return baseURL.appendingPathComponent(name)
    }

    private static func fetch(_ request: URLRequest, on session: URLSession) async throws -> EsclReply {
        let result: (Data, URLResponse) = try await session.data(for: request)
        guard let http: HTTPURLResponse = result.1 as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return reply(http, data: result.0, file: nil)
    }

    private static func reply(_ http: HTTPURLResponse, data: Data, file: URL?) -> EsclReply {
        var retryAfter: TimeInterval?
        if let text: String = http.value(forHTTPHeaderField: "Retry-After"),
           let seconds: Int = Int(text.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            retryAfter = TimeInterval(seconds)
        }
        return EsclReply(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"),
                         retryAfter: retryAfter, data: data, file: file)
    }

    /// Waits for `task`, but stops waiting (throwing `CancellationError`) when the current task is
    /// cancelled; `task` itself runs on.
    private static func waitUnlessCancelled(_ task: Task<EsclReply, Error>) async throws -> EsclReply {
        let waiter: EsclReplyWaiter = EsclReplyWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<EsclReply, Error>) in
                if waiter.start(continuation) {
                    Task {
                        let result: Result<EsclReply, Error> = await task.result
                        waiter.finish(result)
                    }
                }
            }
        } onCancel: {
            waiter.finish(.failure(CancellationError()))
        }
    }

    private static func isEmptyFile(_ file: URL) -> Bool {
        guard let attributes: [FileAttributeKey: Any] = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attributes[.size] as? NSNumber else {
            return false
        }
        return size.int64Value == 0
    }

    private static func remove(_ file: URL) {
        try? FileManager.default.removeItem(at: file)
    }

    private static func makeConfiguration(_ options: EsclClientOptions, waits: Bool) -> URLSessionConfiguration {
        var configuration: URLSessionConfiguration = URLSessionConfiguration.ephemeral
        if let given = options.configuration, let copy = given.copy() as? URLSessionConfiguration {
            configuration = copy
        }
        configuration.timeoutIntervalForRequest = options.requestTimeout
        configuration.waitsForConnectivity = waits
        if waits {
            configuration.timeoutIntervalForResource = options.connectivityWait + options.requestTimeout
        }
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldUsePipelining = false
        return configuration
    }
}

/// An answer: its status, the headers a job needs, and its body (in memory, or a page's file).
private struct EsclReply {
    let status: Int
    let location: String?
    let retryAfter: TimeInterval?
    let data: Data
    let file: URL?
}

/// A failed job request as an error (before the first page) and as a stop (after it).
private struct EsclJobFailure {
    let error: ScanError
    let stop: ScanStop
}

/// A job created on the device; deleted at most once.
private final class EsclJobRun: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var deleted = false

    init(url: URL) {
        self.url = url
    }

    /// Marks the job as deleted; false when it was already.
    func claimDeletion() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if deleted {
            return false
        }
        deleted = true
        return true
    }
}

/// One wait for a reply that ends with the reply or with a cancel, whichever comes first.
private final class EsclReplyWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<EsclReply, Error>?
    private var done = false

    /// Keeps `continuation` to resume later; false when the wait has ended already (it was cancelled), in
    /// which case `continuation` is resumed now.
    func start(_ continuation: CheckedContinuation<EsclReply, Error>) -> Bool {
        lock.lock()
        if done {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func finish(_ result: Result<EsclReply, Error>) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        let pending: CheckedContinuation<EsclReply, Error>? = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
