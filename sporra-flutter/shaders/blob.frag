#include <flutter/runtime_effect.glsl>
uniform vec2 size;
uniform float edge;
uniform sampler2D inputImage;
out vec4 fragColor;
void main() {
  vec4 color = texture(inputImage, FlutterFragCoord().xy / size);
  float low = max(0.05, 0.4 - edge);
  float high = min(1.0, max(low + 1.0 / 255.0, 0.4 + edge));
  float alpha = color.a == 0.0 ? 0.0 : smoothstep(low, high, color.a);
  fragColor = vec4(color.rgb * alpha / max(color.a, 0.000001), alpha);
}
