@preconcurrency import AVFoundation
import ArgumentParser
import Foundation
import SwiftTUI
import Upscaling

// MARK: - MetalFXUpscale

@main struct FXUpscale: AsyncParsableCommand {
    @Option(name: [.customShort("i"), .customLong("input")], help: "input video file to upscale",
                transform: URL.init(fileURLWithPath:))
            var input: URL
    @Option(name: [.customShort("o"), .customLong("output")], help: "output video file path")
    var output: String?
    @Option(name: .shortAndLong, help: "width in pixels of output video")
    var width: Int?
    @Option(name: .shortAndLong, help: "height in pixels of output video")
    var height: Int?
    @Option(name: .shortAndLong, help: ArgumentHelp("scale factor (e.g. 2.0). Overrides width/height", valueName: "factor"))
    var scale: Double?
    @Option(name: .shortAndLong, help: "output codec: 'hevc', 'prores', or 'h264")
    var codec: String = "hevc"
    @Option(name: .shortAndLong, help: "encoder quality 0 – 100. Applies to HEVC/H.264")
    var quality: Int?
    @Option(name: .short, help: ArgumentHelp("GOP size (default: let encoder decide the GOP size)", valueName: "size") )
    var gopSize: Int?

    @Flag(
        name: .customLong("bf", withSingleDash: true),
        help:
            "use B-frames. (default: off for HEVC/H.264 to improve scrubbing)"
    )
    var allowFrameReordering: Bool = false

    @Flag(name: .customLong("prio_speed", withSingleDash: true), help: "prioritize speed over quality")
    var prioritizeSpeed: Bool = false
    @Flag(name: .customShort("y"), help: "overwrite output file")
    var allowOverWrite: Bool = false

    mutating func run() async throws {
        guard ["mov", "m4v", "mp4"].contains(input.pathExtension.lowercased()) else {
            throw ValidationError("Unsupported file type. Supported types: mov, m4v, mp4")
        }

        guard FileManager.default.fileExists(atPath: input.path) else {
            throw ValidationError("File does not exist at \(input.path(percentEncoded: false))")
        }

        let asset = AVAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ValidationError("Failed to get video track from input file")
        }
        // get various data
        let duration = try await videoTrack.load(.timeRange).duration
        let fps = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = Int(CMTimeGetSeconds(duration) * Double(fps))
        let videoLength = formatTime(CMTimeGetSeconds(duration))

        let formatDescription = try await videoTrack.load(.formatDescriptions).first
        guard let dimensions = formatDescription.map({ CMVideoFormatDescriptionGetDimensions($0) }) else {
            throw ValidationError("Failed to determine input video dimensions")
        }
        let inputSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))

        // Validate mutually exclusive options
        if scale != nil, (width != nil || height != nil) {
            throw ValidationError("Cannot combine --scale with --width/--height")
        }

        // 1. Use --scale if provided
        // 2. Use passed in width/height
        // 3. Use proportional width/height if only one is specified
        // 4. Default to 2x upscale

        var outputWidth: Int
        var outputHeight: Int

        if let s = scale {
            guard s > 0 else { throw ValidationError("--scale must be greater than 0") }
            outputWidth = Int(inputSize.width * CGFloat(s))
            outputHeight = Int(inputSize.height * CGFloat(s))
        } else {
            outputWidth =
                width ?? height.map { Int(inputSize.width * (CGFloat($0) / inputSize.height)) } ?? Int(
                    inputSize.width) * 2
            outputHeight =
                height ?? Int(inputSize.height * (CGFloat(outputWidth) / inputSize.width))
        }

        guard outputWidth > 0, outputHeight > 0 else {
            throw ValidationError("Calculated output size must be greater than zero")
        }

        guard outputWidth <= UpscalingExportSession.maxOutputSize,
            outputHeight <= UpscalingExportSession.maxOutputSize
        else {
            throw ValidationError("Maximum supported width/height: 16384")
        }

        let outputSize = CGSize(width: outputWidth, height: outputHeight)
        let requestedOutputCodec: AVVideoCodecType? = try {
            switch codec.lowercased() {
            case "prores": return .proRes422
            case "h264": return .h264
            case "hevc": return .hevc
            default:
                throw ValidationError("Invalid codec. Use one of: hevc, h264, prores")
            }
        }()

        // Through anecdotal tests anything beyond 14.5K fails to encode for anything other than ProRes
        let convertToProRes = (outputSize.width * outputSize.height) > (14500 * 8156)

        if convertToProRes {
            CommandLine.info(
                "Forced ProRes conversion due to output size being larger than 14.5K (will fail otherwise)"
            )
        }

        let effectiveOutputCodec: AVVideoCodecType? =
            convertToProRes ? .proRes422 : requestedOutputCodec

        // Validate quality range if provided
        var normalizedQuality: Double? = nil
        if let q = quality {
            guard (0...100).contains(q) else {
                throw ValidationError("--quality must be between 0 and 100")
            }
            normalizedQuality = Double(q) / 100.0
        }
        let exportSession = UpscalingExportSession(
            asset: asset,
            outputCodec: effectiveOutputCodec,
            preferredOutputURL: output.map { URL(fileURLWithPath: $0) }
                                    ?? input.renamed { "\($0) Upscaled" },
            inSize: inputSize,
            outputSize: outputSize,
            creator: ProcessInfo.processInfo.processName,
            gopSize: gopSize,
            allowFrameReordering: allowFrameReordering,
            quality: normalizedQuality,
            prioritizeSpeed: prioritizeSpeed,
            allowOverWrite: allowOverWrite
        )

        CommandLine.info("Video duration: \(videoLength), total frames: \(totalFrames)")
        CommandLine.info(
            [
                "Upscaling: \(Int(inputSize.width))x\(Int(inputSize.height)) ",
                "to \(Int(outputSize.width))x\(Int(outputSize.height)) ",
            ].joined())
        CommandLine.info(String("Codec: \(effectiveOutputCodec?.rawValue ?? "hevc")"))
        ProgressBar.start(progress: exportSession.progress)

        let startTime = Date()
        do {
            try await exportSession.export()
            
            let elapsed = Date().timeIntervalSince(startTime)
            let elapsedDuration = formatTime(elapsed)
            let encodedFPS = Double(totalFrames) / elapsed
            
            ProgressBar.stop()
            
            CommandLine.info("Encoding time: \(elapsedDuration), fps: \(String(format: "%.2f", encodedFPS))")
            CommandLine.success("Video successfully upscaled!")
        } catch {
            CommandLine.warn(error.localizedDescription)
        }
    }
}

func formatTime(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60
    let milliseconds = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)

    return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
}

