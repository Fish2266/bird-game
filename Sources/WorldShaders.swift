import SceneKit

/// Shader tweaks shared by the 0.4 open worlds.
enum WorldShaders {
    /// Ground speckle that doesn't smear down cliffs: the detail texture projected from all three sides (the plain
    /// ground mapping stretches it into streaks on anything steep).
    static func triplanarGround(_ m: SCNMaterial, extra: String = "") {
        m.diffuse.contents = WorldMaterials.whitePixel
        let detail = SCNMaterialProperty(contents: TerrainManager.detailTexture())
        detail.mipFilter = .linear
        detail.wrapS = .repeat
        detail.wrapT = .repeat
        m.setValue(detail, forKey: "detailTex")
        m.shaderModifiers = [.surface: """
        #pragma arguments
        texture2d<float> detailTex;
        #pragma body
        float3 wp = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
        float3 wn = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
        float3 bw = pow(abs(wn), float3(4.0));
        bw /= max(bw.x + bw.y + bw.z, 1e-4);
        constexpr sampler ds(filter::linear, mip_filter::linear, address::repeat);
        float tx = detailTex.sample(ds, wp.zy / 16.0).r;
        float ty = detailTex.sample(ds, wp.xz / 16.0).r;
        float tz = detailTex.sample(ds, wp.xy / 16.0).r;
        _surface.diffuse.rgb *= tx * bw.x + ty * bw.y + tz * bw.z;
        \(extra)
        """]
    }
}
