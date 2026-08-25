#version 330
#extension GL_ARB_separate_shader_objects : require

// Inputs: scene color and depth textures.
// Sampler names are the post_effect pass sampler_name + "Sampler".
uniform sampler2D SceneTexSampler; // full scene color
uniform sampler2D DepthTexSampler; // depth buffer (non-linear depth from 0..1)

// A post pass is handed the screen quad's own projection, not the camera's, so
// the field of view has to come in through the pass. TanHalfFov is
// tan(radians(fov) / 2.0) for the player's vertical FOV: 0.7002 at the default 70.
// Reflectance is how much a surface reflects head on, Strength scales the lot.
layout(std140) uniform SsrConfig {
    float TanHalfFov;
    float Strength;
    float Reflectance;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int MAX_STEPS = 24;
const float STEP_FRACTION = 0.03; // first step, as a fraction of pixel distance
const float STEP_GROWTH = 1.15;   // each step reaches a little further than the last
const float SELF_BIAS = 0.005;    // ignore hits this close to the ray, relatively
const float THICKNESS = 0.25;     // how far behind a surface still counts as a hit
const float SKY_DEPTH = 0.9999;   // at or past this, the pixel is sky
const float BORDER_FADE = 0.08;   // fade hits out this far from the screen edge
const float FLAT_MIN = 0.40;      // normal agreement: below this is an edge
const float FLAT_MAX = 0.85;      // and above this is a surface

// View-space position of a pixel, in units of the near plane distance. Working
// in those units means the near plane cancels out of every direction and ratio
// below, so its value never has to be known here. z grows away from the camera.
vec3 viewPos(vec2 uv, float depth, vec2 lens) {
    float z = 1.0 / max(1.0 - depth, 1e-6);
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
vec4 march(vec3 origin, vec3 dir, vec2 lens) {
    float stepSize = origin.z * STEP_FRACTION;
    vec3 p = origin;

    for (int i = 0; i < MAX_STEPS; ++i) {
        p += dir * stepSize;
        stepSize *= STEP_GROWTH;
        if (p.z <= 1.0) break; // crossed the near plane

        vec2 uv = viewToUv(p, lens);
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;

        // Geometry off the side of the screen was never rendered and so cannot
        // be reflected; fade out approaching that edge instead of cutting off.
        vec2 border = smoothstep(vec2(0.0), vec2(BORDER_FADE), min(uv, 1.0 - uv));
        float fade = min(border.x, border.y);

        float depth = texture(DepthTexSampler, uv).r;
        if (depth >= SKY_DEPTH) {
            // The sky is a perfectly good thing to see reflected, and over open
            // ground it is the only thing an upward ray can ever reach.
            return vec4(texture(SceneTexSampler, uv).rgb, fade);
        }

        float sceneZ = 1.0 / max(1.0 - depth, 1e-6);
        float behind = p.z - sceneZ;
        // Hit: the ray has passed behind this pixel's surface, but not so far
        // behind that it is really occluded by something in the foreground.
        if (behind > sceneZ * SELF_BIAS && behind < sceneZ * THICKNESS) {
            return vec4(texture(SceneTexSampler, uv).rgb, fade);
        }
    }
    return vec4(0.0); // miss
}

void main() {
    vec3 base = texture(SceneTexSampler, texCoord).rgb;
    float depth = texture(DepthTexSampler, texCoord).r;
    if (depth >= SKY_DEPTH) {
        fragColor = vec4(base, 1.0);
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
        fragColor = vec4(base, 1.0);
        return;
    }
    vec3 N = normalize(nFwd + nBwd);

    vec3 I = normalize(P); // camera through this pixel, into the scene
    vec3 R = reflect(I, N);

    // Schlick: Reflectance head on, rising toward a mirror at grazing angles.
    float cosTheta = clamp(dot(N, -I), 0.0, 1.0);
    float fresnel = Reflectance + (1.0 - Reflectance) * pow(1.0 - cosTheta, 5.0);

    vec4 hit = march(P, R, lens);
    fragColor = vec4(mix(base, hit.rgb, fresnel * Strength * flatness * hit.a), 1.0);
}
