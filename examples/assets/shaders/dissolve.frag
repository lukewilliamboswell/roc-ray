#version 100
precision mediump float;

varying vec2 fragTexCoord;
varying vec4 fragColor;

uniform sampler2D texture0;   // sprite
uniform sampler2D noiseTex;   // grayscale noise
uniform float progress;       // 0.0 = intact, 1.0 = gone
uniform float softness;       // edge softness (0.0–0.2 typical)

void main()
{
    vec4 sprite = texture2D(texture0, fragTexCoord);
    float noise = texture2D(noiseTex, fragTexCoord).r;

    // Dissolve threshold
    float edge = smoothstep(
        progress - softness,
        progress + softness,
        noise
    );

    // Kill fully dissolved pixels
    if (edge <= 0.0 || sprite.a <= 0.0)
        discard;

    gl_FragColor = vec4(sprite.rgb, sprite.a * edge) * fragColor;
}
