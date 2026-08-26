#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;
uniform sampler2D BloomTexSampler;

layout(std140) uniform BloomConfig {
    float Intensity;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    vec3 bloom = texture(BloomTexSampler, texCoord).rgb;

    // Additive, and main's alpha passes through untouched: terrain.fsh tags
    // opaque surfaces in that channel and the ssr chain reads it, so any chain
    // that might run first has to leave it alone.
    fragColor = vec4(scene.rgb + bloom * max(Intensity, 0.0), scene.a);
}
