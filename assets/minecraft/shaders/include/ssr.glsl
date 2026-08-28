const int MAX_STEPS = 24;
const float STEP_FRACTION = 0.03; // first step, as a fraction of pixel distance
const float STEP_GROWTH = 1.15;   // each step reaches a little further than the last
const float SELF_BIAS = 0.005;    // ignore hits this close to the ray, relatively
const float THICKNESS = 0.25;     // how far behind a surface still counts as a hit
const float SKY_DEPTH = 1e-3;     // at or below this, nothing was drawn here
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

// This pass does not touch the scene: it writes the reflection alone, premultiplied
// by its strength, for the blur and composite passes in ssr.json to finish.
// March the reflected ray through view space, projecting each sample back to
// screen to compare it against the depth buffer. Returns the reflected color in
// rgb and how much to trust it in a: zero means the ray found nothing, and the
// pixel must then be left exactly as it was.
vec4 march(vec3 origin, vec3 dir, vec2 lens, sampler2D SceneTexSampler, sampler2D DepthTexSampler, out int outcome) {
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