#version 330
#extension GL_ARB_separate_shader_objects : require

uniform sampler2D SceneTexSampler; // the scene as rendered
uniform sampler2D SharpTexSampler; // reflection from the ssr pass, premultiplied
uniform sampler2D BlurTexSampler;  // that same reflection, blurred

// MaskLevel: main's alpha at or above this counts as a translucent surface,
// which terrain.fsh arranges by tagging opaque terrain with alpha 0.
// RoughStrength: how much of the blurred reflection everything else receives.
// DebugView: non-zero passes the ssr pass's debug output straight through, so
// set it to the same value as the ssr pass's DebugView.
layout(std140) uniform SsrCompositeConfig {
    float MaskLevel;
    float RoughStrength;
    float DebugView;
};

layout(location = 0) in vec2 texCoord;

layout(location = 0) out vec4 fragColor;

void main() {
    vec4 scene = texture(SceneTexSampler, texCoord);
    vec4 sharp = texture(SharpTexSampler, texCoord);

    if (int(DebugView + 0.5) != 0) {
        fragColor = vec4(sharp.rgb, 1.0);
        return;
    }

    // Translucent surfaces get the reflection as traced. Everything else gets it
    // blurred and dialled back, which reads as a rough surface catching a hint of
    // its surroundings rather than as a mirror.
    vec4 refl = scene.a >= MaskLevel
        ? sharp
        : texture(BlurTexSampler, texCoord) * clamp(RoughStrength, 0.0, 1.0);

    // Both reflections are premultiplied, so this composites without the dark
    // fringes a straight mix would leave wherever the blur spread colour into
    // pixels that found nothing to reflect.
    fragColor = vec4(scene.rgb * (1.0 - refl.a) + refl.rgb, 1.0);
}
