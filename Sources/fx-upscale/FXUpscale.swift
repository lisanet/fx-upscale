@preconcurrency import AVFoundation
@preconcurrency import ArgumentParser
import Foundation
import SwiftTUI
import Upscaling

// MARK: - MetalFXUpscale

let version: String = "2.2.1-skl"

struct CropRect: ExpressibleByArgument {
    let rect: CGRect

    init?(argument: String) {
        let parts = argument.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 4 else { return nil }
        self.rect = CGRect(x: parts[2], y: parts[3], width: parts[0], height: parts[1])
    }
}

enum FlagBool: ExpressibleByArgument {
    case yes
    case no

    init?(argument: String) {
        switch argument.lowercased() {
        case "yes", "true", "1":
            self = .yes
        case "no", "false", "0":
            self = .no
        default:
            return nil
        }
    }
    var boolValue: Bool {
        switch self {
        case .yes: return true
        case .no: return false
        }
    }
}

enum TargetResolution: ExpressibleByArgument{
    case fhd  // 1920x1080
    case qhd // 2160x1440
    case k4   // 3840x2160
    case k8   // 7680x4320
    
    init?(argument: String) {
        switch argument.lowercased() {
        case "fhd": self = .fhd
        case "qhd": self = .qhd
        case "wqhd": self = .qhd
        case "uhd": self = .k4
        case "4k": self = .k4
        case "8k": self = .k8
        default: return nil
        }
    }
    var maxWidth: CGFloat {
        switch self {
        case .fhd: return 1920
        case .qhd: return 2160
        case .k4: return 3840
        case .k8: return 7680
        }
    }  
    var maxHeight: CGFloat {
        switch self {
        case .fhd: return 1080
        case .qhd: return 1440
        case .k4: return 2160
        case .k8: return 4320
        }
    }
}

actor LogInfo {
    private var verbose = true

    func setVerbose(_ value: Bool) {
        verbose = value
    }

    func info(_ message: String) {
        verbose ? CommandLine.info(message) : nil
    }
}

@main struct FXUpscale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Metal-based video upscale.",
        usage: "fx-upscale -i input-file [options]",
        version: version,
        helpNames: .long
    )
    @Option(name: .shortAndLong, help: "input video file to upscale. This option is required.",
            transform: URL.init(fileURLWithPath:))
    var input: URL
    @Option(name: .shortAndLong, help: "output video file path.\nIf not specified, ' upscaled' is appended to the input file name.")
    var output: String?
    @Option(name: .shortAndLong, help: "width in pixels of output video.\nIf only width is specified, height is calculated proportionally.")
    var width: Int?
    @Option(name: .shortAndLong, help: "height in pixels of output video.\nIf only height is specified, width is calculated proportionally.")
    var height: Int?
    @Option(name: .shortAndLong, help: ArgumentHelp("""
                    scale factor (e.g. 2.0). Overrides width/height. 
                    If neither target, width, height nor scale is given, the video is upscaled by factor 2.0
                    """, valueName: "factor"))
    var scale: Double?
    @Option(name: .shortAndLong, help: ArgumentHelp("""
                    Scale to target resolution <preset>. 
                    Presets are: 'fhd' (1920x1080), ' qhd' or 'wqhd' (2160x1440), '4k' or 'uhd' (3840x2160),  '8k' (7680x4320)
                    """, valueName: "preset"))
    var target: TargetResolution?
    @Option(name: [.customShort("r"), .long], help: ArgumentHelp("Crop rectangle 'width:height:left:top'. Applied before upscaling.", valueName: "rect"))
    var crop: CropRect?
    @Option(name: .shortAndLong, help: "output codec: 'hevc', 'prores', or 'h264")
    var codec: String = "hevc"
    @Option(name: .shortAndLong, help: "encoder quality 0 – 100. Applies to HEVC/H.264, ProRes is always lossless")
    var quality: Int = 58
    @Option(name: [.short, .customLong("gop")], help: ArgumentHelp("GOP size (default: let encoder decide the GOP size)", valueName: "size"))
    var gopSize: Int?
    @Option(name: .shortAndLong, help: ArgumentHelp("use B-frames. You can use yes/no, true/false, 1/0", valueName: "bool"))
    var bframes: FlagBool = .yes
    @Option(name: [ .customShort("p"), .customLong("prio_speed")], help: ArgumentHelp("prioritize speed over quality. You can use yes/no, true/false, 1/0", valueName: "bool"))
    var prioritizeSpeed: FlagBool = .yes
    @Flag(name: .customShort("y"), help: "overwrite output file")
    var allowOverWrite: Bool = false
    @Flag(name: .long, help: "disable logging")
    var quiet: Bool = false

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

        // get input video dimensions and validate crop rect if provided
        let formatDescription = try await videoTrack.load(.formatDescriptions).first
        guard let dimensions = formatDescription.map({ CMVideoFormatDescriptionGetDimensions($0) }) else {
            throw ValidationError("Failed to determine input video dimensions")
        }
        let originalInputSize = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
        let cropRect: CGRect? = crop?.rect
        // Validate crop rect if provided
        if let crop = cropRect {
            guard crop.width > 0, crop.height > 0, crop.origin.x >= 0, crop.origin.y >= 0 else {
                throw ValidationError("Invalid crop rectangle. All values must be positive.")
            }
            guard crop.maxX <= originalInputSize.width, crop.maxY <= originalInputSize.height else {
                throw ValidationError("Crop rectangle cannot be larger than the input video dimensions.")
            }
        }
        let inputSize = cropRect?.size ?? originalInputSize

        // validate mutually exclusive options
        if target != nil, scale != nil || width != nil || height != nil {
            throw ValidationError("Cannot combine --target with --scale or --width/--height")
        }

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

        // Apply target resolution if provided
        if let target = target {
            // to be implemented
            let targetSize = getOutputSize(
                inputDIM: inputSize, 
                origSAR: formatDescription?.pixelAspectRatio ?? CGSize(width: 1, height: 1), 
                maxDIM: CGSize(width: target.maxWidth, height: target.maxHeight)
            )
            outputWidth = Int(targetSize.width)
            outputHeight = Int(targetSize.height)
        } else {
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
        }
        let outputSize = CGSize(width: outputWidth, height: outputHeight)

        // Validate codec
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
        let effectiveOutputCodec:
            AVVideoCodecType? = convertToProRes ? .proRes422 : requestedOutputCodec

        // Setup logging
        let logging = LogInfo()
        await logging.setVerbose(!quiet)

        // Validate quality range if provided
        var normalizedQuality: Double
        guard (0...100).contains(quality) else {
            throw ValidationError("--quality must be between 0 and 100")
        }
        normalizedQuality = Double(quality) / 100.0

        // now create the export session
        let exportSession = UpscalingExportSession(
            asset: asset,
            outputCodec: effectiveOutputCodec,
            preferredOutputURL: output.map { URL(fileURLWithPath: $0) }
                ?? input.renamed { "\($0) upscaled" },
            inSize: inputSize,
            outputSize: outputSize,
            creator: ProcessInfo.processInfo.processName,
            gopSize: gopSize,
            bframes: bframes.boolValue,
            quality: normalizedQuality,
            prioritizeSpeed: prioritizeSpeed.boolValue,
            allowOverWrite: allowOverWrite,
            crop: cropRect
        )
 
        await logging.info("Video duration: \(videoLength), total frames: \(totalFrames)")
        if let crop = cropRect { 
            await logging.info(
                [ 
                    "Cropping: \(Int(originalInputSize.width))x\(Int(originalInputSize.height))",
                    " to \(Int(crop.width))x\(Int(crop.height))",
                    " at (\(Int(crop.origin.x)),\(Int(crop.origin.y)))" 
                ].joined()
            )
        }           
        await logging.info("Upscaling: \(Int(inputSize.width))x\(Int(inputSize.height)) to \(Int(outputSize.width))x\(Int(outputSize.height))")
        await logging.info(
            [
                "Codec: \(codec.lowercased())",
                bframes.boolValue ? "bframes" : nil,
                "quality \(quality)",
                gopSize.map { "gop \($0)" },
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        prioritizeSpeed.boolValue ? nil : await logging.info("Prioritize speed: no")

        ProgressBar.start(progress: exportSession.progress)

        let startTime = Date()
        do {
            try await exportSession.export()

            let elapsed = Date().timeIntervalSince(startTime)
            let elapsedDuration = formatTime(elapsed)
            let encodedFPS = Double(totalFrames) / elapsed

            ProgressBar.stop()

            await logging.info("Encoding time: \(elapsedDuration), fps: \(String(format: "%.2f", encodedFPS))")
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

func getOutputSize(inputDIM: CGSize, origSAR: CGSize, maxDIM: CGSize) -> CGSize {
    var newWidth: CGFloat
    var newHeight: CGFloat
        
    newWidth = maxDIM.width * origSAR.height / origSAR.width
    newHeight = newWidth / inputDIM.width * inputDIM.height
    if newHeight > maxDIM.height {
        newHeight = maxDIM.height
        newWidth = newHeight * inputDIM.width / inputDIM.height
    }
    // ensure even dimensions, always round down to avoid exceeding maxDIM
    return CGSize(width: floor(newWidth / 2) * 2, height: floor(newHeight / 2) * 2)
}