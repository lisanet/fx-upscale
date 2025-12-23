@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import MetalFX


// MARK: - Upscaler

public final class Upscaler {
    // MARK: - Metal Shader Source
    
    // By embedding the Metal shader source code directly into the Swift file,
    // we remove the need to load external .metallib files. This allows for a truly
    // single, statically-linked executable that can be distributed easily.
    // The shader is compiled once at runtime when the Upscaler is initialized.
    private static let sharpenShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // YUV color space conversion constants
    constant float3 kLumaWeights = float3(0.299, 0.587, 0.114);

    // A simple sharpening kernel that operates only on the luma channel.
    // It uses a 3x3 convolution filter for an unsharp mask effect.
    kernel void sharpenLuma(texture2d<float, access::read> inTexture [[texture(0)]],
                            texture2d<float, access::write> outTexture [[texture(1)]],
                            constant float &sharpness [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
    {
        // Ensure we don't read/write outside of the texture bounds
        if (gid.x >= outTexture.get_width() || gid.y >= outTexture.get_height()) {
            return;
        }

        // --- Unsharp Masking on Luma ---

        // 1. Get the original color and calculate its luma
        float4 originalColor = inTexture.read(gid);
        float originalLuma = dot(originalColor.rgb, kLumaWeights);

        // 2. Create a blurred version of the luma by averaging neighbors (3x3 box blur)
        float blurredLuma = 0.0;
        for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
                uint2 sampleCoord = uint2(gid.x + x, gid.y + y);
                // Clamp to edge to handle boundary pixels
                sampleCoord.x = clamp(sampleCoord.x, uint(0), inTexture.get_width() - 1);
                sampleCoord.y = clamp(sampleCoord.y, uint(0), inTexture.get_height() - 1);
                
                float4 neighborColor = inTexture.read(sampleCoord);
                blurredLuma += dot(neighborColor.rgb, kLumaWeights);
            }
        }
        blurredLuma /= 9.0;

        // 3. Calculate the "unsharp mask" (difference between original and blurred luma)
        //    and apply the sharpness factor.
        float mask = originalLuma - blurredLuma;
        float sharpenedLuma = originalLuma + (mask * sharpness);

        // 4. Calculate the difference in luma and add it back to the original RGB channels.
        //    This preserves the original hue and saturation.
        float lumaDifference = sharpenedLuma - originalLuma;
        float3 sharpenedRgb = originalColor.rgb + lumaDifference;

        // 5. Write the final, sharpened color, ensuring it's clamped to the valid [0,1] range.
        outTexture.write(float4(saturate(sharpenedRgb), originalColor.a), gid);
    }
    """
    
    // MARK: Lifecycle

    public init?(inputSize: CGSize, outputSize: CGSize, crop: CGRect? = nil, sharpen: Double? = nil) {
        let spatialScalerDescriptor = MTLFXSpatialScalerDescriptor()
        spatialScalerDescriptor.inputSize = inputSize
        spatialScalerDescriptor.outputSize = outputSize
        spatialScalerDescriptor.colorTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.outputTextureFormat = .bgra8Unorm
        spatialScalerDescriptor.colorProcessingMode = .perceptual
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.width = Int(outputSize.width)
        textureDescriptor.height = Int(outputSize.height)
        textureDescriptor.pixelFormat = .bgra8Unorm
        textureDescriptor.storageMode = .private
        textureDescriptor.usage = [.shaderWrite, .shaderRead]
        guard let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let spatialScaler = spatialScalerDescriptor.makeSpatialScaler(device: device),
            let intermediateOutputTexture = device.makeTexture(descriptor: textureDescriptor)
        else { return nil }
        self.commandQueue = commandQueue
        self.spatialScaler = spatialScaler
        self.intermediateOutputTexture = intermediateOutputTexture
        self.crop = crop
        self.sharpen = sharpen

        if sharpen != nil {
            do {
                let library = try device.makeLibrary(source: Self.sharpenShaderSource, options: nil)
                if let sharpenLumaFunction = library.makeFunction(name: "sharpenLuma") {
                    sharpenPipelineState = try device.makeComputePipelineState(function: sharpenLumaFunction)
                } else {
                    sharpenPipelineState = nil
                }
            } catch {
                print("Failed to create Metal library from source: \(error)")
                sharpenPipelineState = nil
            }
        } else {
            sharpenPipelineState = nil
        }

        var textureCache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        guard let textureCache else { return nil }
        self.textureCache = textureCache
        var pixelBufferPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(
            nil, nil,
            [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferWidthKey: Int(outputSize.width),
                kCVPixelBufferHeightKey: Int(outputSize.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ] as CFDictionary, &pixelBufferPool)
        guard let pixelBufferPool else { return nil }
        self.pixelBufferPool = pixelBufferPool
    }

    // MARK: Public

    @discardableResult public func upscale(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) async -> CVPixelBuffer {
        do {
            let (commandBuffer, outputPixelBuffer) = try upscaleCommandBuffer(
                pixelBuffer,
                pixelBufferPool: pixelBufferPool,
                outputPixelBuffer: outputPixelBuffer
            )
            try await withCheckedThrowingContinuation { continuation in
                commandBuffer.addCompletedHandler { commandBuffer in
                    if let error = commandBuffer.error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
                commandBuffer.commit()
            } as Void
            return outputPixelBuffer
        } catch {
            return pixelBuffer
        }
    }

    @discardableResult public func upscale(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) -> CVPixelBuffer {
        do {
            let (commandBuffer, outputPixelBuffer) = try upscaleCommandBuffer(
                pixelBuffer,
                pixelBufferPool: pixelBufferPool,
                outputPixelBuffer: outputPixelBuffer
            )
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            if commandBuffer.error != nil { return pixelBuffer }
            return outputPixelBuffer
        } catch {
            return pixelBuffer
        }
    }

    public func upscale(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil,
        completionHandler: @escaping (CVPixelBuffer) -> Void
    ) {
        do {
            let (commandBuffer, outputPixelBuffer) = try upscaleCommandBuffer(
                pixelBuffer,
                pixelBufferPool: pixelBufferPool,
                outputPixelBuffer: outputPixelBuffer
            )
            commandBuffer.addCompletedHandler { commandBuffer in
                if commandBuffer.error != nil {
                    completionHandler(pixelBuffer)
                } else {
                    completionHandler(outputPixelBuffer)
                }
            }
            commandBuffer.commit()
        } catch {
            completionHandler(pixelBuffer)
        }
    }

    // MARK: Private

    private let commandQueue: MTLCommandQueue
    private let spatialScaler: MTLFXSpatialScaler
    private let intermediateOutputTexture: MTLTexture
    private let textureCache: CVMetalTextureCache
    private let pixelBufferPool: CVPixelBufferPool
    private let crop: CGRect?
    private let sharpen: Double?
    private let sharpenPipelineState: MTLComputePipelineState?

    private func upscaleCommandBuffer(
        _ pixelBuffer: CVPixelBuffer,
        pixelBufferPool: CVPixelBufferPool? = nil,
        outputPixelBuffer: CVPixelBuffer? = nil
    ) throws -> (MTLCommandBuffer, CVPixelBuffer) {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            throw Error.unsupportedPixelFormat
        }

        guard
            let outputPixelBuffer = outputPixelBuffer
                ?? {
                    var outputPixelBuffer: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(
                        nil, pixelBufferPool ?? self.pixelBufferPool, &outputPixelBuffer)
                    return outputPixelBuffer
                }()
        else { throw Error.couldNotCreatePixelBuffer }

        var colorTexture: CVMetalTexture!
        var status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            pixelBuffer,
            [:] as CFDictionary,
            .bgra8Unorm,
            pixelBuffer.width,
            pixelBuffer.height,
            0,
            &colorTexture
        )
        guard status == kCVReturnSuccess,
            let sourceTexture = CVMetalTextureGetTexture(colorTexture)
        else {
            throw Error.couldNotCreateMetalTexture
        }

        var upscaledTexture: CVMetalTexture!
        status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            textureCache,
            outputPixelBuffer,
            [:] as CFDictionary,
            .bgra8Unorm,
            outputPixelBuffer.width,
            outputPixelBuffer.height,
            0,
            &upscaledTexture
        )
        guard status == kCVReturnSuccess,
                let upscaledTexture = CVMetalTextureGetTexture(upscaledTexture)
        else {
            throw Error.couldNotCreateMetalTexture
        }

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw Error.couldNotMakeCommandBuffer
        }

        var finalSourceTexture: MTLTexture = sourceTexture
        if let cropRect = crop {
            let cropTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: sourceTexture.pixelFormat,
                width: Int(cropRect.width),
                height: Int(cropRect.height),
                mipmapped: false
            )
            cropTextureDescriptor.usage = sourceTexture.usage
            cropTextureDescriptor.storageMode = .private

            guard let croppedTexture = commandQueue.device.makeTexture(descriptor: cropTextureDescriptor) else {
                throw Error.couldNotCreateMetalTexture
            }

            guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                throw Error.couldNotMakeCommandBuffer
            }

            let origin = MTLOrigin(x: Int(cropRect.origin.x), y: Int(cropRect.origin.y), z: 0)
            let size = MTLSize(width: Int(cropRect.width), height: Int(cropRect.height), depth: 1)
            blitEncoder.copy(from: sourceTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size, to: croppedTexture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))

            blitEncoder.endEncoding()
            finalSourceTexture = croppedTexture
        }

        spatialScaler.colorTexture = finalSourceTexture
        spatialScaler.outputTexture = intermediateOutputTexture
        spatialScaler.encode(commandBuffer: commandBuffer)

        if let pipelineState = sharpenPipelineState, let sharpnessDouble = sharpen {
            guard let computeCommandEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw Error.couldNotMakeCommandBuffer
            }
            computeCommandEncoder.setComputePipelineState(pipelineState)
            computeCommandEncoder.setTexture(intermediateOutputTexture, index: 0)
            computeCommandEncoder.setTexture(upscaledTexture, index: 1)
            
            // Convert Double to Float and pass a pointer to a stable variable
            var sharpnessFloat = Float(sharpnessDouble)
            computeCommandEncoder.setBytes(&sharpnessFloat, length: MemoryLayout<Float>.size, index: 0)

            let threadgroupSize = MTLSize(width: 16, height: 16, depth: 1)
            let threadgroupCount = MTLSize(
                width: (intermediateOutputTexture.width + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (intermediateOutputTexture.height + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            computeCommandEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            computeCommandEncoder.endEncoding()
        } else {
            let blitCommandEncoder = commandBuffer.makeBlitCommandEncoder()
            blitCommandEncoder?.copy(from: intermediateOutputTexture, to: upscaledTexture)
            blitCommandEncoder?.endEncoding()
        }

        return (commandBuffer, outputPixelBuffer)
    }
}

// MARK: Upscaler.Error

extension Upscaler {
    enum Error: Swift.Error, LocalizedError {
        case unsupportedPixelFormat
        case couldNotCreatePixelBuffer
        case couldNotCreateMetalTexture
        case couldNotMakeCommandBuffer
        case metalLibraryNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedPixelFormat:
                return NSLocalizedString(
                    "Unsupported pixel format",
                    comment: "Upscaler error description for unsupported pixel format."
                )
            case .couldNotCreatePixelBuffer:
                return NSLocalizedString(
                    "Could not create pixel buffer",
                    comment: "Upscaler error description for could not create pixel buffer."
                )
            case .couldNotCreateMetalTexture:
                return NSLocalizedString(
                    "Could not create Metal texture",
                    comment: "Upscaler error description for could not create Metal texture."
                )
            case .couldNotMakeCommandBuffer:
                return NSLocalizedString(
                    "Could not make command buffer",
                    comment: "Upscaler error description for could not make command buffer."
                )
            case .metalLibraryNotFound(let message):
                return NSLocalizedString(
                    "Could not find Metal library: \(message)",
                    comment: "Upscaler error description for could not find Metal library."
                )
            }
        }
    }
}

// Silence Swift 6 Sendable checks for controlled use across tasks.
extension Upscaler: @unchecked Sendable {}
