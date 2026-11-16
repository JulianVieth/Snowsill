// Compiled at runtime via makeLibrary(source:) because the Command Line Tools ship no offline Metal compiler.
enum Shaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct FlakeInstance {
        float2 position;
        float radius;
        float opacity;
    };

    struct FlakeVertexOut {
        float4 position [[position]];
        float2 uv;
        float opacity;
    };

    vertex FlakeVertexOut flakeVertex(uint vid [[vertex_id]],
                                      uint iid [[instance_id]],
                                      const device FlakeInstance *flakes [[buffer(0)]],
                                      constant float2 &viewSize [[buffer(1)]]) {
        float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
        FlakeInstance flake = flakes[iid];
        float2 p = flake.position + corner * flake.radius;
        FlakeVertexOut out;
        out.position = float4(p / viewSize * 2.0 - 1.0, 0.0, 1.0);
        out.uv = corner;
        out.opacity = flake.opacity;
        return out;
    }

    // Soft white disc with a faint bluish rim so flakes stay visible on white windows.
    fragment float4 flakeFragment(FlakeVertexOut in [[stage_in]]) {
        float d = length(in.uv);
        if (d >= 1.0) { discard_fragment(); }
        float3 color;
        float alpha;
        if (d < 0.55) {
            float t = d / 0.55;
            color = mix(float3(1.0), float3(0.95, 0.97, 1.0), t);
            alpha = mix(1.0, 0.85, t);
        } else {
            float t = (d - 0.55) / 0.45;
            color = mix(float3(0.95, 0.97, 1.0), float3(0.75, 0.82, 0.95), t);
            alpha = mix(0.85, 0.0, t);
        }
        alpha *= in.opacity;
        return float4(color * alpha, alpha);
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
