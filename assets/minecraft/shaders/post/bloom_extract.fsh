#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;

// Threshold is the luminance where bloom starts. Knee is how gradually it ramps
// in either side of that, so a pixel drifting over the line fades in instead of
// popping. main is RGBA8, so nothing is brighter than 1.0 here and a threshold
// below about 0.9 is needed for anything to bloom at all.
layout(std140) uniform BloomExtractConfig {
    float Threshold;
    float Knee;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec3 color = texture(SceneTexSampler, texCoord).rgb;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));

    // Soft knee: quadratic across the knee, linear above it.
    float knee = max(Knee, 1e-4);
    float soft = clamp(luma - Threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee);
    float contribution = max(soft, luma - Threshold) / max(luma, 1e-4);

    fragColor = vec4(color * clamp(contribution, 0.0, 1.0), 1.0);
}
