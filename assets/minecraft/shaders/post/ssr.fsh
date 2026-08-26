#version 330
#extension GL_ARB_separate_shader_objects : require

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
    float MaskMode;
    float MaskLevel;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int MAX_STEPS = 24;
const float STEP_FRACTION = 0.03; // first step, as a fraction of pixel distance
const float STEP_GROWTH = 1.15;   // each step reaches a little further than the last
const float SELF_BIAS = 0.005;    // ignore hits this close to the ray, relatively
const float THICKNESS = 0.25;     // how far behind a surface still counts as a hit
const float SKY_DEPTH = 1e-6;     // at or below this, nothing was drawn here
const float BORDER_FADE = 0.08;   // fade hits out this far from the screen edge
const float FLAT_MIN = 0.40;      // normal agreement: below this is an edge
const float FLAT_MAX = 0.85;      // and above this is a surface
const float NEAR_PLANE = 0.05;    // only used to label the depth debug view

// What a ray ended up doing, for DebugView 3.
const int RAY_OUT_OF_STEPS = 0;
const int RAY_SKY = 1;
const int RAY_GEOMETRY = 2;
const int RAY_NEAR_PLANE = 3;
const int RAY_OFF_SCREEN = 4;

// This build's depth buffer is REVERSED: 1.0 at the near plane, falling toward
// 0.0 at the far plane, and 0.0 wherever nothing was drawn. Every world pipeline
// in RenderPipelines tests depth with GREATER_THAN_OR_EQUAL and never with any
// LESS_*, and vanilla's integrate_depth.fsh discards on depth == 0.0, neither of
// which makes sense the other way round. So depth is near / distance, and
// distance is near / depth -- which in units of the near plane is just 1 / depth.
// Reading it the conventional way maps the whole world into a sliver just past
// the near plane, flattening every reconstructed normal to face the camera.
float linearZ(float depth) {
    return 1.0 / max(depth, 1e-7);
}

// Which surfaces the effect is allowed on. There is no translucent-only target
// to sample in this version -- OIT resolves translucency into main before any
// post pass runs, and PostChain rejects a chain that names a target the context
// does not provide -- so the only per-pixel tag that can reach here is main's
// own alpha channel. DebugView 5 shows what it actually holds.
//   MaskMode 0: every surface
//   MaskMode 1: only where main's alpha is below MaskLevel
//   MaskMode 2: only where main's alpha is at or above MaskLevel
float surfaceMask(float alpha) {
    int mode = int(MaskMode + 0.5);
    if (mode == 1) return alpha < MaskLevel ? 1.0 : 0.0;
    if (mode == 2) return alpha >= MaskLevel ? 1.0 : 0.0;
    return 1.0;
}

// View-space position of a pixel, in units of the near plane distance. Working
// in those units means the near plane cancels out of every direction and ratio
// below, so its value never has to be known here. z grows away from the camera.
vec3 viewPos(vec2 uv, float depth, vec2 lens) {
    float z = linearZ(depth);
    return vec3((uv * 2.0 - 1.0) * lens * z, z);
}

// Where a view-space point lands back on screen.
vec2 viewToUv(vec3 p, vec2 lens) {
    return (p.xy / (p.z * lens)) * 0.5 + 0.5;
}

// March the reflected ray through view space, projecting each sample back to
// screen to compare it against the depth buffer. Returns the reflected color in
// rgb and how much to trust it in a: zero means the ray found nothing, and the
// pixel must then be left exactly as it was.
vec4 march(vec3 origin, vec3 dir, vec2 lens, out int outcome) {
    float stepSize = origin.z * STEP_FRACTION;
    vec3 p = origin;
    outcome = RAY_OUT_OF_STEPS;

    for (int i = 0; i < MAX_STEPS; ++i) {
        p += dir * stepSize;
        stepSize *= STEP_GROWTH;
        if (p.z <= 1.0) {
            outcome = RAY_NEAR_PLANE; // aimed back past the camera
            break;
        }

        vec2 uv = viewToUv(p, lens);
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) {
            outcome = RAY_OFF_SCREEN; // whatever it would have hit was never drawn
            break;
        }

        // Geometry off the side of the screen was never rendered and so cannot
        // be reflected; fade out approaching that edge instead of cutting off.
        vec2 border = smoothstep(vec2(0.0), vec2(BORDER_FADE), min(uv, 1.0 - uv));
        float fade = min(border.x, border.y);

        float depth = texture(DepthTexSampler, uv).r;
        if (depth <= SKY_DEPTH) {
            // The sky is a perfectly good thing to see reflected, and over open
            // ground it is the only thing an upward ray can ever reach.
            outcome = RAY_SKY;
            return vec4(texture(SceneTexSampler, uv).rgb, fade);
        }

        float sceneZ = linearZ(depth);
        float behind = p.z - sceneZ;
        // Hit: the ray has passed behind this pixel's surface, but not so far
        // behind that it is really occluded by something in the foreground.
        if (behind > sceneZ * SELF_BIAS && behind < sceneZ * THICKNESS) {
            outcome = RAY_GEOMETRY;
            return vec4(texture(SceneTexSampler, uv).rgb, fade);
        }
    }
    return vec4(0.0); // miss
}

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    vec3 base = scene.rgb;
    float depth = texture(DepthTexSampler, texCoord).r;
    int debug = 0;
    if (depth <= SKY_DEPTH) {
        // Sky pixel: nothing to reflect off. Black in every debug view.
        fragColor = vec4(debug == 0 ? base : vec3(0.0), 1.0);
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
        fragColor = vec4(debug == 0 ? base : vec3(0.25), 1.0);
        return;
    }
    vec3 N = normalize(nFwd + nBwd);

    vec3 I = normalize(P); // camera through this pixel, into the scene
    vec3 R = reflect(I, N);

    // Schlick: Reflectance head on, rising toward a mirror at grazing angles.
    float cosTheta = clamp(dot(N, -I), 0.0, 1.0);
    float fresnel = Reflectance + (1.0 - Reflectance) * pow(1.0 - cosTheta, 5.0);

    int outcome;
    vec4 hit = march(P, R, lens, outcome);
    float weight = fresnel * Strength * flatness * hit.a * surfaceMask(scene.a);

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
        fragColor = vec4(mix(base, hit.rgb, weight), 1.0);
    }
}
