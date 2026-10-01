#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_hdr.glsl>

uniform sampler2D SceneTexSampler;
uniform sampler2D BloomTexSampler;

layout(std140) uniform BloomConfig {
    float Intensity;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    // Both the scene and the bloom pyramid are high-range encoded; decode, add,
    // and re-encode so the halo can rise past 1.0.
    vec3 bloom = vv_hdr_decode(texture(BloomTexSampler, texCoord).rgb);
    vec3 color = vv_hdr_decode(scene.rgb) + bloom * max(Intensity, 0.0);

    // Additive, and main's alpha passes through untouched: terrain.fsh tags
    // opaque surfaces in that channel and the ssr chain reads it, so any chain
    // that might run first has to leave it alone.
    fragColor = vec4(vv_hdr_encode(color), scene.a);
}
