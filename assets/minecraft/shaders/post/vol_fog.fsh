#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler;
uniform sampler2D DepthTexSampler;
uniform sampler2D SunTexSampler;

layout(location = 0) in vec2 texCoord;
layout(location = 0) out vec4 fragColor;

// Fog tuning
const float FOG_DENSITY = 0.001;
const float FOG_START   = 40.0;
const float FOG_END     = 1800.0;

// Base fallback fog color
const vec3 FOG_COLOR_BASE = vec3(0.70, 0.75, 0.80);

// Same depth model as SSR: reversed depth
float linearZ(float depth) {
    return 1.0 / max(depth, 1e-7);
}

// View-space position (same as SSR)
vec3 viewPosFog(vec2 uv, float depth, vec2 lens) {
    float z = linearZ(depth);
    return vec3((uv * 2.0 - 1.0) * lens * z, z);
}

// Fog amount
float fogAmount(float dist) {
    float d = clamp((dist - FOG_START) / (FOG_END - FOG_START), 0.0, 1.0);
    float baseFog = 1.0 - exp(-FOG_DENSITY * dist);
    return clamp(baseFog * d, 0.0, 1.0);
}

void main() {
    vec3 sceneColor = texture(SceneTexSampler, texCoord).rgb;

    float depthRaw = texture(DepthTexSampler, texCoord).r;
    float viewDist = linearZ(depthRaw);

    vec2 texel = 1.0 / vec2(textureSize(DepthTexSampler, 0));
    vec2 uv = clamp(texCoord, texel, 1.0 - texel);

    // ------------------------------------------------------------
    // ENVIRONMENT LIGHTING USING SUN COLOR
    // ------------------------------------------------------------
    vec3 fogLightColor = mix(texture(SunTexSampler, vec2(1.0, 0.5)).rgb, FOG_COLOR_BASE, 0.7);

    // Blend fog base color with environment lighting
    vec3 fogColorLit = mix(FOG_COLOR_BASE, fogLightColor, 0.5);

    // ------------------------------------------------------------

    float f = fogAmount(viewDist);

    vec3 finalColor = mix(sceneColor, fogColorLit, f);

    fragColor = vec4(finalColor, 1.0);
}
