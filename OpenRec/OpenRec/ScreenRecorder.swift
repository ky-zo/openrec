import ScreenCaptureKit
import AVFoundation
import CoreMedia
import CoreGraphics
import UniformTypeIdentifiers

@available(macOS 13.0, *)
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    enum MediaStream: String, Sendable {
        case screen
        case audio
    }

    enum SegmentKind: String, Sendable {
        case initialization
        case media
    }

    /// One ordered CMAF byte range. Sequence starts at zero independently for
    /// each stream and includes that stream's initialization segment.
    struct CMAFSegment: @unchecked Sendable {
        let stream: MediaStream
        let kind: SegmentKind
        let sequence: Int
        let data: Data
    }

    struct Completion: Sendable {
        let screenSegmentCount: Int
        let audioSegmentCount: Int
    }

    enum SegmentedWriterKind {
        case muxedScreen(width: Int, height: Int)
        case audioOnly
    }

    /// The common writer startup result used by production and the focused
    /// AVFoundation regression tests. Keeping startup in one path matters:
    /// changing either the file profile or adaptor ordering can make
    /// `startWriting()` fail (or raise an Objective-C exception) at runtime.
    struct SegmentedWriterComponents {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput?
        let pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        let pixelBufferAdaptorCreationStatus: AVAssetWriter.Status?
        let audioInput: AVAssetWriterInput
    }

    /// Called on a dedicated serial delivery queue, never an AV capture or
    /// writer queue. Bytes for each stream are delivered in sequence order.
    var onSegment: ((CMAFSegment) -> Void)?
    var onComplete: ((Result<Completion, Error>) -> Void)?
    var onAudioLevels: ((Float, Float) -> Void)?
    var onSystemAudioSample: ((CMSampleBuffer) -> Void)?
    var onMicAudioSample: ((CMSampleBuffer) -> Void)?

    private enum State {
        case idle
        case starting
        case recording
        case stopping
        case completed
    }

    private let micDevice: AVCaptureDevice?
    private let recordsScreen: Bool
    /// Whether to produce a separate audio-only CMAF stream. The screen stream
    /// always contains mixed call audio, regardless of this value.
    private let recordsAudio: Bool
    private let segmentDuration: CMTime

    private var stream: SCStream?
    private var micCaptureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private let micQueue = DispatchQueue(label: "screenrec.mic.capture", qos: .userInteractive)
    private let captureControlQueue = DispatchQueue(label: "screenrec.capture.control", qos: .userInitiated)

    private let writerQueue = DispatchQueue(label: "screenrec.writer", qos: .userInitiated)
    private var screenWriter: AVAssetWriter?
    private var screenVideoInput: AVAssetWriterInput?
    private var screenPixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var screenAudioInput: AVAssetWriterInput?
    private var audioWriter: AVAssetWriter?
    private var audioOnlyInput: AVAssetWriterInput?
    private var mixedPCMFormatDescription: CMAudioFormatDescription?
    private var captureTimeOrigin = CMTime.invalid
    private var lastVideoTime = CMTime.invalid
    private var lastAudioTime = CMTime.invalid
    private var writerFailure: Error?
    private var pendingWriterFinishes = 0

    private let mediaAudioMixer = AudioMixer()
    private let observerQueue = DispatchQueue(label: "screenrec.observers", qos: .userInitiated)
    private let segmentDeliveryQueue = DispatchQueue(label: "screenrec.segment.delivery", qos: .utility)
    private var screenSequence = 0
    private var audioSequence = 0
    private var screenInitializationSegments = 0
    private var audioInitializationSegments = 0
    private var screenMediaSegments = 0
    private var audioMediaSegments = 0

    private let stateLock = NSLock()
    private var state: State = .idle
    private let levelLock = NSLock()
    private var micLevel: Float = 0
    private var systemLevel: Float = 0

    private(set) var recordingDisplayID: CGDirectDisplayID?

    init(
        micDevice: AVCaptureDevice?,
        recordsScreen: Bool,
        recordsAudio: Bool,
        segmentDuration: TimeInterval = 8
    ) {
        self.micDevice = micDevice
        self.recordsScreen = recordsScreen
        self.recordsAudio = recordsAudio
        self.segmentDuration = CMTime(
            seconds: max(2, segmentDuration),
            preferredTimescale: 600
        )
        super.init()
    }

    func start() async throws {
        guard recordsScreen || recordsAudio else {
            throw RecorderError.setupFailed("Choose screen recording, audio recording, or both.")
        }
        guard claimStart() else {
            throw RecorderError.setupFailed("The recorder has already been started.")
        }

        var startSucceeded = false
        defer {
            if !startSucceeded {
                abortStart()
            }
        }

        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }
        recordingDisplayID = display.displayID

        let width = max(2, Int(display.width) & ~1)
        let height = max(2, Int(display.height) & ~1)
        do {
            try setupWriters(width: width, height: height)
            try setupMicrophone()
        } catch {
            cancelWriters()
            throw error
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = Int(TimestampedPCMChunk.sampleRate)
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        // Let users capture OpenRec with the normal macOS screenshot tools,
        // while keeping OpenRec's own controls, notes, and recording border
        // out of the call recording itself. Excluding the whole process also
        // covers OpenRec windows that appear after capture starts.
        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        let openRecApplications = content.applications.filter {
            $0.processID == currentProcessID
        }
        guard !openRecApplications.isEmpty else {
            throw RecorderError.setupFailed(
                "OpenRec could not safely exclude its controls from the call recording."
            )
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: openRecApplications,
            exceptingWindows: []
        )
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let screenCaptureQueue = DispatchQueue(label: "screenrec.screen.capture", qos: .userInteractive)
        if recordsScreen {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: screenCaptureQueue)
        }
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: screenCaptureQueue)
        self.stream = stream

        segmentDeliveryQueue.sync {
            screenSequence = 0
            audioSequence = 0
            screenInitializationSegments = 0
            audioInitializationSegments = 0
            screenMediaSegments = 0
            audioMediaSegments = 0
        }

        captureTimeOrigin = CMClockGetTime(CMClockGetHostTimeClock())
        mediaAudioMixer.onHighQualityChunkReady = { [weak self] chunk in
            self?.writerQueue.async { [weak self] in
                self?.appendMixedAudio(chunk)
            }
        }
        mediaAudioMixer.start()

        setState(.recording)
        micCaptureSession?.startRunning()
        try await stream.startCapture()
        startSucceeded = true
    }

    func stop() {
        requestStop(captureError: nil)
    }

    private func requestStop(captureError: Error?) {
        stateLock.lock()
        guard state == .recording else {
            stateLock.unlock()
            return
        }
        state = .stopping
        stateLock.unlock()

        Task { [weak self] in
            await self?.stopCaptureAndFinish(captureError: captureError)
        }
    }

    private func stopCaptureAndFinish(captureError: Error?) async {
        await withCheckedContinuation { continuation in
            captureControlQueue.async { [weak self] in
                self?.micCaptureSession?.stopRunning()
                continuation.resume()
            }
        }

        var finalCaptureError = captureError
        do {
            try await stream?.stopCapture()
        } catch {
            if finalCaptureError == nil { finalCaptureError = error }
        }

        await withCheckedContinuation { continuation in
            mediaAudioMixer.finish {
                continuation.resume()
            }
        }

        writerQueue.async { [weak self] in
            self?.finishWriters(captureError: finalCaptureError)
        }
    }

    private func setupWriters(width: Int, height: Int) throws {
        writerFailure = nil
        pendingWriterFinishes = 0
        lastVideoTime = .invalid
        lastAudioTime = .invalid
        let mixedPCMFormatDescription = try Self.makeMixedPCMFormatDescription()
        self.mixedPCMFormatDescription = mixedPCMFormatDescription

        if recordsScreen {
            let components = try Self.startSegmentedWriter(
                kind: .muxedScreen(width: width, height: height),
                segmentDuration: segmentDuration,
                mixedPCMFormatDescription: mixedPCMFormatDescription,
                delegate: self
            )
            screenWriter = components.writer
            screenVideoInput = components.videoInput
            screenPixelBufferAdaptor = components.pixelBufferAdaptor
            screenAudioInput = components.audioInput
        }

        if recordsAudio {
            let components = try Self.startSegmentedWriter(
                kind: .audioOnly,
                segmentDuration: segmentDuration,
                mixedPCMFormatDescription: mixedPCMFormatDescription,
                delegate: self
            )
            audioWriter = components.writer
            audioOnlyInput = components.audioInput
        }
    }

    static func startSegmentedWriter(
        kind: SegmentedWriterKind,
        segmentDuration: CMTime,
        mixedPCMFormatDescription: CMAudioFormatDescription,
        delegate: AVAssetWriterDelegate
    ) throws -> SegmentedWriterComponents {
        let profile: AVFileTypeProfile
        switch kind {
        case .muxedScreen:
            // AVFoundation's strict CMAF profile only permits one track. The
            // Apple HLS fMP4 profile uses the same init + moof/mdat segment
            // delivery contract while allowing H.264 and mixed call audio.
            profile = .mpeg4AppleHLS
        case .audioOnly:
            profile = .mpeg4CMAFCompliant
        }
        let writer = makeSegmentedWriter(profile: profile, segmentDuration: segmentDuration)
        var videoInput: AVAssetWriterInput?
        var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
        var pixelBufferAdaptorCreationStatus: AVAssetWriter.Status?

        if case .muxedScreen(let width, let height) = kind {
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 3_000_000,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: CMTimeGetSeconds(segmentDuration)
                ]
            ]
            guard writer.canApply(outputSettings: videoSettings, forMediaType: .video) else {
                throw RecorderError.setupFailed("This Mac cannot encode the selected display as H.264.")
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else {
                throw RecorderError.setupFailed("The screen encoder could not add its video track.")
            }
            writer.add(input)
            videoInput = input

            // The adaptor must be attached before startWriting(). AVFoundation
            // raises an Objective-C exception (rather than returning an Error)
            // if it is created after the writer has entered `.writing`.
            pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height
                ]
            )
            pixelBufferAdaptorCreationStatus = writer.status
        }

        let audioInput = try makeAudioInput(
            for: writer,
            mixedPCMFormatDescription: mixedPCMFormatDescription
        )
        writer.delegate = delegate
        guard writer.startWriting() else {
            let fallback: RecorderError
            switch kind {
            case .muxedScreen:
                fallback = .setupFailed("The screen encoder could not start.")
            case .audioOnly:
                fallback = .setupFailed("The audio encoder could not start.")
            }
            throw writer.error ?? fallback
        }
        writer.startSession(atSourceTime: .zero)

        return SegmentedWriterComponents(
            writer: writer,
            videoInput: videoInput,
            pixelBufferAdaptor: pixelBufferAdaptor,
            pixelBufferAdaptorCreationStatus: pixelBufferAdaptorCreationStatus,
            audioInput: audioInput
        )
    }

    private static func makeSegmentedWriter(
        profile: AVFileTypeProfile,
        segmentDuration: CMTime
    ) -> AVAssetWriter {
        let writer = AVAssetWriter(contentType: .mpeg4Movie)
        writer.outputFileTypeProfile = profile
        writer.preferredOutputSegmentInterval = segmentDuration
        writer.initialSegmentStartTime = .zero
        return writer
    }

    private static func makeAudioInput(
        for writer: AVAssetWriter,
        mixedPCMFormatDescription: CMAudioFormatDescription
    ) throws -> AVAssetWriterInput {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: TimestampedPCMChunk.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw RecorderError.setupFailed("This Mac cannot encode the mixed call audio as AAC.")
        }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: mixedPCMFormatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecorderError.setupFailed("The encoder could not add its mixed audio track.")
        }
        writer.add(input)
        return input
    }

    static func makeMixedPCMFormatDescription() throws -> CMAudioFormatDescription {
        var format = AudioStreamBasicDescription(
            mSampleRate: TimestampedPCMChunk.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &format,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw RecorderError.setupFailed("The recorder could not describe its mixed audio format.")
        }
        return description
    }

    private func setupMicrophone() throws {
        guard let micDevice else { return }

        let session = AVCaptureSession()
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let input = try AVCaptureDeviceInput(device: micDevice)
        guard session.canAddInput(input) else {
            throw RecorderError.setupFailed("The selected microphone is unavailable.")
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: TimestampedPCMChunk.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        output.setSampleBufferDelegate(self, queue: micQueue)
        guard session.canAddOutput(output) else {
            throw RecorderError.setupFailed("The microphone capture output is unavailable.")
        }
        session.addOutput(output)
        micCaptureSession = session
        micOutput = output
    }

    // MARK: - SCStreamOutput

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard isActivelyRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        switch type {
        case .screen:
            writerQueue.async { [weak self, sampleBuffer] in
                self?.appendVideo(sampleBuffer)
            }
        case .audio:
            mediaAudioMixer.appendSystemAudio(sampleBuffer)
            observerQueue.async { [weak self, sampleBuffer] in
                guard let self else { return }
                let level = self.calculateAudioLevel(from: sampleBuffer)
                self.levelLock.lock()
                self.systemLevel = level
                let mic = self.micLevel
                self.levelLock.unlock()
                self.onAudioLevels?(mic, level)
                self.onSystemAudioSample?(sampleBuffer)
            }
        case .microphone:
            break
        @unknown default:
            break
        }
    }

    private func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard isActivelyRecording,
              let writer = screenWriter,
              writer.status == .writing,
              let input = screenVideoInput,
              let adaptor = screenPixelBufferAdaptor,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let sourceTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard sourceTime.isNumeric else { return }
        let presentationTime = normalizedTime(sourceTime)
        guard !lastVideoTime.isNumeric || presentationTime > lastVideoTime else { return }

        guard input.isReadyForMoreMediaData else {
            failWriter(RecorderError.encodingFailed("The screen encoder could not keep up with the display."))
            return
        }
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            failWriter(writer.error ?? RecorderError.encodingFailed("A screen frame could not be encoded."))
            return
        }
        lastVideoTime = presentationTime
    }

    private func appendMixedAudio(_ chunk: TimestampedPCMChunk) {
        guard isRecordingOrStopping else { return }
        let presentationTime = normalizedTime(chunk.presentationTime)
        guard !lastAudioTime.isNumeric || presentationTime > lastAudioTime else { return }

        let sampleBuffer: CMSampleBuffer
        do {
            sampleBuffer = try makeAudioSampleBuffer(from: chunk, presentationTime: presentationTime)
        } catch {
            failWriter(error)
            return
        }

        if let writer = screenWriter, let input = screenAudioInput {
            guard writer.status == .writing, input.isReadyForMoreMediaData else {
                failWriter(writer.error ?? RecorderError.encodingFailed("The screen audio encoder could not keep up."))
                return
            }
            guard input.append(sampleBuffer) else {
                failWriter(writer.error ?? RecorderError.encodingFailed("Mixed audio could not be added to the screen recording."))
                return
            }
        }

        if let writer = audioWriter, let input = audioOnlyInput {
            guard writer.status == .writing, input.isReadyForMoreMediaData else {
                failWriter(writer.error ?? RecorderError.encodingFailed("The audio encoder could not keep up."))
                return
            }
            guard input.append(sampleBuffer) else {
                failWriter(writer.error ?? RecorderError.encodingFailed("Mixed audio could not be encoded."))
                return
            }
        }
        lastAudioTime = presentationTime
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard isActivelyRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        mediaAudioMixer.appendMicAudio(sampleBuffer)
        observerQueue.async { [weak self, sampleBuffer] in
            guard let self else { return }
            let level = self.calculateAudioLevel(from: sampleBuffer)
            self.levelLock.lock()
            self.micLevel = level
            self.levelLock.unlock()
            self.onMicAudioSample?(sampleBuffer)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let nsError = error as NSError
        requestStop(captureError: nsError.code == -3817 ? nil : error)
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(
        _ writer: AVAssetWriter,
        didOutputSegmentData segmentData: Data,
        segmentType: AVAssetSegmentType
    ) {
        let copiedData = Data(segmentData)
        let mediaStream: MediaStream
        if writer === screenWriter {
            mediaStream = .screen
        } else if writer === audioWriter {
            mediaStream = .audio
        } else {
            return
        }
        let kind: SegmentKind = segmentType == .initialization ? .initialization : .media

        segmentDeliveryQueue.async { [weak self] in
            guard let self else { return }
            let sequence: Int
            switch mediaStream {
            case .screen:
                sequence = self.screenSequence
                self.screenSequence += 1
                if kind == .initialization { self.screenInitializationSegments += 1 }
                else { self.screenMediaSegments += 1 }
            case .audio:
                sequence = self.audioSequence
                self.audioSequence += 1
                if kind == .initialization { self.audioInitializationSegments += 1 }
                else { self.audioMediaSegments += 1 }
            }
            self.onSegment?(
                CMAFSegment(
                    stream: mediaStream,
                    kind: kind,
                    sequence: sequence,
                    data: copiedData
                )
            )
        }
    }

    private func finishWriters(captureError: Error?) {
        if writerFailure == nil { writerFailure = captureError }
        let writers = [screenWriter, audioWriter].compactMap { $0 }
        pendingWriterFinishes = writers.count
        guard !writers.isEmpty else {
            enqueueCompletion(error: writerFailure ?? RecorderError.encodingFailed("No recording encoder was enabled."))
            return
        }

        screenVideoInput?.markAsFinished()
        screenAudioInput?.markAsFinished()
        audioOnlyInput?.markAsFinished()

        for writer in writers {
            guard writer.status == .writing else {
                writerDidFinish(writer)
                continue
            }
            writer.finishWriting { [weak self, weak writer] in
                guard let self, let writer else { return }
                self.writerQueue.async {
                    self.writerDidFinish(writer)
                }
            }
        }
    }

    private func writerDidFinish(_ writer: AVAssetWriter) {
        if writer.status != .completed, writerFailure == nil {
            writerFailure = writer.error ?? RecorderError.encodingFailed("A media encoder could not finish its final segment.")
        }
        pendingWriterFinishes -= 1
        guard pendingWriterFinishes == 0 else { return }
        enqueueCompletion(error: writerFailure)
    }

    private func enqueueCompletion(error: Error?) {
        // AVAssetWriter invokes its segment delegate before its finish completion.
        // This serial marker therefore runs after every copied final segment.
        segmentDeliveryQueue.async { [weak self] in
            guard let self else { return }
            var finalError = error
            if finalError == nil, self.recordsScreen,
               (self.screenInitializationSegments == 0 || self.screenMediaSegments == 0) {
                finalError = RecorderError.encodingFailed("The screen encoder produced no playable CMAF media.")
            }
            if finalError == nil, self.recordsAudio,
               (self.audioInitializationSegments == 0 || self.audioMediaSegments == 0) {
                finalError = RecorderError.encodingFailed("The audio encoder produced no playable CMAF media.")
            }

            self.stateLock.lock()
            self.state = .completed
            self.stateLock.unlock()

            if let finalError {
                self.onComplete?(.failure(finalError))
            } else {
                self.onComplete?(
                    .success(
                        Completion(
                            screenSegmentCount: self.screenMediaSegments,
                            audioSegmentCount: self.audioMediaSegments
                        )
                    )
                )
            }
        }
    }

    private func failWriter(_ error: Error) {
        if writerFailure == nil { writerFailure = error }
        requestStop(captureError: nil)
    }

    private func cancelWriters() {
        screenWriter?.cancelWriting()
        audioWriter?.cancelWriting()
        screenWriter = nil
        audioWriter = nil
        screenVideoInput = nil
        screenPixelBufferAdaptor = nil
        screenAudioInput = nil
        audioOnlyInput = nil
    }

    private func normalizedTime(_ sourceTime: CMTime) -> CMTime {
        guard sourceTime.isNumeric, captureTimeOrigin.isNumeric else { return .zero }
        let relative = CMTimeSubtract(sourceTime, captureTimeOrigin)
        if relative < .zero { return .zero }
        return CMTimeConvertScale(
            relative,
            timescale: CMTimeScale(TimestampedPCMChunk.sampleRate),
            method: .default
        )
    }

    private func makeAudioSampleBuffer(
        from chunk: TimestampedPCMChunk,
        presentationTime: CMTime
    ) throws -> CMSampleBuffer {
        guard let formatDescription = mixedPCMFormatDescription,
              chunk.frameCount > 0,
              chunk.data.count == chunk.frameCount * MemoryLayout<Float>.size else {
            throw RecorderError.encodingFailed("The mixed audio buffer was malformed.")
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: chunk.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: chunk.data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw RecorderError.encodingFailed("The mixed audio memory buffer could not be created.")
        }
        status = chunk.data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: chunk.data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw RecorderError.encodingFailed("The mixed audio bytes could not be copied.")
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(TimestampedPCMChunk.sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleSize = MemoryLayout<Float>.size
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: chunk.frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw RecorderError.encodingFailed("The mixed audio sample could not be created.")
        }
        return sampleBuffer
    }

    private func calculateAudioLevel(from sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            dataBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer, length >= MemoryLayout<Float>.size else { return 0 }

        let sampleCount = min(length / MemoryLayout<Float>.size, 512)
        let samples = UnsafeRawPointer(dataPointer).bindMemory(to: Float.self, capacity: sampleCount)
        var sum: Float = 0
        for index in 0..<sampleCount { sum += samples[index] * samples[index] }
        return min(1, sqrt(sum / Float(sampleCount)) * 12)
    }

    private var isActivelyRecording: Bool {
        stateLock.lock()
        let value = state == .recording
        stateLock.unlock()
        return value
    }

    private var isRecordingOrStopping: Bool {
        stateLock.lock()
        let value = state == .recording || state == .stopping
        stateLock.unlock()
        return value
    }

    private func claimStart() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard state == .idle else { return false }
        state = .starting
        return true
    }

    private func setState(_ newState: State) {
        stateLock.lock()
        state = newState
        stateLock.unlock()
    }

    private func abortStart() {
        setState(.idle)
        mediaAudioMixer.stop()
        micCaptureSession?.stopRunning()
        cancelWriters()
        stream = nil
    }
}

@available(macOS 13.0, *)
extension ScreenRecorder: AVAssetWriterDelegate {}

// Access is synchronized by dedicated serial queues and locks.
@available(macOS 13.0, *)
extension ScreenRecorder: @unchecked Sendable {}

enum RecorderError: Error, LocalizedError, CustomStringConvertible {
    case noDisplay
    case setupFailed(String)
    case encodingFailed(String)

    var description: String {
        switch self {
        case .noDisplay:
            return "No display found to record."
        case .setupFailed(let reason), .encodingFailed(let reason):
            return reason
        }
    }

    var errorDescription: String? { description }
}
