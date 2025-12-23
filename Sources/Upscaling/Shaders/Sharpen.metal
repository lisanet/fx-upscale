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
