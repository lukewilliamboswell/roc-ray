#version 330

in vec2 fragTexCoord;
in vec4 fragColor;

uniform sampler2D texture0;
uniform float time;

out vec4 finalColor;

void main()
{
    vec2 uv = fragTexCoord;
    float wave = sin(uv.y * 28.0 + time * 2.0) * 0.004;
    vec4 color = texture(texture0, vec2(uv.x + wave, uv.y)) * fragColor;
    color.rgb *= 0.92 + 0.08 * sin(time + vec3(0.0, 2.1, 4.2));
    finalColor = color;
}
