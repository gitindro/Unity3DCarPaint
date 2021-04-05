#ifndef LIGHTWEIGHT_SIMPLE_LIT_INPUT_INCLUDED
#define LIGHTWEIGHT_SIMPLE_LIT_INPUT_INCLUDED

//#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/SurfaceInput.hlsl"

CBUFFER_START(UnityPerMaterial)
float4 _BaseMap_ST;
float4 _BumpMap_ST;
float4 _FlakeMap_ST;
float4 _EnvMap_ST;
float4 _SpecGlossMap_ST;
half4 _BaseColor;
half4 _MidColor;
half4 _TopColor;
half4 _FlakeColor;
half4 _SpecColor;
half4 _EmissionColor;
half _Cutoff;
CBUFFER_END

//TEXTURE2D(_BaseMap);  SAMPLER(sampler_BaseMap);
TEXTURE2D(_SpecGlossMap);  SAMPLER(sampler_SpecGlossMap);
TEXTURE2D(_FlakeMap);  SAMPLER(sampler_FlakeMap);
TEXTURECUBE(_EnvMap);  SAMPLER(sampler_EnvMap);




half4 SampleSpecularSmoothness(half2 uv, half alpha, half4 specColor, TEXTURE2D_PARAM(specMap, sampler_specMap))
{
    half4 specularSmoothness = half4(0.0h, 0.0h, 0.0h, 1.0h);

    specularSmoothness = SAMPLE_TEXTURE2D(specMap, sampler_specMap, uv) * specColor;

#ifdef _GLOSSINESS_FROM_BASE_ALPHA
    specularSmoothness.a = exp2(10 * alpha + 1);
#else
    specularSmoothness.a = exp2(10 * specularSmoothness.a + 1);
#endif

    return specularSmoothness;
}

#endif
