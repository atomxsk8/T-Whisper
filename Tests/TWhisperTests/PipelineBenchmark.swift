import Testing
import ApplicationServices
import Foundation
@testable import TWhisperKit

/// Deterministic, network-free benchmark of T-Whisper's own record -> transcribe ->
/// normalize -> insert pipeline. Network I/O is replaced by `StubURLProtocol`, which answers
/// every request in-process with canned bytes, so the measured time reflects only this
/// package's code: multipart encoding, JSON encode/decode, actor hops, and `AppModel`
/// orchestration — the local overhead T-Whisper adds on top of the network round trip,
/// which is exactly what determines how "instant" dictation feels next to Wispr Flow.
///
/// Run in isolation (so no other test's work pollutes the timing) via:
///   swift test --filter pipelineBenchmark

@MainActor
private func benchmarkDummyTarget() -> InsertionTarget {
    InsertionTarget(pid: getpid(), element: AXUIElementCreateApplication(getpid()), selectedRange: nil)
}

/// Builds a fully deterministic 16 kHz mono 16-bit PCM WAV file (fixed sine wave, no
/// randomness, no clock dependency) so repeated runs upload byte-identical audio.
private func makeSyntheticWAVData(durationSeconds: Double = 5.0, sampleRate: Int = 16_000) -> Data {
    let sampleCount = Int(Double(sampleRate) * durationSeconds)
    var pcm = Data(capacity: sampleCount * 2)
    for i in 0..<sampleCount {
        let t = Double(i) / Double(sampleRate)
        let value = Int16((sin(t * 440.0 * 2.0 * Double.pi) * 8000.0).rounded())
        withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
    }

    func uint32LE(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    func uint16LE(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

    let byteRate = UInt32(sampleRate * 2)
    var header = Data()
    header.append("RIFF".data(using: .ascii)!)
    header.append(uint32LE(UInt32(36 + pcm.count)))
    header.append("WAVE".data(using: .ascii)!)
    header.append("fmt ".data(using: .ascii)!)
    header.append(uint32LE(16))
    header.append(uint16LE(1)) // PCM
    header.append(uint16LE(1)) // mono
    header.append(uint32LE(UInt32(sampleRate)))
    header.append(uint32LE(byteRate))
    header.append(uint16LE(2)) // block align
    header.append(uint16LE(16)) // bits per sample
    header.append("data".data(using: .ascii)!)
    header.append(uint32LE(UInt32(pcm.count)))

    return header + pcm
}

/// Intercepts every request issued by the benchmark's `URLSession` and answers instantly
/// with canned bytes, in-process. No socket is ever opened, so the benchmark never touches
/// the live network and never depends on wall-clock/network jitter.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var transcriptionResponseData = Data()
    nonisolated(unsafe) static var normalizationResponseData = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isTranscription = request.url?.path.contains("transcriptions") ?? false
        let payload = isTranscription ? Self.transcriptionResponseData : Self.normalizationResponseData
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func makeStubbedGroqClient() -> GroqClient {
    StubURLProtocol.transcriptionResponseData = Data("""
    {"text":"the quick brown fox jumps over the lazy dog","segments":[{"no_speech_prob":0.05,"avg_logprob":-0.2}]}
    """.utf8)
    StubURLProtocol.normalizationResponseData = Data("""
    {"choices":[{"message":{"content":"The quick brown fox jumps over the lazy dog"},"finish_reason":"stop"}]}
    """.utf8)

    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    config.urlCache = nil
    return GroqClient(session: URLSession(configuration: config))
}

@MainActor
private func meanMilliseconds(_ clock: ContinuousClock, iterations: Int, _ body: () async throws -> Void) async rethrows -> Double {
    let start = clock.now
    for _ in 0..<iterations {
        try await body()
    }
    let elapsed = clock.now - start
    let totalMs = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    return totalMs / Double(iterations)
}

@Test @MainActor
func pipelineBenchmark() async throws {
    let clock = ContinuousClock()
    let warmupIterations = 5
    let measuredIterations = 100

    let wavData = makeSyntheticWAVData()
    let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("twhisper-bench-\(UUID().uuidString).wav")
    try wavData.write(to: wavURL)
    defer { try? FileManager.default.removeItem(at: wavURL) }

    // Isolated GroqClient micro-benchmarks: pin the cost of multipart encoding and JSON
    // decode/encode independently of AppModel's orchestration overhead.
    let transcribeClient = makeStubbedGroqClient()
    for _ in 0..<warmupIterations {
        _ = try await transcribeClient.transcribe(audioURL: wavURL, language: .thai, vocabulary: "", apiKey: "test-key")
    }
    let transcribeLatencyMs = try await meanMilliseconds(clock, iterations: measuredIterations) {
        _ = try await transcribeClient.transcribe(audioURL: wavURL, language: .thai, vocabulary: "", apiKey: "test-key")
    }

    let normalizeClient = makeStubbedGroqClient()
    for _ in 0..<warmupIterations {
        _ = try await normalizeClient.normalize(transcript: "the quick brown fox", vocabulary: "", apiKey: "test-key")
    }
    let normalizeLatencyMs = try await meanMilliseconds(clock, iterations: measuredIterations) {
        _ = try await normalizeClient.normalize(transcript: "the quick brown fox", vocabulary: "", apiKey: "test-key")
    }

    // Full AppModel pipeline: real GroqClient (stubbed network) + fake audio/text seams, so
    // this isolates T-Whisper's own orchestration/encoding cost end to end.
    func runPipelineOnce(_ model: AppModel) async {
        _ = model.debugBeginRecordingSession(target: benchmarkDummyTarget())
        model.stopRecordingAndProcess()
        await model.debugWaitForPipeline()
    }

    let (defaults, cleanup) = makeIsolatedDefaults()
    defer { cleanup() }
    let audioRecorder = FakeAudioRecorder()
    audioRecorder.stopResult = .success(wavURL)
    let model = AppModel(
        audioRecorder: audioRecorder,
        groqClient: makeStubbedGroqClient(),
        textInserter: FakeTextInserter(),
        hotkeyManager: NoOpHotkeyManager(),
        recordingPanel: NoOpRecordingPanel(),
        apiKeyStore: InMemoryAPIKeyStore(),
        defaults: defaults
    )
    model.cleanUpTranscript = true
    model.inputLanguage = .thai

    for _ in 0..<warmupIterations {
        await runPipelineOnce(model)
    }
    let pipelineLatencyMs = await meanMilliseconds(clock, iterations: measuredIterations) {
        await runPipelineOnce(model)
    }

    print("METRIC pipeline_latency_ms=\(pipelineLatencyMs)")
    print("METRIC transcribe_latency_ms=\(transcribeLatencyMs)")
    print("METRIC normalize_latency_ms=\(normalizeLatencyMs)")
}
