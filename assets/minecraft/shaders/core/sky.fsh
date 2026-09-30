#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:dynamictransforms.glsl>
#include <minecraft:projection.glsl>
#include <minecraft:vv_lighting.glsl>

layout(location = 0) in float sphericalVertexDistance;
layout(location = 1) in float cylindricalVertexDistance;

layout(location = 0) out vec4 fragColor;

// The sky is a screen-space quad with no world position behind it, so the view
// ray is rebuilt from the window position: divide NDC by the projection's own
// scale to get a view-space ray, then carry it into world space with the inverse
// of the view rotation. The sky is only ever translated, never scaled, so the 3x3
// of the modelview is pure rotation and transposing it inverts it.
vec3 worldViewRay() {
    vec2 ndc = gl_FragCoord.xy / vec2(ScreenSize) * 2.0 - 1.0;
    vec3 ray = vec3(ndc.x / ProjMat[0][0], ndc.y / ProjMat[1][1], -1.0);
    return normalize(transpose(mat3(ModelViewMat)) * ray);
}

void main() {
    vec3 ray = worldViewRay();
    vec3 sun = vv_sun_direction();
    vec3 moon = vv_moon_direction();

    float elevation = ray.y;
    float height = vv_sun_height();

    // ColorModulator is the sky colour the game already resolved for this biome,
    // dimension and time, so it stays the base and everything here is layered on
    // top of it rather than replacing it.
    vec3 sky = ColorModulator.rgb;

    // Vertical gradient. The flat fill the game hands over has no falloff at all,
    // which is what makes default skies look like a backdrop; deepening towards
    // the zenith and lifting towards the horizon is most of the improvement.
    float up = clamp(elevation, 0.0, 1.0);
    vec3 zenithTint = vec3(0.62, 0.78, 1.00);
    vec3 horizonTint = vec3(1.00, 0.96, 0.90);
    float day = smoothstep(-0.20, 0.35, height);
    vec3 gradient = mix(horizonTint, zenithTint, pow(up, 0.55));
    sky = mix(sky, sky * gradient, day * 0.55 * smoothstep(-0.05, 0.25, elevation));

    // Mie-ish forward scattering: the whole sky brightens and warms as the sun
    // gets near it, and the effect spreads with the angle between them.
    float sunAngle = max(dot(ray, sun), 0.0);
    float lowSun = 1.0 - smoothstep(-0.05, 0.45, height);
    vec3 scatter = vec3(1.00, 0.55, 0.24);
    sky += scatter * pow(sunAngle, 6.0) * lowSun * 0.85;
    sky += scatter * pow(sunAngle, 1.5) * lowSun * 0.16;

    // The sun itself. The game's own sun quad is drawn over this, so the disk is
    // left to it; what is added here is the glow around it, which is what the
    // bloom pass then picks up.
    sky += vec3(1.0, 0.86, 0.66) * pow(sunAngle, 220.0) * 0.9 * smoothstep(-0.12, 0.05, height);
    sky += vec3(1.0, 0.80, 0.58) * pow(sunAngle, 24.0) * 0.28 * smoothstep(-0.10, 0.10, height);

    // The moon gets a cool halo instead.
    float moonAngle = max(dot(ray, moon), 0.0);
    float night = 1.0 - smoothstep(-0.25, 0.02, height);
    sky += vec3(0.55, 0.62, 0.90) * pow(moonAngle, 90.0) * 0.35 * night;

    // Haze pooling along the horizon, thickening downward and picking up the
    // biome's own fog colour so terrain and sky meet in the same tone.
    float haze = pow(1.0 - clamp(elevation, 0.0, 1.0), 6.0);
    vec3 hazeColor = mix(FogColor.rgb, vec3(0.72, 0.80, 0.92), 0.45);
    sky = mix(sky, hazeColor, haze * 0.75);

    fragColor = apply_fog(vec4(sky, 1.0), sphericalVertexDistance, cylindricalVertexDistance, 0.0, FogSkyEnd, FogSkyEnd, FogSkyEnd, FogColor);
}
