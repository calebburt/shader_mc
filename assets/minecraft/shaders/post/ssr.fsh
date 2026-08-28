#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:ssr.glsl>

// Inputs: scene color and depth textures.
// Sampler names are the post_effect pass sampler_name + "Sampler".
uniform sampler2D SceneTexSampler; // full scene color
uniform sampler2D DepthTexSampler; // reversed-Z depth: see linearZ() below

// A post pass is handed the screen quad's own projection, not the camera's, so
// the field of view has to come in through the pass. TanHalfFov is
// tan(radians(fov) / 2.0) for the player's vertical FOV: 0.7002 at the default 70.
// Reflectance is how much a surface reflects head on, Strength scales the lot.
layout(std140) uniform SsrConfig {
    float TanHalfFov;
    float Strength;
    float Reflectance;
    float DebugView;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    float depth = texture(DepthTexSampler, texCoord).r;
    int debug = 0;
    if (depth <= SKY_DEPTH) {
        // Sky pixel: nothing to reflect off, so contribute nothing.
        fragColor = debug == 0 ? vec4(0.0) : vec4(0.0, 0.0, 0.0, 1.0);
        return;
    }

    vec2 texel = 1.0 / vec2(textureSize(DepthTexSampler, 0));
    // Half-extent of the near plane in view space: aspect is width/height, which
    // in texel terms is texel.y / texel.x.
    vec2 lens = vec2(TanHalfFov * texel.y / texel.x, TanHalfFov);

    // Keep the neighbourhood on screen, so no two samples land on the same
    // clamped texel and leave a tangent of length zero behind.
    vec2 uv = clamp(texCoord, texel, 1.0 - texel);

    vec3 P = viewPos(uv, texture(DepthTexSampler, uv).r, lens);
    vec2 dx = vec2(texel.x, 0.0), dy = vec2(0.0, texel.y);
    vec3 pR = viewPos(uv + dx, texture(DepthTexSampler, uv + dx).r, lens);
    vec3 pL = viewPos(uv - dx, texture(DepthTexSampler, uv - dx).r, lens);
    vec3 pU = viewPos(uv + dy, texture(DepthTexSampler, uv + dy).r, lens);
    vec3 pD = viewPos(uv - dy, texture(DepthTexSampler, uv - dy).r, lens);

    // Two independent normals: one from the neighbours above and right, one from
    // those below and left. Both point back toward the camera. On a flat surface
    // they agree to six decimal places however steep the perspective; wherever
    // the neighbourhood straddles two surfaces -- a block edge, a silhouette --
    // they diverge completely, which is exactly where a depth-reconstructed
    // normal is nonsense and must not be allowed to drive a reflection.
    vec3 nFwd = normalize(cross(pU - P, pR - P));
    vec3 nBwd = normalize(cross(P - pD, P - pL));
    float flatness = smoothstep(FLAT_MIN, FLAT_MAX, dot(nFwd, nBwd));
    if (flatness <= 0.0) {
        // Edge or silhouette: the normal here is not usable. Grey when debugging.
        fragColor = debug == 0 ? vec4(0.0) : vec4(vec3(0.25), 1.0);
        return;
    }
    vec3 N = normalize(nFwd + nBwd);

    vec3 I = normalize(P); // camera through this pixel, into the scene
    vec3 R = reflect(I, N);

    // Schlick: Reflectance head on, rising toward a mirror at grazing angles.
    float cosTheta = clamp(dot(N, -I), 0.0, 1.0);
    float fresnel = Reflectance + (1.0 - Reflectance) * pow(1.0 - cosTheta, 5.0);

    int outcome;
    vec4 hit = march(P, R, lens, SceneTexSampler, DepthTexSampler, outcome);
    float weight = fresnel * Strength * flatness * hit.a;

    // DebugView, set in ssr.json: 0 renders normally, the rest answer "which
    // stage gave up on this pixel?" without needing a debugger in the game.
    if (debug == 1) {                       // reconstructed normal
        fragColor = vec4(N * 0.5 + 0.5, 1.0);
    } else if (debug == 2) {                // distance, one stripe per 8 blocks
        float blocks = P.z * NEAR_PLANE;
        fragColor = vec4(vec3(fract(blocks / 8.0)), 1.0);
    } else if (debug == 3) {                // what the ray did
        vec3 c = vec3(1.0, 0.0, 0.0);                       // red: out of steps
        if (outcome == RAY_GEOMETRY)   c = vec3(0.0, 1.0, 0.0);  // green: hit geometry
        if (outcome == RAY_SKY)        c = vec3(0.2, 0.4, 1.0);  // blue: hit sky
        if (outcome == RAY_OFF_SCREEN) c = vec3(1.0, 0.9, 0.0);  // yellow: left the screen
        if (outcome == RAY_NEAR_PLANE) c = vec3(1.0, 0.0, 1.0);  // magenta: back past camera
        fragColor = vec4(c, 1.0);
    } else if (debug == 4) {                // how strong the reflection came out
        fragColor = vec4(vec3(weight), 1.0);
    } else if (debug == 5) {                // what main's alpha channel holds
        // The only channel that could carry a material tag from world rendering
        // into this pass, since no translucent-only target exists to read.
        fragColor = vec4(vec3(scene.a), 1.0);
    } else if (debug == 5) {
        // main's alpha channel. There is no translucent target to isolate in
        // this version -- OIT resolves translucency into main before any post
        // pass runs -- so alpha is the only channel left that could carry a
        // "this pixel is water" tag. Red where it is 0, green where it is 1.
        float a = texture(SceneTexSampler, texCoord).a;
        fragColor = vec4(1.0 - a, a, 0.0, 1.0);
    } else {
        // Premultiplied by the weight, so a box blur can spread this without
        // dragging in black from pixels whose ray found nothing. ssr_composite
        // does the blending over the scene.
        fragColor = vec4(hit.rgb * weight, weight);
    }
}
