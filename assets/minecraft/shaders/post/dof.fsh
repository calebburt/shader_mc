#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;
uniform sampler2D BlurTexSampler;
uniform sampler2D DepthTexSampler;

// FocusScale: how fast things leave focus either side of the focal plane.
// HandCutoff: depth above this is the held item, which is far nearer than any
// block and stays sharp instead of smearing across the bottom of the screen.
// MaxBlur: ceiling on how much of the blurred image is ever mixed in.
layout(std140) uniform DofConfig {
    float FocusScale;
    float HandCutoff;
    float MaxBlur;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    float depth = texture(DepthTexSampler, texCoord).r;

    // Reversed-Z depth is proportional to 1 / distance, which is exactly the
    // reciprocal-distance term a circle of confusion is built from -- so the
    // difference of two depths is usable directly, with no linearising.
    // Focus on whatever sits under the crosshair.
    float focus = texture(DepthTexSampler, vec2(0.5)).r;
    float coc = clamp(abs(depth - focus) * FocusScale, 0.0, 1.0)
              * clamp(MaxBlur, 0.0, 1.0);
    if (depth >= HandCutoff) {
        coc = 0.0;
    }

    // Alpha passes through for the same reason as in bloom_composite.
    fragColor = vec4(mix(scene.rgb, texture(BlurTexSampler, texCoord).rgb, coc),
                     scene.a);
}
