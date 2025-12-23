@preconcurrency import AVFoundation
@preconcurrency import ArgumentParser
import Foundation
import SwiftTUI
import Upscaling

// MARK: - MetalFXUpscale

let version: String = "2.6.0-skl"

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
    case hd   // 1280x720
    case fhd  // 1920x1080
    case qhd // 2160x1440
    case k4   // 3840x2160
    case k8   // 7680x4320
    
    init?(argument: String) {
        switch argument.lowercased() {
        case "hd": self = .hd
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
        case .hd: return 1280
        case .fhd: return 1920
        case .qhd: return 2160
        case .k4: return 3840
        case .k8: return 7680
        }
    }  
    var maxHeight: CGFloat {
        switch self {
        case .hd: return 720
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

struct FileOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "input video file to upscale. This option is required.",
            transform: URL.init(fileURLWithPath:))
    var input: URL
    @Option(name: .shortAndLong, help: "output video file path.\nIf not specified, ' upscaled' is appended to the input file name.")
    var output: String?
    @Flag(name: [ .customShort("y"), .customLong("overwrite") ], help: "overwrite output file")
    var allowOverWrite: Bool = false
    @Flag(name: [ .customShort("a"), .long ], help: "Disable audio processing. The output file will have no audio tracks.")
    var noaudio: Bool = false
    @Option(name: .customLong("color_input"), help: ArgumentHelp("expert option: input color space for SD content, if not autodected: 'pal' or 'ntsc'", valueName: "space"))
    var inputSDColor: String = "auto"
}

struct ScaleOptions: ParsableArguments {
    @Option(name: .shortAndLong, help: "width in pixels of output video.\nIf only width is specified, height is calculated proportionally.")
    var width: Int?
    @Option(name: .shortAndLong, help: "height in pixels of output video.\nIf only height is specified, width is calculated proportionally.")
    var height: Int?
    @Option(name: .shortAndLong, help: ArgumentHelp("""
                    Scale to target resolution <preset>. 
                    Presets are: 'hd' (1280x720), 'fhd' (1920x1080), ' qhd' or 'wqhd' (2160x1440), '4k' or 'uhd' (3840x2160),  '8k' (7680x4320)
                    """, valueName: "preset"))
    var target: TargetResolution?
    @Flag(name: [.customShort("1"), .long], help: "Scale anamorphic video to square pixels when using --target")
    var square: Bool = false
    @Option(name: [.customShort("r"), .long], help: ArgumentHelp("Crop rectangle 'width:height:left:top'. Applied before upscaling.", valueName: "rect"))
    var crop: CropRect?
    @Option(name: .shortAndLong, help: ArgumentHelp("Sharpen video after upscaling. Recommended values: 0.5 - 0.9 (fhd) ", valueName: "amount"))
    var sharpen: Float?   
}

struct CodecOptions: ParsableArguments {
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
}

@main struct FXUpscale: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Metal-based video upscale.",
        usage: "fx-upscale -i input-file [options]",
        version: version,
        helpNames: .long
    )
    @OptionGroup(title: "File Options")
    var file: FileOptions
    @OptionGroup(title: "Scaling Options")
    var scale: ScaleOptions
    @OptionGroup(title: "Codec Options")
    var codec: CodecOptions
    @Flag(name: .long, help: "disable logging")
    var quiet: Bool = false

    mutating func run() async throws {
        guard ["mov", "m4v", "mp4"].contains(file.input.pathExtension.lowercased()) else {
            throw ValidationError("Unsupported file type. Supported types: mov, m4v, mp4")
        }

        guard FileManager.default.fileExists(atPath: file.input.path) else {
            throw ValidationError("File does not exist at \(file.input.path(percentEncoded: false))")
        }

        let asset = AVAsset(url: file.input)
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
        let cropRect: CGRect? = scale.crop?.rect
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

        if scale.square, scale.target == nil {
            throw ValidationError("--square can only be used with --target")
        }

        // validate mutually exclusive options
        if scale.target != nil, scale.width != nil || scale.height != nil {
            throw ValidationError("Cannot combine --target with --width/--height")
        }

        // 1. Use --target if provided
        // 2. Use passed in width/height
        // 3. Use proportional width/height if only one is specified

        var outputWidth: Int
        var outputHeight: Int

        // Apply target resolution if provided
        if let target = scale.target {
            let targetSize = getOutputSize(
                inputDIM: inputSize, 
                origSAR: formatDescription?.pixelAspectRatio ?? CGSize(width: 1, height: 1), 
                maxDIM: CGSize(width: target.maxWidth, height: target.maxHeight),
                square: scale.square
            )
            outputWidth = Int(targetSize.width)
            outputHeight = Int(targetSize.height)
        } else {
            outputWidth =
                scale.width ?? scale.height.map { Int(inputSize.width * (CGFloat($0) / inputSize.height)) } ?? Int(
                    inputSize.width)
            outputHeight =
                scale.height ?? Int(inputSize.height * (CGFloat(outputWidth) / inputSize.width))
            
            guard outputWidth > 0, outputHeight > 0 else {
                throw ValidationError("Output size must be greater than zero")
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
            switch codec.codec.lowercased() {
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

        // validate SD color space option
        if file.inputSDColor != "auto" && file.inputSDColor != "pal" && file.inputSDColor != "ntsc" {
            throw ValidationError("Invalid SD color space. Use one of: pal, ntsc")
        }

        // only autodetect for SD content
        if originalInputSize.width <= 720, originalInputSize.height <= 576 {
            // auto-detect based on resolution, this should work on all DVD ripped content
            if file.inputSDColor == "auto" {
                if originalInputSize.height == 576 { 
                    file.inputSDColor = "pal"
                }
            }
            // some SD content might have been cropped already, so use pixel aspect ratio
            if file.inputSDColor == "auto" { 
                if let par = formatDescription?.pixelAspectRatio {
                    if (par.width == 16) || (par.width == 64) { file.inputSDColor = "pal" }
                    if (par.width == 10) || (par.width == 40) { file.inputSDColor = "ntsc" }
                }
            }
            // still not detected, so test for fps
            if file.inputSDColor == "auto" { 
                file.inputSDColor = fps == 25.0 ? "pal" : "ntsc"
            }
            // some rare cases where we can't detect, default to ntsc, inform the user
            if file.inputSDColor == "auto" {
                CommandLine.warn("Unable to detect SD color space, defaulting to NTSC. Overwrite with --color_input if needed.")
                file.inputSDColor = "ntsc"
            }
        } else {
            if file.inputSDColor != "auto" {
                CommandLine.warn("--color_input is only applicable to SD content (<= 720x576), ignoring")
            }
            file.inputSDColor = "none" // disable for non-SD content
        }

        // validate sharpen value if provided
        if scale.sharpen != nil {
            guard scale.sharpen! >= 0.0 && scale.sharpen! <= 5.0 else {
                throw ValidationError("Sharpen value must be between 0.0 and 5.0")
            }
        }

        // Setup logging
        let logging = LogInfo()
        await logging.setVerbose(!quiet)

        // Validate quality range if provided
        var normalizedQuality: Double
        guard (0...100).contains(codec.quality) else {
            throw ValidationError("--quality must be between 0 and 100")
        }
        normalizedQuality = Double(codec.quality) / 100.0

        // now create the export session
        let exportSession = UpscalingExportSession(
            asset: asset,
            outputCodec: effectiveOutputCodec,
            preferredOutputURL: file.output.map { URL(fileURLWithPath: $0) }
                ?? file.input.renamed { "\($0) upscaled" },
            inSize: inputSize,
            outputSize: outputSize,
            creator: ProcessInfo.processInfo.processName,
            gopSize: codec.gopSize,
            bframes: codec.bframes.boolValue,
            quality: normalizedQuality,
            prioritizeSpeed: codec.prioritizeSpeed.boolValue,
            allowOverWrite: file.allowOverWrite,
            crop: cropRect,
            processAudio: !file.noaudio,
            inputSDColor: file.inputSDColor,
            sharpen: scale.sharpen
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
        let sdinfo = file.inputSDColor == "none" ? ":" : " SD \(file.inputSDColor.uppercased()):"      
        await logging.info("Upscaling\(sdinfo) \(Int(inputSize.width))x\(Int(inputSize.height)) to \(Int(outputSize.width))x\(Int(outputSize.height))")
        await logging.info(
            [
                "Codec: \(codec.codec.lowercased())",
                codec.bframes.boolValue ? "bframes" : nil,
                "quality \(codec.quality)",
                codec.gopSize.map { "gop \($0)" },
                scale.sharpen.map { "sharpen \($0)" },
            ]
            .compactMap { $0 }
            .joined(separator: ", ")
        )
        codec.prioritizeSpeed.boolValue ? nil : await logging.info("Prioritize speed: no")

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

func getOutputSize(inputDIM: CGSize, origSAR: CGSize, maxDIM: CGSize, square: Bool) -> CGSize {
    var newWidth: CGFloat
    var newHeight: CGFloat
    var inputDIM = inputDIM

    if square {
        newWidth = maxDIM.width
        inputDIM.width = inputDIM.width * origSAR.width / origSAR.height
    } else {
        newWidth = maxDIM.width * origSAR.height / origSAR.width
    }
    newHeight = newWidth / inputDIM.width * inputDIM.height
    if newHeight > maxDIM.height {
        newHeight = maxDIM.height
        newWidth = newHeight * inputDIM.width / inputDIM.height  
    }
    // ensure even dimensions, always round down to avoid exceeding maxDIM
    return CGSize(width: floor(newWidth / 2) * 2, height: floor(newHeight / 2) * 2)
}