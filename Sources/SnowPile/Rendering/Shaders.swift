// Compiled at runtime via makeLibrary(source:) because the Command Line Tools ship no offline Metal compiler.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    // Must match `Sprite` in SnowPileCore/Rendering/Sprites.swift.
    struct Sprite {
        float2 position;
        float2 size;
        float4 color;
        float rotation;
        float shape;
        float seed;
        float param;
    };

    struct SpriteOut {
        float4 position [[position]];
        float2 local;
        float2 size;
        float4 color;
        float shape;
        float seed;
        float param;
    };

    // Unit quad around each sprite, padded by a point so anti-aliased edges aren't cut off.
    vertex SpriteOut spriteVertex(uint vid [[vertex_id]],
                                  uint iid [[instance_id]],
                                  const device Sprite *sprites [[buffer(0)]],
                                  constant float2 &viewSize [[buffer(1)]]) {
        Sprite s = sprites[iid];
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        float2 local = corner * (s.size + 1.0);
        float c = cos(s.rotation), sn = sin(s.rotation);
        float2 rotated = float2(local.x * c - local.y * sn, local.x * sn + local.y * c);
        float2 p = s.position + rotated;
        SpriteOut out;
        out.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.local = local;
        out.size = s.size;
        out.color = s.color;
        out.shape = s.shape;
        out.seed = s.seed;
        out.param = s.param;
        return out;
    }

    // Coverage from a signed distance in points (negative inside).
    static inline float coverage(float d) { return clamp(0.5 - d * 1.6, 0.0, 1.0); }

    static inline float4 premultiplied(float3 color, float alpha) { return float4(color * alpha, alpha); }

    static inline float hash11(float x) { return fract(sin(x * 127.1) * 43758.5453); }

    // Snow shading for blobs: light from the upper left, bluish in the shade.
    static inline float3 snowShade(float2 q) {
        float lit = clamp(0.55 + 0.45 * dot(normalize(q + float2(0.0001)), normalize(float2(-0.7, 0.7))) * min(length(q) * 1.4, 1.0), 0.0, 1.0);
        return mix(float3(0.72, 0.79, 0.92), float3(1.0), lit);
    }

    fragment float4 spriteFragment(SpriteOut in [[stage_in]]) {
        int shape = int(in.shape + 0.5);
        float2 q = in.local / in.size;
        float r = length(q);
        float alpha = in.color.a;

        if (shape == 0) {
            // Soft white flake with a faint bluish rim so it stays visible on white windows.
            if (r >= 1.0) { discard_fragment(); }
            float3 color; float a;
            if (r < 0.55) {
                float t = r / 0.55;
                color = mix(float3(1.0), float3(0.95, 0.97, 1.0), t);
                a = mix(1.0, 0.85, t);
            } else {
                float t = (r - 0.55) / 0.45;
                color = mix(float3(0.95, 0.97, 1.0), float3(0.75, 0.82, 0.95), t);
                a = mix(0.85, 0.0, t);
            }
            return premultiplied(color, a * alpha);
        }
        if (shape == 1) {
            // Clump: lumpy outline from a few sines seeded per particle.
            float angle = atan2(q.y, q.x);
            float s = in.seed * 40.0;
            float outline = 0.86 + 0.08 * sin(3.0 * angle + s) + 0.05 * sin(5.0 * angle + s * 1.7) + 0.04 * sin(8.0 * angle + s * 2.3);
            float d = (r - outline) * in.size.x;
            float a = coverage(d);
            if (a <= 0.0) { discard_fragment(); }
            return premultiplied(snowShade(q), a * alpha);
        }
        if (shape == 2) {
            // Snowball: shaded sphere with a little surface texture.
            float d = (r - 1.0) * in.size.x;
            float a = coverage(d);
            if (a <= 0.0) { discard_fragment(); }
            float2 qc = q / max(r, 1.0);
            float z = sqrt(max(1.0 - dot(qc, qc), 0.0));
            float3 n = float3(qc, z);
            float diffuse = max(dot(n, normalize(float3(-0.45, 0.55, 0.7))), 0.0);
            float grain = hash11(floor(in.local.x * 0.9) * 13.0 + floor(in.local.y * 0.9) * 71.0 + in.seed * 97.0);
            float3 color = mix(float3(0.62, 0.70, 0.86), float3(1.0), pow(diffuse, 0.75));
            color *= 0.97 + 0.03 * grain;
            return premultiplied(min(color, float3(1.0)), a * alpha);
        }
        if (shape == 3) {
            float a = coverage(length(in.local) - in.size.x);
            if (a <= 0.0) { discard_fragment(); }
            return premultiplied(in.color.rgb, a * alpha);
        }
        if (shape == 4) {
            float radius = min(in.param, min(in.size.x, in.size.y));
            float2 b = abs(in.local) - in.size + radius;
            float d = length(max(b, 0.0)) + min(max(b.x, b.y), 0.0) - radius;
            float a = coverage(d);
            if (a <= 0.0) { discard_fragment(); }
            return premultiplied(in.color.rgb, a * alpha);
        }
        if (shape == 5) {
            // Triangle pointing to +x.
            float t = clamp((in.size.x - in.local.x) / (2.0 * in.size.x), 0.0, 1.0);
            float halfWidth = in.size.y * t;
            float d = max(abs(in.local.y) - halfWidth, max(-in.size.x - in.local.x, in.local.x - in.size.x));
            float a = coverage(d * 0.8);
            if (a <= 0.0) { discard_fragment(); }
            // Slight shading across, so a carrot reads as round.
            float shade = 0.85 + 0.15 * (1.0 - abs(in.local.y) / max(halfWidth, 0.001));
            return premultiplied(in.color.rgb * shade, a * alpha);
        }
        if (shape == 6) {
            // Icicle: hangs from the top edge, tapers to a point at the bottom, glassy with a highlight.
            float t = clamp((in.local.y + in.size.y) / (2.0 * in.size.y), 0.0, 1.0);
            float wobble = 1.0 + 0.12 * sin(in.local.y * 0.9 + in.seed * 30.0);
            float halfWidth = in.size.x * pow(t, 0.8) * wobble;
            float d = max(abs(in.local.x) - halfWidth, max(-in.size.y - in.local.y, in.local.y - in.size.y));
            float a = coverage(d);
            if (a <= 0.0) { discard_fragment(); }
            float across = in.local.x / max(halfWidth, 0.001);
            float highlight = smoothstep(-0.7, -0.2, across) * (1.0 - smoothstep(-0.2, 0.2, across));
            float3 color = mix(in.color.rgb * 0.88, float3(1.0), highlight * 0.8);
            return premultiplied(color, a * alpha * (0.75 + 0.25 * highlight));
        }
        if (shape == 7) {
            // Mound: upper half of an ellipse standing on the bottom of the quad, with a lumpy top.
            float2 m = float2(q.x, (q.y + 1.0) * 0.5);
            float bump = 0.06 * sin(q.x * 9.0 + in.seed * 20.0) + 0.04 * sin(q.x * 17.0 + in.seed * 7.0);
            float d = (length(m) - (1.0 + bump)) * min(in.size.x, in.size.y * 2.0);
            d = max(d, -m.y * in.size.y * 2.0);
            float a = coverage(d);
            if (a <= 0.0) { discard_fragment(); }
            float3 color = mix(float3(0.76, 0.82, 0.94), float3(1.0), clamp(m.y * 1.3 - q.x * 0.2 + 0.2, 0.0, 1.0));
            return premultiplied(color, a * alpha);
        }
        discard_fragment();
        return float4(0.0);
    }

    struct SurfaceVertex {
        float2 position;
        float4 color;
    };

    struct SurfaceVertexOut {
        float4 position [[position]];
        float4 color;
    };

    vertex SurfaceVertexOut surfaceVertex(uint vid [[vertex_id]],
                                          const device SurfaceVertex *vertices [[buffer(0)]],
                                          constant float2 &viewSize [[buffer(1)]]) {
        SurfaceVertex v = vertices[vid];
        SurfaceVertexOut out;
        out.position = float4(v.position / viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.color = v.color;
        return out;
    }

    fragment float4 surfaceFragment(SurfaceVertexOut in [[stage_in]]) {
        return in.color;
    }
    """
}
