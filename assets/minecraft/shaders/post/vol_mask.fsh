#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;
uniform sampler2D DepthTexSampler;

// SkyThreshold: luminance a sky pixel must beat to count as the light source.
// It wants to be high enough that only the sun or moon passes and the open sky
// does not, or the light ends up averaged into the middle of the sky.
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
    float bright = max(luma - SkyThreshold, 0.0) / max(1.0 - SkyThreshold, 1e-4);

    // Colour premultiplied, so the shafts pick up the light's own tint, and the
    // plain amount in alpha for the position search to weigh with.
    fragColor = vec4(color * bright, bright);
}
