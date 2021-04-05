#ifndef CARPAINT_FORWARD_PASS_INCLUDED
#define CARPAINT_FORWARD_PASS_INCLUDED

#include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
#include "Packages/com.unity.render-pipelines.core/ShaderLibrary/Common.hlsl"
struct Attributes
{
    float4 positionOS    : POSITION;
    float3 normalOS      : NORMAL;
    float4 tangentOS     : TANGENT;
    float2 texcoord      : TEXCOORD0;
    float2 lightmapUV    : TEXCOORD1;
    UNITY_VERTEX_INPUT_INSTANCE_ID
};

struct PaintInputData
{
	float3  positionWS;
	half3   normalWS;
	half3   viewDirectionWS;
	float4  shadowCoord;
	half    fogCoord;
	half3   vertexLighting;
	half3   bakedGI;
};

struct Varyings
{
    float2 uv                       : TEXCOORD0;
    DECLARE_LIGHTMAP_OR_SH(lightmapUV, vertexSH, 1);

    float3 posWS                    : TEXCOORD2;    // xyz: posWS

//#ifdef _NORMALMAP
    half4 normal                    : TEXCOORD3;    // xyz: normal, w: viewDir.x
    half4 tangent                   : TEXCOORD4;    // xyz: tangent, w: viewDir.y
    half4 bitangent                  : TEXCOORD5;    // xyz: bitangent, w: viewDir.z
//#else
//    half3  normal                   : TEXCOORD3;
//    half3 viewDir                   : TEXCOORD4;
//#endif

    half4 fogFactorAndVertexLight   : TEXCOORD6; // x: fogFactor, yzw: vertex light

#ifdef _MAIN_LIGHT_SHADOWS
    float4 shadowCoord              : TEXCOORD7;
#endif

	half3 SparkelTex				: TEXCOORD8;

    float4 positionCS               : SV_POSITION;
    UNITY_VERTEX_INPUT_INSTANCE_ID
    UNITY_VERTEX_OUTPUT_STEREO
};

void InitializeInputData(Varyings input, half3 normalTS, out InputData inputData)
{
    inputData.positionWS = input.posWS;

    half3 viewDirWS = half3(input.normal.w, input.tangent.w, input.bitangent.w);
	half3x3 tangentToworld = transpose(half3x3(input.tangent.xyz, input.bitangent.xyz, input.normal.xyz));
    inputData.normalWS = SafeNormalize(mul(tangentToworld, normalTS));

    viewDirWS = SafeNormalize(viewDirWS);

    inputData.viewDirectionWS = viewDirWS;

#if defined(_MAIN_LIGHT_SHADOWS) && !defined(_RECEIVE_SHADOWS_OFF)
    inputData.shadowCoord = input.shadowCoord;
#else
    inputData.shadowCoord = float4(0, 0, 0, 0);
#endif
    inputData.fogCoord = input.fogFactorAndVertexLight.x;
    inputData.vertexLighting = input.fogFactorAndVertexLight.yzw;
    inputData.bakedGI = SAMPLE_GI(input.lightmapUV, input.vertexSH, inputData.normalWS);

}

///////////////////////////////////////////////////////////////////////////////
//                  Vertex and Fragment functions                            //
///////////////////////////////////////////////////////////////////////////////

// Used in car paint shader
Varyings CarPaint_VertexSimple(Attributes input)
{
    Varyings output = (Varyings)0;

    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_TRANSFER_INSTANCE_ID(input, output);
    UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(output);

    VertexPositionInputs vertexInput = GetVertexPositionInputs(input.positionOS.xyz);
    VertexNormalInputs normalInput = GetVertexNormalInputs(input.normalOS, input.tangentOS);
    half3 viewDirWS = GetCameraPositionWS() - vertexInput.positionWS;
    half3 vertexLight = VertexLighting(vertexInput.positionWS, normalInput.normalWS);
    half fogFactor = ComputeFogFactor(vertexInput.positionCS.z);

    output.uv = TRANSFORM_TEX(input.texcoord, _BumpMap);

	float2 f2 = TRANSFORM_TEX((input.texcoord * 20.0), _FlakeMap);
	output.SparkelTex.xy = f2.xy;
    output.posWS.xyz = vertexInput.positionWS;
    output.positionCS = vertexInput.positionCS;

    output.normal = half4(normalInput.normalWS, viewDirWS.x);
    output.tangent = half4(normalInput.tangentWS, viewDirWS.y);
    output.bitangent = half4(normalInput.bitangentWS, viewDirWS.z);

	OUTPUT_LIGHTMAP_UV(input.lightmapUV, unity_LightmapST, output.lightmapUV);
    OUTPUT_SH(output.normal.xyz, output.vertexSH);

    output.fogFactorAndVertexLight = half4(fogFactor, vertexLight);

#if defined(_MAIN_LIGHT_SHADOWS) && !defined(_RECEIVE_SHADOWS_OFF)
    output.shadowCoord = GetShadowCoord(vertexInput);
#endif

    return output;
}

half4 CarpaintFragmentBlinnPhong(PaintInputData inputData, half3 np1, half3 np2, half4 specularGloss, half smoothness, half4 paintColor0,
	half4 paintColormid, half4 paintColor2, half4 flakeLayerColor, float3x3 tangentToworld)
{
	Light mainLight = GetMainLight(inputData.shadowCoord);
	MixRealtimeAndBakedGI(mainLight, inputData.normalWS, inputData.bakedGI, half4(0, 0, 0, 0));

	half3 attenuatedLightColor = mainLight.color * (mainLight.distanceAttenuation * mainLight.shadowAttenuation);
	half3 diffuseColor = inputData.bakedGI + LightingLambert(attenuatedLightColor, mainLight.direction, inputData.normalWS);
	half3 specularColor = LightingSpecular(attenuatedLightColor, mainLight.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, smoothness);

	float3 viewWS = normalize(inputData.viewDirectionWS);
	// Compute reflection vector resulted from the clear coat of paint on the metallic
   // surface:
	float fNDotV = saturate(dot(inputData.normalWS, -viewWS));

	float3 vRef = reflect(-viewWS, inputData.normalWS);

	// Here we just use a constant gloss value to bias reading from the environment
	// map, however, in the real demo we use a gloss map which specifies which 
	// regions will have reflection slightly blurred.
	float glossLevel = 0.1;
	float fEnvBias = glossLevel;
	float4 envMap = SAMPLE_TEXTURECUBE_LOD(_EnvMap, sampler_EnvMap, vRef, 0);
	
	envMap.rgb = envMap.rgb * envMap.a;

	float brightnessFactor = 0.2f;
	envMap.rgb *= brightnessFactor;
#ifdef _ADDITIONAL_LIGHTS
	//int pixelLightCount = GetAdditionalLightsCount();
	//for (int i = 0; i < pixelLightCount; ++i)
	//{
	//	Light light = GetAdditionalLight(i, inputData.positionWS);
	//	half3 attenuatedLightColor = light.color * (light.distanceAttenuation * light.shadowAttenuation);
	//	diffuseColor += LightingLambert(attenuatedLightColor, light.direction, inputData.normalWS);
	//	specularColor += LightingSpecular(attenuatedLightColor, light.direction, inputData.normalWS, inputData.viewDirectionWS, specularGloss, smoothness);
	//}
#endif

	// Compute modified Fresnel term for reflections from the first layer of
	// microflakes. First transform perturbed surface normal for that layer into 
	// world space and then compute dot product of that normal with the view vector:
	float3 vNp1World = normalize(mul(tangentToworld, np1));
	float  fFresnel1 = saturate(dot(vNp1World, viewWS));

	// Compute modified Fresnel term for reflections from the second layer of 
	// microflakes. Again, transform perturbed surface normal for that layer into 
	// world space and then compute dot product of that normal with the view vector:
	float3 vNp2World = normalize(mul(tangentToworld, np2 ));
	float  fFresnel2 = saturate(dot(vNp2World, viewWS));

	//
	// Compute final paint color: combines all layers of paint as well as two layers
	// of microflakes
	float  fFresnel1Sq = fFresnel1 * fFresnel1;

	float4 paintColor = fFresnel1 * paintColor0 + fFresnel1Sq * paintColormid + fFresnel1Sq * fFresnel1Sq * paintColor2 + pow(fFresnel2, 16) * flakeLayerColor*0.8;

	// Combine result of environment map reflection with the paint color:
	float  fEnvContribution = 1.0 - 0.5 * fNDotV;

	float4 finalColor;
	finalColor.a = 1.0;

	finalColor.rgb = (envMap.rgb * fEnvContribution + paintColor.rgb) * (diffuseColor.rgb) ;

	float alpha = 1;

	return half4(finalColor);
}

// Used for StandardSimpleLighting shader
half4 CarPaint_FragmentSimple(Varyings input) : SV_Target
{
    UNITY_SETUP_INSTANCE_ID(input);
    UNITY_SETUP_STEREO_EYE_INDEX_POST_VERTEX(input);

    float2 uv = input.uv;
	float2 uvSparkelTex = input.SparkelTex.xy;

    half alpha = _BaseColor.a;


	float microflakePerturbation =0.1;
	float microflakePerturbationA = 1.0;
	float normalPerturbation = 1.0;

    half3 vnormal = SampleNormal(uv, TEXTURE2D_ARGS(_BumpMap, sampler_BumpMap));


	half3 fknormal = SampleNormal(uvSparkelTex, TEXTURE2D_ARGS(_FlakeMap, sampler_FlakeMap));
	fknormal = normalize(fknormal);

	// This shader simulates two layers of microflakes suspended in 
	// the coat of paint. To compute the surface normal for the first layer,
	// the following formula is used: 
	//   Np1 = ( a * Np + b * N ) /  || a * Np + b * N || where a << b
	//

	half3 np1 = microflakePerturbationA * fknormal + normalPerturbation * vnormal;
	half3 np2 = microflakePerturbation * (fknormal + vnormal);

    half4 specular = SampleSpecularSmoothness(uv, alpha, _SpecColor, TEXTURE2D_ARGS(_SpecGlossMap, sampler_BaseMap));
    half smoothness = specular.a;

    PaintInputData inputData;
    InitializeInputData(input, vnormal, inputData);

	//_BaseColor("Base layer Color", Color) = (0.5, 0.5, 0.5, 1)
	//_MidColor("Middle layer Color", Color) = (0.5, 0.5, 0.5, 1)
	//_TopColor("Top layer Color", Color) = (0.5, 0.5, 0.5, 1)
	//_FlakeColor("Flake layer Color", Color) = (0.5, 0.5, 0.5, 1)

	half4 paintcolor1		= _BaseColor;
	half4 paintcolormid		= _MidColor;
	half4 paintcolor2		= _TopColor;
	half4 paintcolorflake	= _FlakeColor;

	float3x3 tangentToworld = transpose(float3x3(input.tangent.xyz, input.bitangent.xyz, input.normal.xyz));

    half4 color = CarpaintFragmentBlinnPhong(inputData, np1, np2, 
		specular, smoothness, paintcolor1, paintcolormid, paintcolor2, paintcolorflake, tangentToworld);


	return  float4(color.xyz, 1);
};

#endif
