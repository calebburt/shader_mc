#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_hdr.glsl>

uniform sampler2D SceneTexSampler;

// Threshold is the luminance where bloom starts, in linear light. Knee is how
// gradually it ramps in either side of that, so a pixel drifting over the line
// fades in instead of popping. The scene is high-range encoded, so Threshold can
// sit above 1.0 and pick out only true highlights if that is wanted.
layout(std140) uniform BloomExtractConfig {
    float Threshold;
    float Knee;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    // The scene arrives high-range encoded, so decode before thresholding: the
    // threshold is in linear light, not in the 1/scale storage units.
    vec3 color = vv_hdr_decode(texture(SceneTexSampler, texCoord).rgb);
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));

    // Soft knee: quadratic across the knee, linear above it.
    float knee = max(Knee, 1e-4);
    float soft = clamp(luma - Threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contribution = max(soft, luma - Threshold) / max(luma, 1e-4);

    // Re-encoded so the pyramid blurs can carry a highlight above 1.0 without
    // clipping it at the first downsample.
    fragColor = vec4(vv_hdr_encode(color * clamp(contribution, 0.0, 1.0)), 1.0);
}
