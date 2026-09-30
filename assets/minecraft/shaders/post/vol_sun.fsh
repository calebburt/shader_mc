#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_sun.glsl>

uniform sampler2D MaskTexSampler;    // the light mask, blurred
uniform sampler2D RawMaskTexSampler; // the light mask, unblurred

// SunGain scales how much found light counts as full strength, which sets how
// quickly the shafts fade up as the sun comes into view.
layout(std140) uniform VolSunConfig {
    float SunGain;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

// A post pass is given the screen quad's orthographic projection, never the
// camera's, so the sun's world direction cannot be projected to a screen
// position here. This pass finds the light on screen instead: it is where the
// mask is strongest. The real direction still matters, and does two jobs. It
// decides whether a light source should be expected at all (vv_sun.glsl), which
// is what stops a torch from seeding shafts at noon, and it scales the result by
// how high the real sun is, which is what stops a shaft from hanging in the
// frame long after the sun has set.
//
// Renders to a 1x1 target, so the whole grid is walked for a single fragment.
const int GRID = 40;

void main() {
    // The peak, not the centroid, is what decides the strength. The centroid
    // measures how much lit sky there is, which changes with the view; the peak
    // measures how bright the light itself is, which does not. Read from the
    // unblurred mask, because the blur that steadies the position below also
    // averages the disc down and would understate the light.
    float peak = 0.0;

    for (int y = 0; y < GRID; ++y) {
        for (int x = 0; x < GRID; ++x) {
            vec2 uv = (vec2(x, y) + 0.5) / float(GRID);
            peak = max(peak, texture(RawMaskTexSampler, uv).a);
        }
    }

    // Second walk: the centroid, but weighted by the square of the score. Plain
    // weighting averages in every lit pixel on screen, so a bright torch beside
    // the sun drags the shafts off towards the torch, and a partly occluded sun
    // gets smeared across the sky. Squaring concentrates the average on the
    // samples that are actually the light, which is where the disc is.
    vec2 weighted = vec2(0.0);
    float total = 0.0;

    for (int y = 0; y < GRID; ++y) {
        for (int x = 0; x < GRID; ++x) {
            vec2 uv = (vec2(x, y) + 0.5) / float(GRID);
            float score = texture(MaskTexSampler, uv).a;
            float weight = score * score;
            weighted += uv * weight;
            total += weight;
        }
    }

    vec2 center = total > 1e-6 ? weighted / total : vec2(0.5);

    // abs() so the moon counts once it is the light that is up, and smoothstep
    // so nothing is drawn while the light is on the horizon or below it.
    float elevation = smoothstep(0.02, 0.30, abs(vv_sun_height()));
    float strength = clamp(peak * elevation * max(SunGain, 0.0), 0.0, 1.0);

    // rg: where the light is on screen. b: how strong it is, so the rays pass can
    // fade out as the sun sets, goes behind a hill, or leaves the screen.
    fragColor = vec4(center, strength, 1.0);
}