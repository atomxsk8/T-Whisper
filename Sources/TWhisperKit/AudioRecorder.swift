import Foundation
import AVFoundation

/// Records microphone input to an app-owned temporary 16 kHz mono 16-bit PCM WAV file.
@MainActor
public final class AudioRecorder: NSObject {
    enum RecorderError: LocalizedError {
        case microphonePermissionDenied
        case failedToCreateRecorder(Error)
        case failedToPrepare
        case failedToStart
        case encodingFailed(Error?)
        case notRecording
        case noAudioDetected

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access is denied. Grant access in System Settings > Privacy & Security > Microphone."
            case .failedToCreateRecorder(let error):
                return "Could not start the recorder: \(error.localizedDescription)"
            case .failedToPrepare:
                return "The recorder failed to prepare."
            case .failedToStart:
                return "The recorder failed to start."
            case .encodingFailed(let error):
                return "Recording failed: \(error?.localizedDescription ?? "unknown encoding error")"
            case .notRecording:
                return "Not currently recording."
            case .noAudioDetected:
                return "No audio detected."
            }
        }
    }

    static let maxDuration: TimeInterval = 120
    private static let silenceFloorDBFS: Float = -60
    private static let minimumDuration: TimeInterval = 0.3
    private static let meteringInterval: TimeInterval = 0.1

    private(set) var isRecording = false
    private(set) var currentLevel: Float = 0
    private(set) var elapsed: TimeInterval = 0

    /// Called at most once per recording, from the main actor, when the hard cap is hit.
    var onAutoStopReached: (() -> Void)?
    /// Called on every metering tick (~10 Hz while recording) so observers can react to
    /// `currentLevel`/`elapsed` changes without polling.
    var onMeterUpdate: (() -> Void)?

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var startDate: Date?
    private var recordingURL: URL?
    private var peakEverAboveFloor = false
    private var recordingError: Error?
    private var autoStopFired = false

    private static let tempDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("app.twhisper.mac.audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Removes any audio files left behind by a previous crash. Safe to call once at launch;
    /// only touches files inside this app's own temporary audio directory.
    public static func cleanupStaleFiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(at: tempDirectory, includingPropertiesForKeys: nil) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    /// Requests microphone permission if not yet determined. Returns whether access is granted.
    @discardableResult
    static func requestPermissionIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    func start() throws {
        guard !isRecording else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphonePermissionDenied
        }

        let url = Self.tempDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        let newRecorder: AVAudioRecorder
        do {
            newRecorder = try AVAudioRecorder(url: url, settings: settings)
        } catch {
            throw RecorderError.failedToCreateRecorder(error)
        }
        newRecorder.delegate = self
        newRecorder.isMeteringEnabled = true

        guard newRecorder.prepareToRecord() else {
            throw RecorderError.failedToPrepare
        }
        guard newRecorder.record() else {
            throw RecorderError.failedToStart
        }

        recorder = newRecorder
        recordingURL = url
        startDate = Date()
        peakEverAboveFloor = false
        recordingError = nil
        autoStopFired = false
        isRecording = true
        currentLevel = 0
        elapsed = 0
        startMetering()
    }

    /// Stops recording and returns the finished file's URL, or throws when the take should be
    /// discarded (too short/silent) or a delegate-reported encoding error occurred.
    func stop() throws -> URL {
        guard isRecording, let recorder, let url = recordingURL, let startDate else {
            throw RecorderError.notRecording
        }
        stopMetering()
        let finalElapsed = Date().timeIntervalSince(startDate)
        recorder.stop()

        isRecording = false
        self.recorder = nil
        self.startDate = nil
        self.recordingURL = nil

        if let recordingError {
            self.recordingError = nil
            cleanupFile(at: url)
            throw RecorderError.encodingFailed(recordingError)
        }

        guard finalElapsed >= Self.minimumDuration, peakEverAboveFloor else {
            cleanupFile(at: url)
            throw RecorderError.noAudioDetected
        }

        return url
    }

    /// Discards the in-progress recording without producing a result.
    func cancel() {
        guard isRecording, let recorder else { return }
        stopMetering()
        recorder.stop()
        if let url = recordingURL {
            cleanupFile(at: url)
        }
        self.recorder = nil
        self.recordingURL = nil
        self.startDate = nil
        self.recordingError = nil
        isRecording = false
        currentLevel = 0
        elapsed = 0
    }

    func cleanupFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: Self.meteringInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMeter()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
        currentLevel = 0
    }

    private func updateMeter() {
        guard let recorder, let startDate else { return }
        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        if db > Self.silenceFloorDBFS {
            peakEverAboveFloor = true
        }
        let normalized = max(0, min(1, (db + 60) / 60))
        currentLevel = normalized
        elapsed = Date().timeIntervalSince(startDate)
        onMeterUpdate?()

        if !autoStopFired, elapsed >= Self.maxDuration {
            autoStopFired = true
            onAutoStopReached?()
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    public nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.recordingError = error ?? RecorderError.encodingFailed(nil)
        }
    }
}
