#version 330
#extension GL_ARB_separate_shader_objects : require

// Inputs: scene color and depth textures (no config uniforms needed).
// Sampler names are the post_effect pass sampler_name + "Sampler".
uniform sampler2D SceneTexSampler; // full scene color
uniform sampler2D DepthTexSampler; // depth buffer (non-linear depth from 0..1)

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int MAX_STEPS = 20;
const float STEP_SIZE = 0.01;   // screen-space step (fraction of screen)
const float DEPTH_BIAS = 0.001; // non-linear depth units, so this is a taste knob

// Screen-space ray-march. Depth is 0 at the near plane and 1 at the far one, so
// the ray has hit something when the scene at that pixel sits in FRONT of where
// the ray has reached. rayDir.xy is in UV units, normalised so one step covers
// STEP_SIZE of the screen; rayDir.z is in depth-buffer units, the same mixed
// space main() reconstructs the normal in.
vec3 ssrSample(vec2 rayStart, float startDepth, vec3 rayDir) {
    vec2 rayUV = rayStart;
    float rayDepth = startDepth;

    for (int i = 0; i < MAX_STEPS; ++i) {
        rayUV += rayDir.xy * STEP_SIZE;
        rayDepth += rayDir.z * STEP_SIZE;
        if (rayUV.x < 0.0 || rayUV.x > 1.0 || rayUV.y < 0.0 || rayUV.y > 1.0) break;

        float sampleDepth = texture(DepthTexSampler, rayUV).r;
        // Hit: this pixel's surface is nearer than the ray, so the ray went behind it.
        if (sampleDepth < rayDepth - DEPTH_BIAS) {
            return texture(SceneTexSampler, rayUV).rgb;
        }
    }
    return vec3(0.0); // miss
}

void main() {
    // Current pixel
    vec3 base = texture(SceneTexSampler, texCoord).rgb;
    float depthN = texture(DepthTexSampler, texCoord).r;

    // Get screen size from texture
    vec2 screenSize = vec2(textureSize(DepthTexSampler, 0));
    vec2 texel = 1.0 / screenSize;

    // Sample neighboring depth for normal reconstruction
    vec2 uvR = clamp(texCoord + vec2(texel.x, 0.0), vec2(0.0), vec2(1.0));
    vec2 uvL = clamp(texCoord - vec2(texel.x, 0.0), vec2(0.0), vec2(1.0));
    vec2 uvU = clamp(texCoord + vec2(0.0, texel.y), vec2(0.0), vec2(1.0));
    vec2 uvD = clamp(texCoord - vec2(0.0, texel.y), vec2(0.0), vec2(1.0));

    float dR = texture(DepthTexSampler, uvR).r;
    float dL = texture(DepthTexSampler, uvL).r;
    float dU = texture(DepthTexSampler, uvU).r;
    float dD = texture(DepthTexSampler, uvD).r;

    // Surface tangents in (u, v, depth) space: x right, y up, z away from the
    // camera. cross(y, x) then points back toward the camera, which is the
    // outward normal we want.
    vec3 tangentX = vec3(texel.x, 0.0, (dR - dL) * 0.5);
    vec3 tangentY = vec3(0.0, texel.y, (dU - dD) * 0.5);
    vec3 N = normalize(cross(tangentY, tangentX));

    // Ray from the camera through this pixel, pointing into the scene (+z).
    vec3 I = normalize(vec3(texCoord * 2.0 - 1.0, 1.0));
    vec3 R = reflect(I, N);

    // Fresnel-based blend: reflections stronger at grazing angles, near zero
    // where the surface faces the camera head on (-I aligned with N).
    float fresnel = pow(1.0 - clamp(dot(N, -I), 0.0, 1.0), 5.0);

    // A reflection aimed straight back at the camera has no screen-space
    // direction to march along, and normalising it would hand NaNs to texture().
    float spread = length(R.xy);
    vec3 hitColor = spread > 1e-5 ? ssrSample(texCoord, depthN, R / spread)
                                  : vec3(0.0);

    vec3 final = mix(base, hitColor, fresnel * 0.5); // reduced blend strength for subtlety

    fragColor = vec4(final, 1.0);
}
