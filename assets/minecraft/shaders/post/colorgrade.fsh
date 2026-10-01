#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_hdr.glsl>

uniform sampler2D SceneTexSampler;

// Exposure: stops of light, applied before anything else so the tone curve has
//   something to work with.
// WhitePoint: the level the highlight rolloff aims for. Everything under the knee
//   is left alone, so this only ever softens what is already near clipping.
// Contrast: an S-curve pivoted on mid grey. Below 1 flattens, above 1 deepens.
// Saturation: distance from luminance, around 0 to keep the original.
// Temperature / Tint: a white balance, warm positive and cool negative, in the
//   usual photographer's convention.
// ShadowTint / HighlightTint: a split-tone grade. Shadow colour is added and
//   Highlight colour is screened, weighted by how dark or bright a pixel already
//   is, which is the cheapest way to get the cool-shadow warm-highlight look.
layout(std140) uniform ColorGradeConfig {
    float Exposure;
    float WhitePoint;
    float Contrast;
    float Saturation;
    float Temperature;
    float Tint;
    vec3 ShadowTint;
    vec3 HighlightTint;
    float GradeStrength;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const float PI = 3.14159265358979;

// Rec. 709 luminance, the weighting the eye actually uses.
float luma(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// A shoulder that only touches the top of the range: linear below the knee, then
// a smooth exponential approach to the white point. This is the only tone map in
// the chain, and it is why the scene is carried high-range up to here: a sky or a
// shaft that the world render would have clipped now rolls off instead of ending
// on a flat edge.
float shoulder(float x, float white) {
    float knee = white * 0.75;
    if (x <= knee) {
        return x;
    }
    return knee + (white - knee) * (1.0 - exp(-(x - knee) / max(white - knee, 1e-4)));
}

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    // The final pass is the one place the high-range encoding is undone; from
    // here the image is display referred and clamped.
    vec3 color = vv_hdr_decode(scene.rgb) * exp2(Exposure);

    // White balance. A real sensor gain moves the three channels by different
    // amounts; a simple scale towards a warm or cool axis lands in the same place
    // and is far cheaper.
    color *= vec3(1.0 + Temperature * 0.22 + Tint * 0.10,
                  1.0 + Tint * -0.05,
                  1.0 - Temperature * 0.22 + Tint * 0.10);

    color = vec3(shoulder(color.r, WhitePoint),
                 shoulder(color.g, WhitePoint),
                 shoulder(color.b, WhitePoint));

    // Contrast pivoted on mid grey rather than on zero, so brightening the
    // exposure does not also wash the image out.
    color = clamp((color - 0.5) * Contrast + 0.5, 0.0, 1.0);

    color = clamp(mix(vec3(luma(color)), color, Saturation), 0.0, 1.0);

    // Split tone, weighted by the opposite end of the range: dark pixels lean on
    // the shadow colour, bright ones on the highlight colour.
    vec3 shadowWeight = vec3(pow(1.0 - luma(color), 2.0));
    vec3 highlightWeight = vec3(pow(luma(color), 2.0));
    vec3 graded = color
                + ShadowTint * shadowWeight * (1.0 - color)
                + HighlightTint * highlightWeight * color;

    color = mix(color, clamp(graded, 0.0, 1.0), GradeStrength);

    // Alpha is main's opaque tag, read by the SSR pass, so it passes straight
    // through untouched.
    fragColor = vec4(clamp(color, 0.0, 1.0), scene.a);
}
