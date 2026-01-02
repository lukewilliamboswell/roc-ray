#version 100
precision mediump float;
varying vec2 fragTexCoord;
varying vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform float time;
uniform float frequency;
uniform float amplitude;

void main()
{
    vec4 texelColor = texture2D(texture0, fragTexCoord);
    float f = frequency;
    vec2 uv = fragTexCoord - 0.5;
    float dist = length(uv);
    float ripple = sin(dist * frequency * 10.0 - time * 4.0) * amplitude;

    vec2 distortedUV = fragTexCoord + normalize(uv) * ripple;
    gl_FragColor = colDiffuse * texture2D(texture0, distortedUV);
}
