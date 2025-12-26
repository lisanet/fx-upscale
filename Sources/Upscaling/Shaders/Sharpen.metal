#include <metal_stdlib>
using namespace metal;

struct SharpenParams {
    float sharpness;
    uint  useBT709;   // 0 = BT.601, 1 = BT.709
};

float rgb_to_luma(float3 rgb, bool useBT709) {
    return useBT709
        ? dot(rgb, float3(0.2126, 0.7152, 0.0722))   
        : dot(rgb, float3(0.2990, 0.5870, 0.1140));  // BT.601
}


kernel void sharpenLuma(texture2d<float, access::read> inTexture [[texture(0)]],
                        texture2d<float, access::write> outTexture [[texture(1)]],
                        constant SharpenParams& params [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    // Ensure we don't read/write outside of the texture bounds
    uint2 size = uint2(inTexture.get_width(), inTexture.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;

    // Unsharp Mask Kernel (3x3)
    const float blurWeights[9] = {
        1, 2, 1,
        2, 4, 2,
        1, 2, 1
    };
    const float blurDiv = 16.0;

    float4 center = inTexture.read(gid);
    // Create a blurred version 
    float blurredLuma = 0.0;
    for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
            int2 coord = clamp(int2(gid) + int2(dx, dy), int2(0,0), int2(size) - 1);
            float3 sample = inTexture.read(uint2(coord)).rgb;
            float sampleLuma = rgb_to_luma(sample, params.useBT709 != 0);
            int idx = (dy + 1) * 3 + (dx + 1);
            blurredLuma += sampleLuma * blurWeights[idx];
        }
    }
    blurredLuma /= blurDiv;

    // Luma berechnen
    float centerLuma = rgb_to_luma(center.rgb, params.useBT709);
    float mask = (centerLuma - blurredLuma);
    // thresholding
    if (abs(mask) < 0.01) {
        outTexture.write(center, gid);
    } else {
        float3 resultRgb = center.rgb + mask * params.sharpness;
        resultRgb = clamp(resultRgb, 0.0, 1.0);
        outTexture.write(float4(resultRgb, center.a), gid);

    }
}
