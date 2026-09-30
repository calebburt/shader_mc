#ifndef MINECRAFT_VV_LIGHTING_GLSL
#define MINECRAFT_VV_LIGHTING_GLSL

// The sun direction and colour live in vv_sun.glsl so the post effect chain can
// reach them too; this header adds the BRDF and ambient that only the world
// passes need.
#include <minecraft:vv_sun.glsl>

// Ambient the sky throws onto a surface. Cool from overhead, dimmer and browner
// from below, plus a warm wash on the sun-facing side while the sun is low, which
// is the bounce that sells a sunrise.
vec3 vv_sky_ambient(vec3 n) {
    float day = smoothstep(-0.25, 0.40, vv_sun_height());

    vec3 zenith = mix(vec3(0.020, 0.024, 0.036), vec3(0.26, 0.33, 0.45), day);
    vec3 ground = mix(vec3(0.010, 0.010, 0.014), vec3(0.13, 0.12, 0.11), day);

    vec3 ambient = mix(ground, zenith, n.y * 0.5 + 0.5);

    vec3 sun = vv_sun_direction();
    float low = 1.0 - smoothstep(0.0, 0.42, sun.y);
    ambient += vec3(0.16, 0.070, 0.018) * low * max(dot(n, sun), 0.0);

    return ambient;
}

// Cook-Torrance direct lighting for one light. Radiance is expected around 1.0;
// the /PI on the diffuse is the usual Lambert normalisation and is what keeps a
// fully lit white surface from clipping.
vec3 vv_brdf(vec3 n, vec3 v, vec3 l, vec3 albedo, float roughness, float metalness, vec3 radiance) {
    float nDotL = max(dot(n, l), 0.0);
    if (nDotL <= 0.0 || dot(radiance, vec3(1.0)) <= 0.0) {
        return vec3(0.0);
    }

    vec3 h = normalize(v + l);
    float nDotV = max(dot(n, v), 1e-4);
    float nDotH = max(dot(n, h), 0.0);
    float vDotH = max(dot(v, h), 0.0);

    float a = max(roughness, 0.045);
    float a2 = a * a;

    // GGX / Trowbridge-Reitz normal distribution
    float denom = nDotH * nDotH * (a2 - 1.0) + 1.0;
    float d = a2 / max(VV_PI * denom * denom, 1e-7);

    // Smith height-correlated visibility, folded down to the k approximation
    float k = a * 0.5;
    float gv = nDotV / (nDotV * (1.0 - k) + k);
    float gl = nDotL / (nDotL * (1.0 - k) + k);
    float g = gv * gl;

    vec3 f0 = mix(vec3(0.04), albedo, metalness);
    vec3 f = f0 + (1.0 - f0) * pow(1.0 - vDotH, 5.0);

    vec3 specular = (d * g * f) / max(4.0 * nDotV * nDotL, 1e-4);
    vec3 diffuse = (vec3(1.0) - f) * albedo * (1.0 - metalness) * VV_INV_PI;

    return (diffuse + specular) * radiance * nDotL;
}

// How the game encodes skylight in a sampled lightmap: brightest channel wins,
// then a curve so the dark end of the ramp keeps some shape.
float vv_light_level(vec3 lightmapColor) {
    float level = max(max(lightmapColor.r, lightmapColor.g), lightmapColor.b);
    return clamp(level * level * (3.0 - 2.0 * level), 0.0, 1.0);
}

// Standard derivative bump mapping. Minecraft block textures carry no normal map
// and the terrain format has no normal attribute either, so the screen-space
// gradient of the albedo stands in for surface relief: mortar lines between
// bricks, blades of grass, the grain of planks.
vec3 vv_bump_from_albedo(vec3 n, vec3 position, float height, float scale) {
    vec3 dpdx = dFdx(position);
    vec3 dpdy = dFdy(position);
    float dhdx = dFdx(height);
    float dhdy = dFdy(height);

    vec3 r1 = cross(dpdy, n);
    vec3 r2 = cross(n, dpdx);
    float det = dot(dpdx, r1);

    // A degenerate derivative pair (silhouette, or a quad flattened by
    // projection) has nothing to differentiate along, so leave the normal be.
    if (abs(det) < 1e-12) {
        return n;
    }

    vec3 grad = (r1 * dhdx + r2 * dhdy) / det;
    return normalize(n - scale * grad);
}

#endif
