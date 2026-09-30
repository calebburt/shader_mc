#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_sun.glsl>

uniform sampler2D MaskTexSampler; // the light mask, unblurred
uniform sampler2D SunTexSampler;  // 1x1: light position in rg, strength in b

// Density: how far along the line toward the light each pixel marches, as a
// fraction of the distance to it. Decay: per-step falloff, so shafts fade with
// distance from the light. Exposure: overall gain on the result.
layout(std140) uniform VolRaysConfig {
    float Density;
    float Decay;
    float Exposure;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int SAMPLES = 32;

void main() {
    vec4 sun = texture(SunTexSampler, vec2(0.0));
    if (sun.b <= 0.0) {
        fragColor = vec4(0.0); // no light in view, so no shafts
        return;
    }

    // Step from this pixel toward the light, gathering the mask as it goes. Where
    // geometry masks the light the gathered total drops, and the gaps between
    // become the shafts.
    vec2 toSun = sun.rg - texCoord;
    vec2 delta = toSun * (clamp(Density, 0.0, 1.0) / float(SAMPLES));

    vec2 uv = texCoord;
    vec3 gathered = vec3(0.0);
    float weight = 0.0;
    float illumination = 1.0;

    for (int i = 0; i < SAMPLES; ++i) {
        uv += delta;
        // The mask sampler clamps to edge, so a step past the screen would smear
        // the border pixel down the whole ray. Fading toward nothing instead
        // keeps a sun that is half off screen from painting a stripe.
        vec2 edge = smoothstep(vec2(0.0), vec2(0.06), uv)
                  * (1.0 - smoothstep(vec2(0.94), vec2(1.0), uv));
        vec4 tap = texture(MaskTexSampler, clamp(uv, vec2(0.0), vec2(1.0)));
        float w = illumination * edge.x * edge.y;
        gathered += tap.rgb * w;
        weight += w;
        illumination *= clamp(Decay, 0.0, 1.0);
    }

    // Normalising by the accumulated weight rather than the sample count keeps
    // the brightness stable as Decay changes the effective number of steps.
    vec3 shafts = weight > 1e-5 ? gathered / weight : vec3(0.0);

    // Tint by the light's own colour so a dawn shaft is warm and a moonlit one is
    // cold, independent of what happened to be bright in the mask.
    vec3 tint = mix(vec3(1.0), vv_key_chroma(), 0.6);

    fragColor = vec4(shafts * tint * (clamp(Exposure, 0.0, 8.0) * sun.b), 1.0);
}