#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:ssr.glsl>

uniform sampler2D SceneTexSampler;
uniform sampler2D DepthTexSampler;

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int SAMPLES = 8;
const float DENSITY = 0.1;
const float TanHalfFov = 0.7002;

float sampleFogHit(float density, float xi) {
    // extinction coefficient (sigma_t)
    float sigma_t = density;

    // sample free-flight distance
    return -log(1.0 - xi) / sigma_t;
}

vec3 randomUnitVector(float a, float b) {
    float z = 1.0 - 2.0 * a;
    float r = sqrt(max(0.0, 1.0 - z*z));
    float phi = 6.2831853 * b;
    return vec3(r * cos(phi), r * sin(phi), z);
}

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    float depth = texture(DepthTexSampler, texCoord).r;

    vec2 texel = 1.0 / vec2(textureSize(DepthTexSampler, 0));
    // Half-extent of the near plane in view space: aspect is width/height, which
    // in texel terms is texel.y / texel.x.
    vec2 lens = vec2(TanHalfFov * texel.y / texel.x, TanHalfFov);

    // Keep the neighbourhood on screen, so no two samples land on the same
    // clamped texel and leave a tangent of length zero behind.
    vec2 uv = clamp(texCoord, texel, 1.0 - texel);

    vec3 P = viewPos(uv, texture(DepthTexSampler, uv).r, lens);

    vec3 accum = vec3(0.0);

    float xi = 0.0;
    float fogDistance;
    for (int i = 0; i < SAMPLES; i++) {
        fogDistance = sampleFogHit(DENSITY, xi);
        P = viewPos(uv, fogDistance, lens);
        for (int x = 0; x < SAMPLES; x++) {
            for (int y = 0; y < SAMPLES; y++) {
                vec3 scatteringDirection = randomUnitVector(float(x) / float(SAMPLES), float(y) / float(SAMPLES));
                int _outcome;
                vec3 hit = march(P, scatteringDirection, lens, SceneTexSampler, DepthTexSampler, _outcome).rgb;
                accum += hit;
            }
        }

        xi = float(i) / float(SAMPLES);
    }

    accum /= SAMPLES * SAMPLES * SAMPLES;

    fragColor = accum;
}
