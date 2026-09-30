#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:globals.glsl>
#include <minecraft:texture_sampling.glsl>
#include <minecraft:oit.glsl>
#include <minecraft:terrainglobals.glsl>
#include <minecraft:vv_lighting.glsl>
#ifndef MULTIDRAW_TERRAIN
    #include <minecraft:chunksection.glsl>
#endif

uniform sampler2D Sampler0;

layout(location = 0) in float sphericalVertexDistance;
layout(location = 1) in float cylindricalVertexDistance;
layout(location = 2) in vec4 vertexColor;
layout(location = 3) in vec2 texCoord0;
layout(location = 4) in float chunkVisibility;
layout(location = 5) in vec3 cameraRelativePos;

#ifndef OIT_ALPHA_ONLY
layout(location = 0) out vec4 fragColor;
#endif

// Albedo is the tinted block colour: the texture sample times the vertex colour,
// which the vertex shader has already folded the sampled lightmap into. The
// surviving variation in that product is the biome tint, and splitting it back
// out is what lets the surface be lit by a colour rather than by a scalar.
vec4 sampleAlbedo() {
    vec2 pixelSize = 1.0f / TextureSize;
    vec4 texel = UseRgss == 1
        ? sampleRGSS(Sampler0, texCoord0, pixelSize)
        : sampleNearest(Sampler0, texCoord0, pixelSize);
    return texel * vertexColor;
}

// The terrain vertex format has no normal attribute, so the flat geometric
// normal comes from the screen-space derivatives of the camera-relative world
// position, flipped back to face the camera (which is the origin of that space).
vec3 geometricNormal(vec3 cameraRelative) {
    vec3 n = normalize(cross(dFdx(cameraRelative), dFdy(cameraRelative)));
    return dot(n, cameraRelative) > 0.0 ? -n : n;
}

vec3 doFog(vec3 color) {
    // apply_fog works in vec4, so wrap and unwrap around it.
    vec3 fogged = apply_fog(vec4(color, 1.0), sphericalVertexDistance, cylindricalVertexDistance,
                            FogEnvironmentalStart, FogEnvironmentalEnd,
                            FogRenderDistanceStart, FogRenderDistanceEnd, FogColor).rgb;
    return mix(fogged, color, chunkVisibility);
}

void main() {
    vec4 texColor = sampleAlbedo();

    // Derivatives have to be taken before any discard, or neighbouring fragments
    // in the same quad end up disagreeing about them and the normals break along
    // every cutout edge.
    vec3 flatNormal = geometricNormal(cameraRelativePos);
    float height = dot(texColor.rgb, vec3(0.299, 0.587, 0.114));
    vec3 bumped = vv_bump_from_albedo(flatNormal, cameraRelativePos, height, 0.55);

    #ifdef ALPHA_CUTOUT
    if (texColor.a < ALPHA_CUTOUT) {
        discard;
    }
    #endif

    #ifdef OIT_ALPHA_ONLY
    executeAlphaOnlyPhase(gl_FragCoord.z, texColor.a);
    #else
    vec3 albedo = clamp(texColor.rgb, 0.0, 1.0);
    vec3 n = normalize(bumped);
    vec3 v = normalize(-cameraRelativePos);

    // The lightmap is baked into vertexColor, so recover the light level and the
    // tint separately: level decides how much light arrives, tint decides its
    // colour. Anything that came from the texture rather than the tint shows up
    // as a departure from flat, which is a decent stand-in for a gloss map.
    float level = vv_light_level(vertexColor.rgb);
    vec3 tint = texColor.rgb / max(vertexColor.rgb, vec3(1e-4));
    tint = clamp(mix(vec3(1.0), tint, 0.35), 0.0, 1.0);

    // Roughness: brighter and flatter texture reads as a smoother, denser
    // surface. Terrain spans the whole range, so this stays on the rough side
    // except for the pale blocks that pick up a sheen.
    float rough = clamp(1.05 - 0.55 * dot(albedo, vec3(0.3333)), 0.18, 0.95);

    vec3 sun = vv_sun_direction();
    vec3 moon = vv_moon_direction();

    vec3 direct = vv_brdf(n, v, sun, albedo, rough, 0.0, vv_sun_radiance()) * tint;
    direct += vv_brdf(n, v, moon, albedo, rough, 0.0, vv_moon_radiance()) * tint;

    vec3 ambient = albedo * vv_sky_ambient(n) * level;

    // Facing the light: a cool sky reflection along the silhouette, which is the
    // Fresnel rim that makes edges read against a bright sky.
    float rim = pow(1.0 - max(dot(n, v), 0.0), 4.0);
    vec3 rimColor = mix(vec3(0.05, 0.07, 0.11), vec3(0.30, 0.40, 0.55), smoothstep(-0.2, 0.4, vv_sun_height()));
    vec3 lit = (direct * level + ambient) + rim * rimColor * level * 0.35;

    doFog(lit);

    #ifdef OIT
    // Translucent terrain goes through OIT in fabulous, where alpha is coverage
    // and has to survive; oit_composite puts it into main with a high value.
    fragColor = vec4(lit, texColor.a);
    #else
    // Everything drawn in this pass is a solid surface, so main's alpha is free
    // to carry a tag instead. The post chain reads 0 as "opaque" and anything at
    // or above its mask level as translucent, which is what lets SSR sharpen its
    // reflection on glass and water while leaving stone blurred.
    fragColor = vec4(lit, 0.0);
    #endif
    #endif
}
