#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:vv_sun.glsl>

uniform sampler2D SceneTexSampler;
uniform sampler2D DepthTexSampler;

layout(location = 0) in vec2 texCoord;
layout(location = 0) out vec4 fragColor;

// How much the distance haze picks up the sky's colour, and how much it keeps
// the world's own fog colour. Pushing this towards the sky is what makes fog
// read as air rather than as a grey sheet.
const float SKY_MIX = 0.55;

// Reversed-Z, same model as the SSR pass: main stores 1/w.
float linearZ(float depth) {
    return 1.0 / max(depth, 1e-7);
}

void main() {
    vec3 sceneColor = texture(SceneTexSampler, texCoord).rgb;

    float viewDist = linearZ(texture(DepthTexSampler, texCoord).r);

    // Reversed-Z puts open sky at depth 0, which inverts to an enormous distance.
    // Left alone it would fog the sky to a flat sheet, so it is excluded and the
    // sky keeps whatever the sky shader drew.
    if (texture(DepthTexSampler, texCoord).r <= 1e-4) {
        fragColor = vec4(sceneColor, 1.0);
        return;
    }

    // Distance haze lifted from the world's own fog, so the volumetric fog lands
    // at the same distance and colour the rest of the scene already fades to.
    // Post passes are never handed the camera's view vector, only linear depth,
    // so z stands in for both the spherical and cylindrical distances the core
    // shaders use; they only diverge when the camera is pitched, and behind fog
    // that is not visible.
    float envStart = FogEnvironmentalStart;
    float envEnd = FogEnvironmentalEnd;
    float renderStart = FogRenderDistanceStart;
    float renderEnd = FogRenderDistanceEnd;
    vec4 baseFog = FogColor;

    // If the Fog block was not bound for this pass every field reads as zero,
    // which would fog the entire frame to black. Detect that and fall back to
    // the froxel-free defaults rather than trusting it.
    if (envEnd <= envStart || renderEnd <= renderStart || baseFog.a <= 0.0) {
        envStart = 40.0;
        envEnd = 1800.0;
        renderStart = 40.0;
        renderEnd = 1800.0;
        baseFog = vec4(0.70, 0.75, 0.80, 1.0);
    }

    float fogValue = max(
        linear_fog_value(viewDist, envStart, envEnd),
        linear_fog_value(viewDist, renderStart, renderEnd));

    // The air takes its colour from whatever light is actually up: warm at dawn,
    // near white at noon, cold blue at night, rather than one fixed grey.
    vec3 skyLight = vv_key_radiance_color();
    float skyLuma = dot(skyLight, vec3(0.2126, 0.7152, 0.0722));
    vec3 keyTint = skyLight / max(skyLuma, 1e-3);

    vec3 fogColor = mix(baseFog.rgb, baseFog.rgb * keyTint, SKY_MIX);

    // Higher at dawn and dusk, where the light is low and the air scatters most.
    float lowSun = 1.0 - smoothstep(0.0, 0.45, abs(vv_sun_height()));
    fogColor = mix(fogColor, fogColor * vec3(1.10, 0.94, 0.84), lowSun * 0.5);

    vec3 finalColor = mix(sceneColor, fogColor, clamp(fogValue, 0.0, 1.0));

    fragColor = vec4(finalColor, 1.0);
}