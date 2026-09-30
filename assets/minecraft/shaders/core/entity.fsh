#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:dynamictransforms.glsl>
#include <minecraft:oit.glsl>
#include <minecraft:vv_lighting.glsl>

uniform sampler2D Sampler0;

#ifdef DISSOLVE
uniform sampler2D DissolveMaskSampler;
#endif

#ifdef GLINT
uniform sampler2D GlintSampler;
#endif

layout(location = 0) in float sphericalVertexDistance;
layout(location = 1) in float cylindricalVertexDistance;
#ifdef PER_FACE_LIGHTING
layout(location = 2) in vec4 vertexPerFaceColorBack;
layout(location = 3) in vec4 vertexPerFaceColorFront;
#else
layout(location = 2) in vec4 vertexColor;
#endif

#ifndef EMISSIVE
layout(location = 4) in vec4 lightMapColor;
#endif

#ifndef NO_OVERLAY
layout(location = 5) in vec4 overlayColor;
#endif

layout(location = 6) in vec2 texCoord0;
#ifdef GLINT
layout(location = 7) in vec2 texCoordGlint;
#endif

layout(location = 8) in vec3 normalView;
layout(location = 9) in vec3 cameraRelativePos;

#ifndef OIT_ALPHA_ONLY
layout(location = 0) out vec4 fragColor;
#endif

#ifndef EMISSIVE
// Entities arrive with the game's cardinal lighting already multiplied into
// vertexColor, which is why the default look rotates with the camera. The vertex
// stage now passes the tint through untouched, so all of the lighting happens
// here from the real normal, in a fixed world direction: a model stays lit the
// same way as the ground it is standing on.
//
// Emissive variants are excluded: they have no lightmap varying to read a level
// from, and they are not lit by the world to begin with.
vec3 shadeEntity(vec4 texColor, vec4 faceColor) {
    vec3 albedo = clamp(texColor.rgb * faceColor.rgb * ColorModulator.rgb, 0.0, 1.0);

    // The sampled lightmap carries the local light level and, importantly, its
    // colour, so a mob under a torch picks up the same warm cast as the wall
    // behind it. Level drives how much arrives; the hue is kept separately.
    float peak = max(max(lightMapColor.r, lightMapColor.g), lightMapColor.b);
    float level = clamp(peak, 0.0, 1.0);
    level = level * level * (3.0 - 2.0 * level);
    vec3 lightHue = lightMapColor.rgb / max(peak, 1e-3);

    vec3 n = normalize(normalView);
    vec3 v = normalize(-cameraRelativePos);

    // The sun is defined in world space; the modelview 3x3 is the camera's world
    // to view rotation, so this puts the light in the same space as the normal.
    vec3 sunView = normalize(mat3(ModelViewMat) * vv_sun_direction());
    vec3 moonView = normalize(mat3(ModelViewMat) * vv_moon_direction());

    // Roughness sits higher than terrain: skin, wool and leaves are all matte,
    // and metal and glass are close enough to a few highlights that one value
    // reads acceptably across the whole set.
    const float rough = 0.55;
    const float metal = 0.0;

    vec3 direct = vv_brdf(n, v, sunView, albedo, rough, metal, vv_sun_radiance() * lightHue * 0.85);
    direct += vv_brdf(n, v, moonView, albedo, rough, metal, vv_moon_radiance() * lightHue * 0.85);

    vec3 ambient = albedo * vv_sky_ambient(n) * lightHue * 0.85;

    float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
    vec3 rimColor = mix(vec3(0.04, 0.06, 0.10), vec3(0.26, 0.34, 0.48), smoothstep(-0.2, 0.4, vv_sun_height()));

    return (direct + ambient) * level + rim * rimColor * level * 0.5;
}
#endif

vec4 calculateFinalColor(vec4 color) {
    #ifndef NO_OVERLAY
    color.rgb = mix(overlayColor.rgb, color.rgb, overlayColor.a);
    #endif

    #ifdef GLINT
    vec4 glintColor = GlintAlpha * texture(GlintSampler, texCoordGlint);
    // Matches BlendFunction.GLINT
    color.rgb += glintColor.rgb * glintColor.rgb;
    #endif

    #ifdef OIT_ACCUMULATE
    color = sampleColorForAccumulation(color);
    vec4 fogColor = vec4(FogColor.rgb * color.a, FogColor.a);
    #else
    vec4 fogColor = FogColor;
    #endif

    vec4 fogged = apply_fog(color, sphericalVertexDistance, cylindricalVertexDistance, FogEnvironmentalStart, FogEnvironmentalEnd, FogRenderDistanceStart, FogRenderDistanceEnd, fogColor);

    #ifdef OIT_ACCUMULATE
    // Translucent entities go through OIT, where alpha is coverage and the post
    // chain reads it as the translucent-surface tag.
    return fogged;
    #elif defined(GLINT)
    // Glint is blended against its own alpha, so it has to keep full coverage.
    return vec4(fogged.rgb, 1.0);
    #else
    // Entities drawn in this pass are solid surfaces, so main's alpha is free to
    // carry the same tag terrain.fsh writes. Without this the texture's own
    // alpha (1.0 for most mobs) would read as translucent and give every entity
    // a mirror-sharp reflection.
    return vec4(fogged.rgb, 0.0);
    #endif
}

void main() {
    vec4 color = texture(Sampler0, texCoord0);

    #ifdef OIT_ADDITIVE
    color.a = min(0.99, color.a);
    #endif

    #ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
    #endif

    #ifdef PER_FACE_LIGHTING
    vec4 faceColor = gl_FrontFacing ? vertexPerFaceColorFront : vertexPerFaceColorBack;
    #else
    vec4 faceColor = vertexColor;
    #endif

    #ifdef DISSOLVE
    if (faceColor.a < texture(DissolveMaskSampler, texCoord0).a) {
        discard;
    }
    // The dissolve effect entirely replaces translucency
    faceColor.a = 1.0;
    #endif

    #ifdef GLINT
    color.a = max(color.a, GlintAlpha);
    #endif

    #ifdef OIT_ALPHA_ONLY
    executeAlphaOnlyPhase(gl_FragCoord.z, color.a);
    #else
    #ifdef EMISSIVE
    // Emissive entities are not lit by the world at all, so they keep the flat
    // tint the vertex stage gave them.
    color.rgb *= faceColor.rgb;
    #else
    // faceColor carries the vertex tint and, unless cardinal lighting was
    // disabled, the game's own per-vertex light. Shading takes the texture
    // colour and the tint separately, so the baked light does not double up.
    color.rgb = shadeEntity(color, faceColor);
    #endif
    fragColor = calculateFinalColor(color);
    #endif
}
