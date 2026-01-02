#version 100

precision mediump float;
attribute vec3 vertexPosition;
attribute vec2 vertexTexCoord;
attribute vec4 vertexColor;

varying vec2 fragTexCoord;
varying vec4 fragColor;
varying vec2 fragPos;
uniform mat4 mvp;
uniform vec2 center;
uniform float time;
uniform float max;
const float PI = 3.14159;
const float maxRotation = 2.0 * PI;
void main()
{
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragPos = vertexPosition.xy;

    float amp = max - 1.0;
    float time_ = smoothstep(0.0, 1.0, time);
    float oscillation = abs(cos(time_ * 3.0 * PI));
    float envelope = pow(clamp(1.0 - time_, 0.0, 1.0), 2.0);
    float scale = 1. + oscillation * amp * envelope;
    float angle = maxRotation * envelope;
    float c = cos(angle);
    float s = sin(angle);
    vec2 p = fragPos - center;
    p *= scale;
    p = vec2(
	p.x * c - p.y * s,
	p.x * s + p.y * c
    );
    vec2 finalPos = p + center;

    gl_Position = mvp * vec4(finalPos, 0.0, 1.0);
}
