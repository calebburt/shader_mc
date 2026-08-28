#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;
uniform sampler2D ShaftTexSampler;
uniform sampler2D FogTexSampler;

layout(std140) uniform VolConfig {
    float ShaftIntensity;
    float FogIntensity;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    vec3 shafts = texture(ShaftTexSampler, texCoord).rgb;
    vec3 fog = texture(FogTexSampler, texCoord).rgb;

    // Additive light, and alpha passes through: it carries terrain.fsh's opaque
    // tag, which the ssr chain reads however these chains end up ordered.
    fragColor = vec4(scene.rgb + shafts * max(ShaftIntensity, 0.0) + fog * max(FogIntensity, 0.0), scene.a);
}
