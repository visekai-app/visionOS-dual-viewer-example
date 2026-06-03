@preconcurrency import AVFoundation
import Foundation

@MainActor
final class VisionProCaptureController: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
    let id: String
    let deviceName: String
    let session = AVCaptureSession()

    @Published private(set) var isPreviewing = false
    @Published private(set) var isRecording = false
    @Published private(set) var isAudioMonitoringEnabled = false
    @Published private(set) var audioLevel: Float = 0
    @Published private(set) var audioAuthorizationStatus: AVAuthorizationStatus
    @Published private(set) var audioStatusMessage: String?
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var errorMessage: String?

    private let device: AVCaptureDevice
    private let framePipeline: CaptureFramePipeline
    private let audioLevelMeter: CaptureAudioLevelMeter
    private let audioPreviewOutput = AVCaptureAudioPreviewOutput()
    private var deviceInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var watchdogTask: Task<Void, Never>?
    private var isRestartingAfterFrameTimeout = false

    init(device: AVCaptureDevice) {
        self.device = device
        framePipeline = CaptureFramePipeline(deviceID: device.uniqueID)
        audioLevelMeter = CaptureAudioLevelMeter(deviceID: device.uniqueID)
        audioAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        id = device.uniqueID
        deviceName = device.localizedName
        super.init()

        framePipeline.recordingFailureHandler = { [weak self] url, message in
            self?.isRecording = false
            self?.lastRecordingURL = url
            self?.errorMessage = message
        }
        audioLevelMeter.levelUpdateHandler = { [weak self] level in
            self?.audioLevel = level
        }
    }

    func togglePreview() {
        isPreviewing ? stopPreview() : startPreview()
    }

    func startPreview() {
        // Don't start before camera access is granted, or the session runs in a
        // frameless state and a later start no-ops (session already "running").
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }

        guard !session.isRunning else {
            isPreviewing = true
            startFrameWatchdog()
            return
        }

        configureSessionIfNeeded()
        guard isConfigured else {
            return
        }

        framePipeline.clearRenderLayer()
        framePipeline.markSessionStarted()
        session.startRunning()
        isPreviewing = session.isRunning
        if isPreviewing {
            startFrameWatchdog()
        }
    }

    func stopPreview() {
        watchdogTask?.cancel()
        watchdogTask = nil

        if isRecording {
            stopRecording()
        }

        if isAudioMonitoringEnabled {
            setAudioMonitoringEnabled(false)
        }

        if session.isRunning {
            session.stopRunning()
        }

        framePipeline.clearRenderLayer()
        isPreviewing = false
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        configureSessionIfNeeded()
        guard isConfigured else {
            return
        }

        if !session.isRunning {
            startPreview()
        }

        guard session.isRunning, !isRecording else {
            return
        }

        do {
            let outputURL = try Self.makeRecordingURL(deviceName: deviceName)
            guard framePipeline.startRecording(to: outputURL) else {
                return
            }
            lastRecordingURL = outputURL
            isRecording = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func toggleAudioMonitoring() {
        if isAudioMonitoringEnabled {
            setAudioMonitoringEnabled(false)
            return
        }

        audioAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch audioAuthorizationStatus {
        case .authorized:
            setAudioMonitoringEnabled(true)
        case .notDetermined:
            Task { @MainActor [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .audio)
                guard let self else { return }
                self.audioAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                if granted {
                    self.setAudioMonitoringEnabled(true)
                } else {
                    self.audioStatusMessage = "Audio access was denied. Enable microphone access in System Settings."
                }
            }
        case .denied, .restricted:
            audioStatusMessage = "Audio access is blocked. Enable microphone access in System Settings."
        @unknown default:
            audioStatusMessage = "Unknown audio authorization state."
        }
    }

    func stopRecording() {
        guard isRecording else {
            return
        }

        framePipeline.stopRecording { [weak self] message in
            self?.isRecording = false
            if let message {
                self?.errorMessage = message
            }
        }
    }

    func attachRenderLayer(_ layer: AVSampleBufferDisplayLayer) {
        framePipeline.attachRenderLayer(layer)
    }

    func detachRenderLayer(_ layer: AVSampleBufferDisplayLayer) {
        framePipeline.detachRenderLayer(layer)
    }

    private func configureSessionIfNeeded() {
        guard !isConfigured else {
            return
        }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        for input in session.inputs {
            session.removeInput(input)
        }

        for output in session.outputs {
            session.removeOutput(output)
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                errorMessage = "Cannot add capture input for \(deviceName)."
                return
            }
            session.addInput(input)
            deviceInput = input
            setAudioPortsEnabled(false, on: input)

            configureDeviceFormat()

            guard session.canAddOutput(framePipeline.videoOutput) else {
                errorMessage = "Cannot add video data output for \(deviceName)."
                return
            }
            session.addOutput(framePipeline.videoOutput)

            isConfigured = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func setAudioMonitoringEnabled(_ enabled: Bool) {
        if enabled {
            configureSessionIfNeeded()
            guard isConfigured else { return }

            guard configureAudioOutputsIfPossible() else {
                isAudioMonitoringEnabled = false
                return
            }

            if !session.isRunning {
                startPreview()
            }

            audioPreviewOutput.volume = 1.0
            isAudioMonitoringEnabled = true
            audioStatusMessage = nil
        } else {
            removeAudioOutputs()
            isAudioMonitoringEnabled = false
            audioLevel = 0
        }
    }

    private func configureAudioOutputsIfPossible() -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            audioStatusMessage = "Audio access is not authorized."
            return false
        }

        guard device.hasMediaType(.audio) || device.hasMediaType(.muxed) else {
            audioStatusMessage = "This stream does not expose audio."
            return false
        }

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
        }

        if let deviceInput {
            setAudioPortsEnabled(true, on: deviceInput)
        }

        var addedAnyOutput = containsOutput(audioPreviewOutput) || containsOutput(audioLevelMeter.audioOutput)

        if !containsOutput(audioPreviewOutput), session.canAddOutput(audioPreviewOutput) {
            session.addOutput(audioPreviewOutput)
            addedAnyOutput = true
        }

        if !containsOutput(audioLevelMeter.audioOutput), session.canAddOutput(audioLevelMeter.audioOutput) {
            session.addOutput(audioLevelMeter.audioOutput)
            addedAnyOutput = true
        }

        guard addedAnyOutput else {
            if let deviceInput {
                setAudioPortsEnabled(false, on: deviceInput)
            }
            audioStatusMessage = "Cannot add audio output for \(deviceName)."
            return false
        }

        return true
    }

    private func removeAudioOutputs() {
        session.beginConfiguration()
        if containsOutput(audioPreviewOutput) {
            session.removeOutput(audioPreviewOutput)
        }
        if containsOutput(audioLevelMeter.audioOutput) {
            session.removeOutput(audioLevelMeter.audioOutput)
        }
        if let deviceInput {
            setAudioPortsEnabled(false, on: deviceInput)
        }
        session.commitConfiguration()
        audioLevelMeter.reset()
    }

    private func containsOutput(_ output: AVCaptureOutput) -> Bool {
        session.outputs.contains { $0 === output }
    }

    private func setAudioPortsEnabled(_ isEnabled: Bool, on input: AVCaptureDeviceInput) {
        for port in input.ports where port.mediaType == .audio {
            port.isEnabled = isEnabled
        }
    }

    private func configureDeviceFormat() {
        guard let preferredConfiguration = Self.preferredFormatConfiguration(for: device) else {
            return
        }

        do {
            try device.lockForConfiguration()
            device.activeFormat = preferredConfiguration.format
            if let frameDuration = preferredConfiguration.frameDuration {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
            device.unlockForConfiguration()
        } catch {
            errorMessage = "Cannot configure \(deviceName) format: \(error.localizedDescription)"
        }
    }

    private func startFrameWatchdog() {
        guard watchdogTask == nil else {
            return
        }

        watchdogTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return
                }

                self?.restartSessionIfFramesStalled()
            }
        }
    }

    private func restartSessionIfFramesStalled() {
        guard isPreviewing, session.isRunning, !isRestartingAfterFrameTimeout else {
            return
        }

        guard framePipeline.secondsSinceLastFrame() >= 3 else {
            return
        }

        isRestartingAfterFrameTimeout = true
        session.stopRunning()
        configureDeviceFormat()
        framePipeline.clearRenderLayer()
        framePipeline.markSessionStarted()
        session.startRunning()
        isPreviewing = session.isRunning
        isRestartingAfterFrameTimeout = false
    }

    private static func preferredFormatConfiguration(for device: AVCaptureDevice) -> DeviceFormatConfiguration? {
        let targetWidth = 1_920
        let targetHeight = 1_080
        let targetAspect = Double(targetWidth) / Double(targetHeight)
        let formatsWithDimensions = device.formats.compactMap { format -> (AVCaptureDevice.Format, CMVideoDimensions)? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else {
                return nil
            }
            return (format, dimensions)
        }

        guard !formatsWithDimensions.isEmpty else {
            return DeviceFormatConfiguration(
                format: device.activeFormat,
                frameDuration: preferredFrameDuration(for: device.activeFormat)
            )
        }

        guard let format = formatsWithDimensions.min(by: { lhs, rhs in
            func score(_ dimensions: CMVideoDimensions) -> Double {
                let widthPenalty = abs(Double(dimensions.width - Int32(targetWidth)))
                let heightPenalty = abs(Double(dimensions.height - Int32(targetHeight)))
                let aspect = Double(dimensions.width) / Double(dimensions.height)
                let aspectPenalty = abs(aspect - targetAspect) * 1_000
                return widthPenalty + heightPenalty + aspectPenalty
            }

            return score(lhs.1) < score(rhs.1)
        })?.0 else {
            return nil
        }

        return DeviceFormatConfiguration(
            format: format,
            frameDuration: preferredFrameDuration(for: format)
        )
    }

    private static func preferredFrameDuration(for format: AVCaptureDevice.Format) -> CMTime? {
        let targetFrameRate = 30.0
        let ranges = format.videoSupportedFrameRateRanges.filter { $0.maxFrameRate > 0 }

        guard let range = ranges.min(by: { lhs, rhs in
            func distanceFromTarget(_ range: AVFrameRateRange) -> Double {
                if range.minFrameRate <= targetFrameRate, targetFrameRate <= range.maxFrameRate {
                    return 0
                }
                return min(
                    abs(targetFrameRate - range.minFrameRate),
                    abs(targetFrameRate - range.maxFrameRate)
                )
            }

            return distanceFromTarget(lhs) < distanceFromTarget(rhs)
        }) else {
            return nil
        }

        let frameRate = min(max(targetFrameRate, range.minFrameRate), range.maxFrameRate)
        guard frameRate > 0 else {
            return nil
        }

        return CMTime(
            value: 1_000_000,
            timescale: CMTimeScale((frameRate * 1_000_000).rounded())
        )
    }

    private static func makeRecordingURL(deviceName: String) throws -> URL {
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop", isDirectory: true)
        let recordingsDirectory = desktopURL.appendingPathComponent("vp-recordings", isDirectory: true)

        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"

        let safeName = deviceName
            .replacingOccurrences(of: "[^A-Za-z0-9]+", with: "", options: .regularExpression)
        let baseName = safeName.isEmpty ? "AppleVisionPro" : safeName
        let fileName = "\(baseName)_\(formatter.string(from: Date())).mov"

        return recordingsDirectory.appendingPathComponent(fileName)
    }
}

private struct DeviceFormatConfiguration {
    let format: AVCaptureDevice.Format
    let frameDuration: CMTime?
}

private final class CaptureFramePipeline: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let videoOutput = AVCaptureVideoDataOutput()
    var recordingFailureHandler: (@MainActor @Sendable (URL, String) -> Void)?

    private let captureQueue: DispatchQueue
    private weak var renderLayer: AVSampleBufferDisplayLayer?
    private var sessionStartDate = Date()
    private var lastFrameDate: Date?
    private var recordingState: RecordingState?

    init(deviceID: String) {
        captureQueue = DispatchQueue(label: "DualViewer.capture.\(deviceID)")
        super.init()

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
    }

    func attachRenderLayer(_ layer: AVSampleBufferDisplayLayer) {
        renderLayer = layer
        layer.videoGravity = .resizeAspect
        layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func detachRenderLayer(_ layer: AVSampleBufferDisplayLayer) {
        if renderLayer === layer {
            renderLayer = nil
        }
    }

    func clearRenderLayer() {
        renderLayer?.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func markSessionStarted() {
        captureQueue.async { [weak self] in
            self?.sessionStartDate = Date()
            self?.lastFrameDate = nil
        }
    }

    func secondsSinceLastFrame() -> TimeInterval {
        captureQueue.sync {
            Date().timeIntervalSince(lastFrameDate ?? sessionStartDate)
        }
    }

    func startRecording(to url: URL) -> Bool {
        captureQueue.sync {
            guard recordingState == nil else {
                return false
            }

            try? FileManager.default.removeItem(at: url)
            recordingState = RecordingState(url: url)
            return true
        }
    }

    func stopRecording(completion: @escaping @MainActor @Sendable (String?) -> Void) {
        captureQueue.async { [weak self] in
            guard let self else {
                return
            }

            guard let state = self.recordingState else {
                Task { @MainActor in completion(nil) }
                return
            }

            self.recordingState = nil

            guard let writer = state.writer, let input = state.input else {
                Task { @MainActor in
                    completion(RecordingError.stoppedBeforeFrames.localizedDescription)
                }
                return
            }

            input.markAsFinished()
            let finishContext = RecordingFinishContext(writer: writer, completion: completion)
            writer.finishWriting {
                finishContext.complete()
            }
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        lastFrameDate = Date()
        render(sampleBuffer)
        appendRecordingSample(sampleBuffer)
    }

    private func render(_ sampleBuffer: CMSampleBuffer) {
        guard let renderLayer else {
            return
        }

        let renderer = renderLayer.sampleBufferRenderer

        if renderer.status == .failed {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }

        guard renderer.isReadyForMoreMediaData else {
            return
        }

        renderer.enqueue(sampleBuffer)
    }

    private func appendRecordingSample(_ sampleBuffer: CMSampleBuffer) {
        guard var state = recordingState else {
            return
        }

        if state.writer == nil {
            do {
                try prepareWriter(for: sampleBuffer, state: &state)
            } catch {
                recordingState = nil
                notifyRecordingFailure(url: state.url, message: error.localizedDescription)
                return
            }
        }

        guard
            let writer = state.writer,
            let input = state.input,
            let adaptor = state.adaptor,
            let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            recordingState = state
            return
        }

        if writer.status == .failed || writer.status == .cancelled {
            recordingState = nil
            notifyRecordingFailure(
                url: state.url,
                message: writer.error?.localizedDescription ?? RecordingError.writerFailed.localizedDescription
            )
            return
        }

        guard input.isReadyForMoreMediaData else {
            recordingState = state
            return
        }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !adaptor.append(pixelBuffer, withPresentationTime: presentationTime) {
            recordingState = nil
            notifyRecordingFailure(
                url: state.url,
                message: writer.error?.localizedDescription ?? RecordingError.appendFailed.localizedDescription
            )
            return
        }

        recordingState = state
    }

    private func prepareWriter(for sampleBuffer: CMSampleBuffer, state: inout RecordingState) throws {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw RecordingError.missingVideoFrame
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else {
            throw RecordingError.missingVideoFrame
        }

        let writer = try AVAssetWriter(outputURL: state.url, fileType: .mov)
        let outputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            throw RecordingError.cannotAddWriterInput
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.writerFailed
        }

        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        state.writer = writer
        state.input = input
        state.adaptor = adaptor
    }

    private func notifyRecordingFailure(url: URL, message: String) {
        Task { @MainActor [recordingFailureHandler] in
            recordingFailureHandler?(url, message)
        }
    }
}

private final class CaptureAudioLevelMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let audioOutput = AVCaptureAudioDataOutput()
    var levelUpdateHandler: (@MainActor @Sendable (Float) -> Void)?

    private let captureQueue: DispatchQueue
    private var lastUpdateDate = Date.distantPast

    init(deviceID: String) {
        captureQueue = DispatchQueue(label: "DualViewer.audio.\(deviceID)")
        super.init()
        audioOutput.setSampleBufferDelegate(self, queue: captureQueue)
    }

    func reset() {
        lastUpdateDate = .distantPast
        Task { @MainActor [levelUpdateHandler] in
            levelUpdateHandler?(0)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        guard now.timeIntervalSince(lastUpdateDate) >= 1.0 / 30.0 else {
            return
        }
        lastUpdateDate = now

        let power = connection.audioChannels
            .map { $0.averagePowerLevel }
            .filter { $0.isFinite }
            .max() ?? -160
        let level = Self.normalizedLevel(fromDecibels: power)

        Task { @MainActor [levelUpdateHandler] in
            levelUpdateHandler?(level)
        }
    }

    private static func normalizedLevel(fromDecibels decibels: Float) -> Float {
        let clamped = min(0, max(-60, decibels))
        return (clamped + 60) / 60
    }
}

private struct RecordingState {
    let url: URL
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var adaptor: AVAssetWriterInputPixelBufferAdaptor?
}

private final class RecordingFinishContext: @unchecked Sendable {
    private let writer: AVAssetWriter
    private let completion: @MainActor @Sendable (String?) -> Void

    init(writer: AVAssetWriter, completion: @escaping @MainActor @Sendable (String?) -> Void) {
        self.writer = writer
        self.completion = completion
    }

    func complete() {
        let message = writer.error?.localizedDescription
        Task { @MainActor [completion] in
            completion(message)
        }
    }
}

private enum RecordingError: LocalizedError {
    case missingVideoFrame
    case cannotAddWriterInput
    case writerFailed
    case appendFailed
    case stoppedBeforeFrames

    var errorDescription: String? {
        switch self {
        case .missingVideoFrame:
            "The capture stream did not provide a video frame."
        case .cannotAddWriterInput:
            "Cannot add video input to the recording writer."
        case .writerFailed:
            "The recording writer failed."
        case .appendFailed:
            "Could not append a video frame to the recording."
        case .stoppedBeforeFrames:
            "Recording stopped before any video frames arrived."
        }
    }
}
