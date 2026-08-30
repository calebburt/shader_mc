#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D MaskTexSampler; // the light mask, unblurred
uniform sampler2D SunTexSampler;  // 1x1: light position in rg, strength in b

// Density: how far along the line toward the light each pixel marches, as a
// fraction of the distance to it. Decay: per-step falloff, so shafts fade with
// distance from the light. Exposure: overall gain on the result.
layout(std140) uniform VolRaysConfig {
    float Density;
    float Decay;
    float Exposure;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

const int SAMPLES = 32;

void main() {
    vec4 sun = texture(SunTexSampler, vec2(0.0));
    if (sun.b <= 0.0) {
        fragColor = vec4(0.0); // no light in view, so no shafts
        return;
    }

    // Step from this pixel toward the light, gathering the mask as it goes. Where
    // geometry masks the light the gathered total drops, and the gaps between
    // become the shafts.
    vec2 delta = (sun.rg - texCoord) * (Density / float(SAMPLES));
    vec2 uv = texCoord;
    vec4 gathered = vec4(0.0);
    float illumination = 1.0;

    for (int i = 0; i < SAMPLES; ++i) {
        uv += delta;
        gathered += texture(MaskTexSampler, uv) * illumination;
        illumination *= Decay;
    }

    fragColor = gathered * (Exposure / float(SAMPLES)) * sun.b;
}
