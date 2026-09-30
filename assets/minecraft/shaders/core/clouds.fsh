#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:oit.glsl>
#include <minecraft:vv_lighting.glsl>

layout(location = 0) in float vertexDistance;
layout(location = 1) in vec4 vertexColor;
layout(location = 2) in vec3 faceNormal;

#ifndef OIT_ALPHA_ONLY
layout(location = 0) out vec4 fragColor;
#endif

vec4 calculateFinalColor(vec4 color) {
    #ifdef OIT_ACCUMULATE
    color = sampleColorForAccumulation(color);
    #endif
    return color;
}

void main() {
    vec4 color = vertexColor;

    vec3 sun = vv_sun_direction();
    vec3 n = normalize(faceNormal);

    // The colour the game hands over is a flat tint per face. Split it back into a
    // brightness to shape and a hue to keep, so the shading below only changes how
    // bright a cloud is and never what colour it is.
    float peak = max(max(color.r, color.g), color.b);
    vec3 tint = color.rgb / max(peak, 1e-3);
    float base = clamp(peak, 0.0, 1.0);

    // Tops catch the sun, undersides stay in shadow, sides sit in between. This
    // is what gives a flat sheet of blocks any sense of volume.
    float nDotL = dot(n, sun) * 0.5 + 0.5;
    float light = mix(0.62, 1.18, nDotL);
    light *= mix(0.35, 1.0, smoothstep(-0.15, 0.30, vv_sun_height()));

    // Silver lining: cloud edges thin out enough to be lit from behind, and
    // forward scattering is what makes a cloud look backlit rather than flat.
    float back = max(-dot(n, sun), 0.0);
    vec3 scatter = vec3(1.00, 0.80, 0.62) * back * 0.35 * smoothstep(-0.05, 0.30, vv_sun_height());

    color.rgb = tint * base * light + scatter;

    #ifndef OIT_DEPTH_BOUNDS
    color.a *= 1.0f - linear_fog_value(vertexDistance, 0, FogCloudsEnd);
    #endif

    #ifdef OIT_ALPHA_ONLY
    executeAlphaOnlyPhase(gl_FragCoord.z, color.a);
    #else
    fragColor = calculateFinalColor(color);
    #endif
}
