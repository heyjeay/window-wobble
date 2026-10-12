cbuffer CB : register(b0) { float2 origin; float2 size; };
struct VSIn  { float2 pos : POSITION; float2 uv : TEXCOORD; };
struct VSOut { float4 pos : SV_POSITION; float2 uv : TEXCOORD; };
Texture2D    tex : register(t0);
SamplerState smp : register(s0);

VSOut VS(VSIn i) {
    VSOut o;
    // Surface pixels -> NDC. origin is the surface's top-left in screen
    // coordinates; mesh vertices are in screen coordinates.
    float2 n = (i.pos - origin) / size * 2.0 - 1.0;
    o.pos = float4(n.x, -n.y, 0, 1);
    o.uv  = i.uv;
    return o;
}
float4 PS(VSOut i) : SV_TARGET {
    float4 c = tex.Sample(smp, i.uv);
    return float4(c.rgb * c.a, c.a);   // swapchain is premultiplied alpha
}
