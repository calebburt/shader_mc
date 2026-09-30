#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_sun.glsl>

uniform sampler2D SceneTexSampler;
uniform sampler2D DepthTexSampler;

// SkyThreshold: how bright a sky pixel has to be, as a fraction of the key
// light's own radiance, before it counts as the light source. Scaling by the
// radiance rather than fixing an absolute number is what keeps the sun findable
// at dawn, when it is dim and orange, and not just at noon.
layout(std140) uniform VolMaskConfig {
    float SkyThreshold;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const float SKY_DEPTH = 1e-2;

void main() {
    // Reversed-Z: depth 0 means nothing was drawn, which is open sky. Anything
    // else is geometry, and geometry blocks the light rather than emitting it.
    if (texture(DepthTexSampler, texCoord).r > SKY_DEPTH) {
        fragColor = vec4(0.0);
        return;
    }

    vec3 color = texture(SceneTexSampler, texCoord).rgb;
    float luma = dot(color, vec3(0.2126, 0.7152, 0.0722));

    // A shaft should only ever grow out of the sun or the moon. Brightness alone
    // cannot tell them apart from a lit torch or a bright wall, so a pixel also
    // has to be roughly the key light's colour. Comparing normalised chroma, so
    // this is a hue test and not a brightness test wearing a hat.
    vec3 pixelChroma = color / max(max(color.r, max(color.g, color.b)), 1e-4);
    float hueMatch = smoothstep(0.45, 0.80, dot(pixelChroma, vv_key_chroma()) / 3.0);

    float floorLevel = clamp(SkyThreshold * vv_key_radiance(), 0.0, 0.95);
    float bright = max(luma - floorLevel, 0.0) / max(1.0 - floorLevel, 1e-4);

    float score = clamp(bright * hueMatch, 0.0, 1.0);

    // Colour premultiplied, so the shafts pick up the light's own tint, and the
    // plain amount in alpha for the position search to weigh with.
    fragColor = vec4(color * score, score);
}