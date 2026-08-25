#version 330

in vec2 uv;

out vec4 fragColor;

// Inputs: scene color and depth textures (no uniforms needed).
uniform sampler2D SceneTex; // full scene color
uniform sampler2D DepthTex; // depth buffer (non-linear depth from 0..1)

const int MAX_STEPS = 20;
const float STEP_SIZE = 0.01; // screen-space step (fraction of screen)
const float DEPTH_BIAS = 0.02;

// Screen-space ray-march: march outward in screen UV space
vec3 ssrSample(vec2 rayStart, vec2 rayDir) {
    vec2 rayUV = rayStart;
    float startDepth = texture(DepthTex, rayStart).r;
    
    for (int i = 0; i < MAX_STEPS; ++i) {
        rayUV += rayDir * STEP_SIZE;
        if (rayUV.x < 0.0 || rayUV.x > 1.0 || rayUV.y < 0.0 || rayUV.y > 1.0) break;
        
        float sampleDepth = texture(DepthTex, rayUV).r;
        // Hit test: if sample depth is shallower (larger in [0,1]) than start
        if (sampleDepth > startDepth + DEPTH_BIAS) {
            return texture(SceneTex, rayUV).rgb;
        }
    }
    return vec3(0.0); // miss
}

void main() {
    // Current pixel
    vec3 base = texture(SceneTex, uv).rgb;
    float depthN = texture(DepthTex, uv).r;

    // Get screen size from texture
    vec2 screenSize = vec2(textureSize(DepthTex, 0));
    vec2 texel = 1.0 / screenSize;

    // Sample neighboring depth for normal reconstruction
    vec2 uvR = clamp(uv + vec2(texel.x, 0.0), vec2(0.0), vec2(1.0));
    vec2 uvL = clamp(uv - vec2(texel.x, 0.0), vec2(0.0), vec2(1.0));
    vec2 uvU = clamp(uv + vec2(0.0, texel.y), vec2(0.0), vec2(1.0));
    vec2 uvD = clamp(uv - vec2(0.0, texel.y), vec2(0.0), vec2(1.0));

    float dR = texture(DepthTex, uvR).r;
    float dL = texture(DepthTex, uvL).r;
    float dU = texture(DepthTex, uvU).r;
    float dD = texture(DepthTex, uvD).r;

    // Estimate surface normal from depth gradients (screen-space derivatives)
    vec3 ddx = vec3(texel.x, 0.0, (dR - dL) * 0.5);
    vec3 ddy = vec3(0.0, texel.y, (dU - dD) * 0.5);
    vec3 N = normalize(cross(ddy, ddx));

    // Simple view direction (screen-space ray toward camera)
    vec3 V = normalize(vec3(uv * 2.0 - 1.0, 1.0));
    vec3 R = reflect(V, clamp(N, -1.0, 1.0));

    // Project reflection into screen-space ray direction
    vec2 rayDir = normalize(R.xy);
    vec3 hitColor = ssrSample(uv, rayDir);

    // Fresnel-based blend: reflections stronger at grazing angles
    float fresnel = pow(1.0 - max(dot(N, V), 0.0), 5.0);
    vec3 final = mix(base, hitColor, fresnel * 0.5); // reduced blend strength for subtlety

    fragColor = vec4(final, 1.0);
}
