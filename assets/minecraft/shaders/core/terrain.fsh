#version 330
#extension GL_ARB_separate_shader_objects : require

#include <minecraft:fog.glsl>
#include <minecraft:globals.glsl>
#include <minecraft:texture_sampling.glsl>
#include <minecraft:oit.glsl>
#include <minecraft:terrainglobals.glsl>
#ifndef MULTIDRAW_TERRAIN
    #include <minecraft:chunksection.glsl>
#endif

uniform sampler2D Sampler0;

layout(location = 0) in float sphericalVertexDistance;
layout(location = 1) in float cylindricalVertexDistance;
layout(location = 2) in vec4 vertexColor;
layout(location = 3) in vec2 texCoord0;
layout(location = 4) in float chunkVisibility;
layout(location = 5) in vec3 cameraRelativePos;

#ifndef OIT_ALPHA_ONLY
layout(location = 0) out vec4 fragColor;
#endif

float value(vec3 c) {
    return max(max(c.r, max(c.g, c.b)), 1e-5);
}

vec3 chroma(vec3 c) {
    return c / value(c);
}

// Vanilla's terrain texture sample: RGSS when supersampling is on, nearest
// otherwise, tinted by the vertex colour. Not wired into the output -- swap it
// into fragColor when you want the albedo back.
vec4 sampleTexture() {
    vec2 pixelSize = 1.0f / TextureSize;
    vec4 texel = UseRgss == 1
        ? sampleRGSS(Sampler0, texCoord0, pixelSize)
        : sampleNearest(Sampler0, texCoord0, pixelSize);
    return texel * vec4(chroma(vertexColor.rgb), vertexColor.a);
}

// The terrain vertex format has no normal attribute, so reconstruct the flat
// geometric normal from the screen-space derivatives of the camera-relative
// world position, then orient it back towards the camera (which sits at the
// origin of that space).
vec3 geometricNormal(vec3 cameraRelative) {
    vec3 normal = normalize(cross(dFdx(cameraRelative), dFdy(cameraRelative)));
    return dot(normal, cameraRelative) > 0.0 ? -normal : normal;
}

void main() {
    // Derivatives must be evaluated before any discard so that neighbouring
    // fragments in the same quad still agree on them.
    vec3 normal = geometricNormal(cameraRelativePos);

    vec4 color = (UseRgss == 1 ? sampleRGSS(Sampler0, texCoord0, 1.0f / TextureSize) : sampleNearest(Sampler0, texCoord0, 1.0f / TextureSize)) * vertexColor;
    #ifdef ALPHA_CUTOUT
    if (color.a < ALPHA_CUTOUT) {
        discard;
    }
    #endif

    #ifdef OIT_ALPHA_ONLY
    executeAlphaOnlyPhase(gl_FragCoord.z, color.a);
    #else
    const vec3 lightColor = vec3(1);
    const float shininess = 0.5;

    vec4 texColor = sampleTexture();

    // // Basic diffuse material
    // float lighting = dot(normal, normalize(vec3(1, 1, 1)));
    // lighting = (lighting + 1.0) * 0.5;   // remap from [-1,1] -> [0,1]
    // lighting = max(lighting, 0.2);       // minimum brightness

    vec3 N = normalize(normal);
    vec3 V = normalize(-cameraRelativePos);   // view direction
    vec3 L = normalize(vec3(1.0, 1.0, 1.0));  // directional light
    vec3 R = reflect(-L, N);                  // reflection vector

    // Ambient term
    float ambient = 0.2;

    // Diffuse term
    float diff = max(dot(N, L), 0.0);
    float diffuse = 0.5 * diff;

    // Specular term
    float spec = pow(max(dot(R, V), 0.0), shininess);
    float specular = 0.1 * spec;

    // Final color
    float lighting = ambient + diffuse;

    float lightmap = value(vertexColor.rgb);
    
    if (lightmap < 0.5) {
        // No sunlight
        lighting = lightmap;
    } else {
        // Blend lightmap
        lighting = mix(lighting, lightmap, 0.5);
    }

    vec3 litColor = lighting * texColor.rgb + vec3(specular);

    // lighting = mix(lightmap, mix(lighting, lightmap, 0.3), lightmap);
    fragColor = vec4(clamp(mix(vec3(lightmap * texColor.rgb), litColor, lightmap), 0.0, 1.0), vertexColor.a);
    #endif
}
