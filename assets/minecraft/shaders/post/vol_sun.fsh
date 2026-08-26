#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D MaskTexSampler; // the light mask, blurred

// SunGain scales how much found light counts as full strength, which sets how
// quickly the shafts fade up as the sun comes into view.
layout(std140) uniform VolSunConfig {
    float SunGain;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

// A post pass is given the screen quad's projection, never the camera's, so
// where the sun is on screen cannot be handed to this chain. Instead this pass
// finds it: the brightness-weighted centroid of the light mask is the sun. It
// renders to a 1x1 target, so this whole grid is walked for a single fragment.
const int GRID = 32;

void main() {
    vec2 weighted = vec2(0.0);
    float total = 0.0;

    for (int y = 0; y < GRID; ++y) {
        for (int x = 0; x < GRID; ++x) {
            vec2 uv = (vec2(x, y) + 0.5) / float(GRID);
            float amount = texture(MaskTexSampler, uv).a;
            weighted += uv * amount;
            total += amount;
        }
    }

    // rg: where the light is. b: how much of it was found, so the rays pass can
    // fade out when the sun sets, goes behind a hill, or leaves the screen.
    vec2 center = total > 0.0 ? weighted / total : vec2(0.5);
    float strength = clamp(total / float(GRID * GRID) * SunGain, 0.0, 1.0);
    fragColor = vec4(center, strength, 1.0);
}
