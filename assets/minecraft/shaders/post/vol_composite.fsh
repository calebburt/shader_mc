#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:vv_hdr.glsl>

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
    // The shafts arrive high-range encoded and the fog does not; decode only what
    // the ray pass scaled.
    vec3 shafts = vv_hdr_decode(texture(ShaftTexSampler, texCoord).rgb);
    vec4 fog = texture(FogTexSampler, texCoord);

    // Additive light, and alpha passes through: it carries terrain.fsh's opaque
    // tag, which the ssr chain reads however these chains end up ordered.
    fragColor = vec4(scene.rgb + shafts * max(ShaftIntensity, 0.0), scene.a);
    fragColor = mix(fragColor, vec4(vec3(fog), 1.0), fog.a * FogIntensity);

    // The light just added is free to exceed 1.0. Store it high-range so the
    // bloom threshold and the final tone map still see the excess.
    fragColor.rgb = vv_hdr_encode(fragColor.rgb);
}
