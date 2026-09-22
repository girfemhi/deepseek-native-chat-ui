//
//  Recorder.swift
//  
//
//  Created by Alisa Mylnikova on 09.03.2023.
//

import Foundation
@preconcurrency import AVFoundation

typealias RecordingProgressHandler = @Sendable (Double, [CGFloat]) -> Void

protocol RecordingService: Actor {
    var isAllowedToRecordAudio: Bool { get }
    var isRecording: Bool { get }
    func setRecorderSettings(_ recorderSettings: RecorderSettings)
    func startRecording(token: UUID, durationProgressHandler: @escaping RecordingProgressHandler) async -> URL?
    func stopRecording(token: UUID?)
}

final actor Recorder: RecordingService {

    // duration and waveform samples
    private let audioSession = AVAudioSession()
    private var audioRecorder: AVAudioRecorder?
    private var recordingTask: Task<Void, Never>?
    private var activeToken: UUID?

    private var soundSamples: [CGFloat] = []
    private var recorderSettings = RecorderSettings()

    var isAllowedToRecordAudio: Bool {
        AVAudioApplication.shared.recordPermission == .granted
    }

    var isRecording: Bool {
        audioRecorder?.isRecording ?? false
    }

    func setRecorderSettings(_ recorderSettings: RecorderSettings) {
        self.recorderSettings = recorderSettings
    }

    func startRecording(token: UUID, durationProgressHandler: @escaping RecordingProgressHandler) async -> URL? {
        guard !Task.isCancelled else { return nil }
        if !isAllowedToRecordAudio {
            let granted = await audioSession.requestRecordPermission()
            guard granted, !Task.isCancelled else { return nil }
        }
        guard !Task.isCancelled else { return nil }
        return startRecordingInternal(token: token, durationProgressHandler)
    }
    
    private func startRecordingInternal(
        token: UUID,
        _ durationProgressHandler: @escaping RecordingProgressHandler
    ) -> URL? {
        let settings: [String : Any] = [
            AVFormatIDKey: Int(recorderSettings.audioFormatID),
            AVSampleRateKey: recorderSettings.sampleRate,
            AVNumberOfChannelsKey: recorderSettings.numberOfChannels,
            AVEncoderBitRateKey: recorderSettings.encoderBitRateKey,
            AVLinearPCMBitDepthKey: recorderSettings.linearPCMBitDepth,
            AVLinearPCMIsFloatKey: recorderSettings.linearPCMIsFloatKey,
            AVLinearPCMIsBigEndianKey: recorderSettings.linearPCMIsBigEndianKey,
            AVLinearPCMIsNonInterleaved: recorderSettings.linearPCMIsNonInterleaved,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        soundSamples = []
        guard let fileExt = fileExtension(for: recorderSettings.audioFormatID) else{
            return nil
        }
        let recordingUrl = RecordingFileStore.makeURL(fileExtension: fileExt)

        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat)
            try audioSession.overrideOutputAudioPort(.speaker)
            try audioSession.setActive(true)
            audioRecorder = try AVAudioRecorder(url: recordingUrl, settings: settings)
            activeToken = token
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()
            durationProgressHandler(0.0, [])

            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard !Task.isCancelled else { break }
                    await self?.onTimer(durationProgressHandler)
                }
            }

            return recordingUrl
        } catch {
            stopRecording(token: token)
            return nil
        }
    }

    func onTimer(_ durationProgressHandler: @escaping RecordingProgressHandler) {
        audioRecorder?.updateMeters()
        if let power = audioRecorder?.averagePower(forChannel: 0) {
            // power from 0 db (max) to -60 db (roughly min)
            let adjustedPower = 1 - (max(power, -60) / 60 * -1)
            soundSamples.append(CGFloat(adjustedPower))
        }
        if let time = audioRecorder?.currentTime {
            durationProgressHandler(time, soundSamples)
        }
    }

    func stopRecording(token: UUID?) {
        if let token, activeToken != token { return }
        audioRecorder?.stop()
        audioRecorder = nil
        activeToken = nil
        recordingTask?.cancel()
        recordingTask = nil
    }

    private func fileExtension(for formatID: AudioFormatID) -> String? {
        switch formatID {
        case kAudioFormatMPEG4AAC:
            return ".aac"
        case kAudioFormatLinearPCM:
            return ".wav"
        case kAudioFormatAppleLossless:
            return ".m4a"
        case kAudioFormatFLAC:
            return ".flac"
        case kAudioFormatULaw:
            return ".wav"
        case kAudioFormatALaw:
            return ".wav"
        default:
            return nil
        }
    }
}

enum RecordingFileStore {
    static let filenamePrefix = "DSH-exyte-recording-"

    static func makeURL(fileExtension: String) -> URL {
        FileManager.tempDirPath
            .appendingPathComponent(filenamePrefix + UUID().uuidString + fileExtension)
    }

    static func isOwned(_ url: URL?) -> Bool {
        guard let url else { return false }
        let standardized = url.standardizedFileURL
        return standardized.deletingLastPathComponent() == FileManager.tempDirPath.standardizedFileURL
            && standardized.lastPathComponent.hasPrefix(filenamePrefix)
    }

    static func deleteIfOwned(_ url: URL?) {
        guard isOwned(url), let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

public struct RecorderSettings : Codable,Hashable {
    var audioFormatID: AudioFormatID
    var sampleRate: CGFloat
    var numberOfChannels: Int
    var encoderBitRateKey: Int
    // pcm
    var linearPCMBitDepth: Int
    var linearPCMIsFloatKey: Bool
    var linearPCMIsBigEndianKey: Bool
    var linearPCMIsNonInterleaved: Bool

    public init(audioFormatID: AudioFormatID = kAudioFormatMPEG4AAC,
                sampleRate: CGFloat = 12000,
                numberOfChannels: Int = 1,
                encoderBitRateKey: Int = 0,
                linearPCMBitDepth: Int = 16,
                linearPCMIsFloatKey: Bool = false,
                linearPCMIsBigEndianKey: Bool = false,
                linearPCMIsNonInterleaved: Bool = false) {
        self.audioFormatID = audioFormatID
        self.sampleRate = sampleRate
        self.numberOfChannels = numberOfChannels
        self.encoderBitRateKey = encoderBitRateKey
        self.linearPCMBitDepth = linearPCMBitDepth
        self.linearPCMIsFloatKey = linearPCMIsFloatKey
        self.linearPCMIsBigEndianKey = linearPCMIsBigEndianKey
        self.linearPCMIsNonInterleaved = linearPCMIsNonInterleaved
    }
}

extension AVAudioSession {
    func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}
