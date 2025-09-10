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
    @Option(name: .shortAndLong, help: "The output file width")
    var width: Int?
    @Option(name: .shortAndLong, help: "The output file height")
    var height: Int?
    @Option(name: .shortAndLong, help: "Scale factor (e.g. 2.0). Overrides width/height")
    var scale: Double?
    @Option(name: .shortAndLong, help: "Output codec: 'hevc', 'prores', or 'h264' (default: hevc)")
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

        let formatDescription = try await videoTrack.load(.formatDescriptions).first
        let dimensions = formatDescription.map {
            CMVideoFormatDescriptionGetDimensions($0)
        }.map {
            CGSize(width: Int($0.width), height: Int($0.height))
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let inputSize = dimensions ?? naturalSize

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
            outputSize: outputSize,
            creator: ProcessInfo.processInfo.processName,
            gopSize: gopSize,
            allowFrameReordering: allowFrameReordering,
            quality: normalizedQuality
        )

        CommandLine.info(
            [
                "Upscaling from \(Int(inputSize.width))x\(Int(inputSize.height)) ",
                "to \(Int(outputSize.width))x\(Int(outputSize.height)) ",
                "using codec: \(effectiveOutputCodec?.rawValue ?? "hevc")",
            ].joined())
        ProgressBar.start(progress: exportSession.progress)
        try await exportSession.export()
        ProgressBar.stop()
        CommandLine.success("Video successfully upscaled!")
    }
}
