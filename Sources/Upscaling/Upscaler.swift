@preconcurrency import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import MetalFX


// MARK: - Upscaler

public final class Upscaler {
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
        self.sharpenBounds = CGRect(origin: .zero, size: outputSize)
        if let sharpen {    
             ciContext = CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!,
                .useSoftwareRenderer: false,
                .workingFormat: CIFormat.BGRA8, // BGRA8 matches the texture format and is much faster than RGBAh
                .cacheIntermediates: false
            ])
            sharpenFilter = CIFilter(name: "CISharpenLuminance")
            sharpenFilter?.setValue(sharpen, forKey: kCIInputSharpnessKey)
        
        }  else {
            ciContext = nil
            sharpenFilter = nil
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
    private let ciContext: CIContext?
    private let sharpenFilter: CIFilter?
    private let sharpenBounds: CGRect
    private let linearSRGB = CGColorSpace(name: CGColorSpace.linearSRGB)!

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

        if let ciContext, let sharpenFilter {
            let imageToFilter = CIImage(mtlTexture: intermediateOutputTexture, options: [ .colorSpace: linearSRGB ])!
            sharpenFilter.setValue(imageToFilter, forKey: kCIInputImageKey)
            if let sharpenedImage = sharpenFilter.outputImage {
                ciContext.render(sharpenedImage, to: upscaledTexture, commandBuffer: commandBuffer, 
                            bounds: sharpenBounds, colorSpace: linearSRGB)
            }
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
            }
        }
    }
}

// Silence Swift 6 Sendable checks for controlled use across tasks.
extension Upscaler: @unchecked Sendable {}