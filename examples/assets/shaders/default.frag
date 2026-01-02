#version 100
precision mediump float;
varying vec2 fragTexCoord;
varying vec4 fragColor;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
void main()
{
    gl_FragColor = fragColor * vec4(texture2D(texture0, fragTexCoord));
}
