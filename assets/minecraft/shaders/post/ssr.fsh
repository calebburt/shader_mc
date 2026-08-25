#version 330
#extension GL_ARB_separate_shader_objects : require

// Inputs: scene color and depth textures.
// Sampler names are the post_effect pass sampler_name + "Sampler".
uniform sampler2D SceneTexSampler; // full scene color
uniform sampler2D DepthTexSampler; // depth buffer (non-linear depth from 0..1)

// A post pass is handed the screen quad's own projection, not the camera's, so
// the field of view has to come in through the pass. TanHalfFov is
// tan(radians(fov) / 2.0) for the player's vertical FOV: 0.7002 at the default 70.
layout(std140) uniform SsrConfig {
    float TanHalfFov;
    float Strength;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int MAX_STEPS = 24;
const float STEP_FRACTION = 0.05;  // ray step, as a fraction of the pixel's distance
const float SELF_BIAS = 0.005;     // ignore hits this close to the ray, relatively
const float THICKNESS = 0.25;      // how far behind a surface still counts as a hit
const float SKY_DEPTH = 0.9999;    // at or past this, the pixel is sky

// View-space position of a pixel, in units of the near plane distance. Working
// in those units means the near plane cancels out of every direction and ratio
// below, so its value never has to be known here. z grows away from the camera.
//
// Reconstructing this is the whole point: raw depth-buffer deltas are non-linear
// and in different units to the UV deltas beside them, so a normal built
// straight out of them reads as camera-facing on every real surface and only
// tilts where depth jumps -- which puts the effect on block edges alone.
vec3 viewPos(vec2 uv, float depth, vec2 lens) {
    float z = 1.0 / max(1.0 - depth, 1e-6);
    return vec3((uv * 2.0 - 1.0) * lens * z, z);
}

// Where a view-space point lands back on screen.
vec2 viewToUv(vec3 p, vec2 lens) {
    return (p.xy / (p.z * lens)) * 0.5 + 0.5;
}

// March the reflected ray through view space, projecting each sample back to
// screen to compare it against the depth buffer.
vec3 march(vec3 origin, vec3 dir, vec2 lens) {
    float stepSize = origin.z * STEP_FRACTION;
    vec3 p = origin;

    for (int i = 0; i < MAX_STEPS; ++i) {
        p += dir * stepSize;
        if (p.z <= 1.0) break; // crossed the near plane

        vec2 uv = viewToUv(p, lens);
        if (any(lessThan(uv, vec2(0.0))) || any(greaterThan(uv, vec2(1.0)))) break;

        float depth = texture(DepthTexSampler, uv).r;
        if (depth >= SKY_DEPTH) continue; // sky writes no usable surface

        float sceneZ = 1.0 / max(1.0 - depth, 1e-6);
        float behind = p.z - sceneZ;
        // Hit: the ray has passed behind this pixel's surface, but not so far
        // behind that it is really occluded by something in the foreground.
        if (behind > sceneZ * SELF_BIAS && behind < sceneZ * THICKNESS) {
            return texture(SceneTexSampler, uv).rgb;
        }
    }
    return vec3(0.0); // miss
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

    vec3 P = viewPos(texCoord, depth, lens);

    float dR = texture(DepthTexSampler, texCoord + vec2(texel.x, 0.0)).r;
    float dL = texture(DepthTexSampler, texCoord - vec2(texel.x, 0.0)).r;
    float dU = texture(DepthTexSampler, texCoord + vec2(0.0, texel.y)).r;
    float dD = texture(DepthTexSampler, texCoord - vec2(0.0, texel.y)).r;

    // One-sided differences, taking whichever neighbour is nearer in depth, so a
    // silhouette does not smear a bogus normal along the block edge.
    vec3 tangentX = abs(dR - depth) < abs(depth - dL)
        ? viewPos(texCoord + vec2(texel.x, 0.0), dR, lens) - P
        : P - viewPos(texCoord - vec2(texel.x, 0.0), dL, lens);
    vec3 tangentY = abs(dU - depth) < abs(depth - dD)
        ? viewPos(texCoord + vec2(0.0, texel.y), dU, lens) - P
        : P - viewPos(texCoord - vec2(0.0, texel.y), dD, lens);

    // tangentX runs +x and tangentY runs +y, so y cross x faces back down -z,
    // toward the camera: the outward normal.
    vec3 N = normalize(cross(tangentY, tangentX));

    vec3 I = normalize(P); // camera through this pixel, into the scene
    vec3 R = reflect(I, N);

    // Fresnel: near zero where the surface faces the camera head on, rising at
    // grazing angles.
    float fresnel = pow(1.0 - clamp(dot(N, -I), 0.0, 1.0), 5.0);

    vec3 hitColor = march(P, R, lens);
    fragColor = vec4(mix(base, hitColor, fresnel * Strength), 1.0);
}
