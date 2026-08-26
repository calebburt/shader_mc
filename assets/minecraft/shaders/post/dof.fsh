#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;
uniform sampler2D BlurTexSampler;
uniform sampler2D DepthTexSampler;

// AutoFocus: 1 focuses on whatever is under the crosshair, 0 focuses at exactly
//   FocusDistance instead.
// FocusDistance: the focal plane in blocks, when focusing by hand.
// Aperture: how shallow the focus is, in blocks. Larger throws everything off
//   the focal plane out of focus sooner. This is the "how much" knob; it does
//   not move the plane.
// HandCutoff: depth above this is the held item, which sits far nearer than any
//   block and stays sharp instead of smearing.
// MaxBlur: ceiling on how much of the blurred image is ever mixed in.
layout(std140) uniform DofConfig {
    float AutoFocus;
    float FocusDistance;
    float Aperture;
    float HandCutoff;
    float MaxBlur;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const float NEAR_PLANE = 0.05; // the game's near plane, in blocks
const float FOCUS_SPREAD = 8.0; // auto-focus sampling radius, in pixels

// Reciprocal distance in 1/blocks. Reversed-Z depth is near / distance, so this
// is just depth / near -- and reciprocal distance is exactly what a thin lens'
// circle of confusion is built from, so nothing further has to be linearised.
// Sky, at depth 0, lands on 0, which is infinitely far away. Correct.
float invDistance(float depth) {
    return depth / NEAR_PLANE;
}

// Nearest surface in a small cross at the crosshair. Taking the nearest rather
// than the exact centre pixel keeps focus on the thing being looked at instead
// of letting a gap between leaves throw it out to infinity.
float focusFromCrosshair() {
    vec2 step = FOCUS_SPREAD / vec2(textureSize(DepthTexSampler, 0));
    float depth = texture(DepthTexSampler, vec2(0.5)).r;
    depth = max(depth, texture(DepthTexSampler, vec2(0.5) + vec2(step.x, 0.0)).r);
    depth = max(depth, texture(DepthTexSampler, vec2(0.5) - vec2(step.x, 0.0)).r);
    depth = max(depth, texture(DepthTexSampler, vec2(0.5) + vec2(0.0, step.y)).r);
    depth = max(depth, texture(DepthTexSampler, vec2(0.5) - vec2(0.0, step.y)).r);
    return invDistance(depth);
}

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    float depth = texture(DepthTexSampler, texCoord).r;

    float focus = AutoFocus >= 0.5
        ? focusFromCrosshair()
        : 1.0 / max(FocusDistance, NEAR_PLANE);

    // Thin-lens circle of confusion: blur grows with the gap between this
    // pixel's reciprocal distance and the focal plane's, so the sharp band sits
    // at the focal plane and falls off either side of it.
    float coc = clamp(abs(invDistance(depth) - focus) * max(Aperture, 0.0), 0.0, 1.0)
              * clamp(MaxBlur, 0.0, 1.0);

    if (depth >= HandCutoff) {
        coc = 0.0; // the held item, not part of the scene
    }

    // Alpha passes through: it carries terrain.fsh's opaque tag.
    fragColor = vec4(mix(scene.rgb, texture(BlurTexSampler, texCoord).rgb, coc),
                     scene.a);
}
