//*********************************************************
//
// Copyright (c) Microsoft. All rights reserved.
// This code is licensed under the MIT License (MIT).
// THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF
// ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING ANY
// IMPLIED WARRANTIES OF FITNESS FOR A PARTICULAR
// PURPOSE, MERCHANTABILITY, OR NON-INFRINGEMENT.
//
//*********************************************************

#ifndef PATHTRACER_HLSL
#define PATHTRACER_HLSL

// Remove /Zpr and use column-major? It might be slightly faster

#define HLSL
#include "RaytracingHlslCompat.h"
#include "RaytracingShaderHelper.hlsli"
#include "RandomNumberGenerator.hlsli"
#include "AnalyticalTextures.hlsli"
#include "BxDF.hlsli"

//***************************************************************************
//*****------ Shader resources bound via root signatures -------*************
//***************************************************************************

//  g_* - bound via a global root signature.
//  l_* - bound via a local root signature.
RaytracingAccelerationStructure g_scene : register(t0, space0);

RWTexture2D<float4> g_rtGBufferPosition : register(u7);
RWTexture2D<NormalDepthTexFormat> g_rtGBufferNormalDepth : register(u8);
RWTexture2D<float> g_rtGBufferDepth : register(u9);

RWTexture2D<float2> g_rtTextureSpaceMotionVector : register(u17);
RWTexture2D<NormalDepthTexFormat> g_rtReprojectedNormalDepth : register(u18);
RWTexture2D<float4> g_rtColor : register(u19);
RWTexture2D<float4> g_rtAOSurfaceAlbedo : register(u20);
RWTexture2D<float4> g_outDebug1 : register(u21);
RWTexture2D<float4> g_outDebug2 : register(u22);
RWTexture2D<float4> g_rtAccumulator : register(u23);

TextureCube<float4> g_texEnvironmentMap : register(t12);
Texture2D<float4> g_texUVChecker : register(t13);
ConstantBuffer<PathtracerConstantBuffer> g_cb : register(b0);
StructuredBuffer<PrimitiveMaterialBuffer> g_materials : register(t3);
StructuredBuffer<AlignedHemisphereSample3D> g_sampleSets : register(t4);
StructuredBuffer<float3x4> g_prevFrameBottomLevelASInstanceTransform : register(t15);

SamplerState LinearWrapSampler : register(s0);


/*******************************************************************************************************/
// Per-object resources bound via a local root signature.
ConstantBuffer<PrimitiveConstantBuffer> l_materialCB : register(b0, space1);

StructuredBuffer<Index> l_indices : register(t0, space1);
StructuredBuffer<VertexPositionNormalTextureTangent> l_vertices : register(t1, space1);             // Current frame vertex buffer.
StructuredBuffer<VertexPositionNormalTextureTangent> l_verticesPrevFrame : register(t2, space1); 

Texture2D<float3> l_texDiffuse : register(t3, space1);
Texture2D<float3> l_texNormalMap : register(t4, space1);
/*******************************************************************************************************/

// Delayed include to resolve resource references
#include "MotionVector.hlsli"

#define TWO_PI (3.141592653 * 2)
#define ONE_OVER_PI ( 1.0f / 3.141592653)
#define FLT_MAX 3.402823466e+38F

// Switches between two RNGs
#define USE_PCG 1

// Conversion between linear and sRGB color spaces
inline float linearToSrgb(float linearColor)
{
	if (linearColor < 0.0031308f) return linearColor * 12.92f;
	else return 1.055f * float(pow(linearColor, 1.0f / 2.4f)) - 0.055f;
}

float3 linearToSrgb(float3 linearColor)
{
	return float3(linearToSrgb(linearColor.x), linearToSrgb(linearColor.y),linearToSrgb(linearColor.z));
}

inline float srgbToLinear(float srgbColor)
{
	if (srgbColor < 0.04045f) return srgbColor / 12.92f;
	else return float(pow((srgbColor + 0.055f) / 1.055f, 2.4f));
}

 // -------------------------------------------------------------------------
 //    RNG
 // -------------------------------------------------------------------------

#if USE_PCG
	#define RngStateType uint4
#else
	#define RngStateType uint
#endif

// PCG random numbers generator
// Source: "Hash Functions for GPU Rendering" by Jarzynski & Olano
uint4 pcg4d(uint4 v)
{
	v = v * 1664525u + 1013904223u;

	v.x += v.y * v.w; 
	v.y += v.z * v.x; 
	v.z += v.x * v.y; 
	v.w += v.y * v.z;

	v = v ^ (v >> 16u);

	v.x += v.y * v.w; 
	v.y += v.z * v.x; 
	v.z += v.x * v.y; 
	v.w += v.y * v.z;

	return v;
}

// 32-bit Xorshift random number generator
uint xorshift(inout uint rngState)
{
	rngState ^= rngState << 13;
	rngState ^= rngState >> 17;
	rngState ^= rngState << 5;
	return rngState;
}

// Jenkins's "one at a time" hash function
uint jenkinsHash(uint x) {
	x += x << 10;
	x ^= x >> 6;
	x += x << 3;
	x ^= x >> 11;
	x += x << 15;
	return x;
}

// Converts unsigned integer into float int range <0; 1) by using 23 most significant bits for mantissa
float uintToFloat(uint x) {
	return asfloat(0x3f800000 | (x >> 9)) - 1.0f;
}

#if USE_PCG

// Initialize RNG for given pixel, and frame number (PCG version)
RngStateType initRNG(uint2 pixelCoords, uint2 resolution, uint frameNumber) {
	return RngStateType(pixelCoords.xy, frameNumber, 0); //< Seed for PCG uses a sequential sample number in 4th channel, which increments on every RNG call and starts from 0
}

// Return random float in <0; 1) range  (PCG version)
float rand(inout RngStateType rngState) {
	rngState.w++; //< Increment sample index
	return uintToFloat(pcg4d(rngState).x);
}

#else

// Initialize RNG for given pixel, and frame number (Xorshift-based version)
RngStateType initRNG(uint2 pixelCoords, uint2 resolution, uint frameNumber) {
	RngStateType seed = dot(pixelCoords, uint2(1, resolution.x)) ^ jenkinsHash(frameNumber);
	return jenkinsHash(seed);
}

// Return random float in <0; 1) range (Xorshift-based version)
float rand(inout RngStateType rngState) {
	return uintToFloat(xorshift(rngState));
}

#endif

// Maps integers to colors using the hash function (generates pseudo-random colors)
float3 hashAndColor(int i) {
	uint hash = jenkinsHash(i);
	float r = ((hash >> 0) & 0xFF) / 255.0f;
	float g = ((hash >> 8) & 0xFF) / 255.0f;
	float b = ((hash >> 16) & 0xFF) / 255.0f;
	return float3(r, g, b);
}
/*******************************************************************************************************/

// Samples a direction within a hemisphere oriented along +Z axis with a cosine-weighted distribution 
// Source: "Sampling Transformations Zoo" in Ray Tracing Gems by Shirley et al.
float3 sampleHemisphere(float2 u, out float pdf) {

	float a = sqrt(u.x);
	float b = TWO_PI * u.y;

	float3 result = float3(
		a * cos(b),
		a * sin(b),
		sqrt(1.0f - u.x));

	pdf = result.z * ONE_OVER_PI;

	return result;
}

float3 sampleHemisphere(float2 u) {
	float pdf;
	return sampleHemisphere(u, pdf);
}

// For sampling of all our diffuse BRDFs we use cosine-weighted hemisphere sampling, with PDF equal to (NdotL/PI)
float diffusePdf(float NdotL) {
	return NdotL * ONE_OVER_PI;
}


/*******************************************************************************************************/
// -------------------------------------------------------------------------
//    Quaternion rotations
// -------------------------------------------------------------------------

// Calculates rotation quaternion from input vector to the vector (0, 0, 1)
// Input vector must be normalized!
float4 getRotationToZAxis(float3 input) {

	// Handle special case when input is exact or near opposite of (0, 0, 1)
	if (input.z < -0.99999f) return float4(1.0f, 0.0f, 0.0f, 0.0f);

	return normalize(float4(input.y, -input.x, 0.0f, 1.0f + input.z));
}

// Calculates rotation quaternion from vector (0, 0, 1) to the input vector
// Input vector must be normalized!
float4 getRotationFromZAxis(float3 input) {

	// Handle special case when input is exact or near opposite of (0, 0, 1)
	if (input.z < -0.99999f) return float4(1.0f, 0.0f, 0.0f, 0.0f);

	return normalize(float4(-input.y, input.x, 0.0f, 1.0f + input.z));
}

// Returns the quaternion with inverted rotation
float4 invertRotation(float4 q)
{
	return float4(-q.x, -q.y, -q.z, q.w);
}

// Optimized point rotation using quaternion
// Source: https://gamedev.stackexchange.com/questions/28395/rotating-vector3-by-a-quaternion
float3 rotatePoint(float4 q, float3 v) {
	const float3 qAxis = float3(q.x, q.y, q.z);
	return 2.0f * dot(qAxis, v) * qAxis + (q.w * q.w - dot(qAxis, qAxis)) * v + 2.0f * q.w * cross(qAxis, v);
}

/*******************************************************************************************************/
float3 SampleGradient3SkyColor(float3 rayDir)
{
	float3 skyColor = float3(0.5,0.5,0.86);
    float3 midColor = float3(0.5,0.5,0.5);
    float3 groundColor = float3(0.1,0.1,0.2);
	float3 color = 0.0f;
    float height = normalize(rayDir).y;
    if (height > 0)
    {
    	color = lerp(midColor, skyColor, height);
    }
    else
    {
	    color = lerp(midColor, groundColor, abs(height));
    }
    return color;
}

// Trace a shadow ray and return true if it hits any geometry.
bool TraceShadowRayAndReportIfHit(out float tHit, in Ray ray, in UINT currentRayRecursionDepth, in bool retrieveTHit = true, in float TMax = 10000)
{
    if (currentRayRecursionDepth >= g_cb.maxShadowRayRecursionDepth)
    {
        return false;
    }

    // Set the ray's extents.
    RayDesc rayDesc;
    rayDesc.Origin = ray.origin;
    rayDesc.Direction = ray.direction;
    rayDesc.TMin = 0.0;
	rayDesc.TMax = TMax;

    // Initialize shadow ray payload.
    // Set the initial value to a hit at TMax. 
    // Miss shader will set it to HitDistanceOnMiss.
    // This way closest and any hit shaders can be skipped if true tHit is not needed. 
    ShadowRayPayload shadowPayload = { TMax };

    UINT rayFlags = RAY_FLAG_CULL_NON_OPAQUE;             // ~skip transparent objects
    bool acceptFirstHit = !retrieveTHit;
    if (acceptFirstHit)
    {
        // Performance TIP: Accept first hit if true hit is not neeeded,
        // or has minimal to no impact. The peformance gain can
        // be substantial.
        rayFlags |= RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH;
    }

    // Skip closest hit shaders of tHit time is not needed.
    if (!retrieveTHit) 
    {
        rayFlags |= RAY_FLAG_SKIP_CLOSEST_HIT_SHADER; 
    }

    TraceRay(g_scene,
        rayFlags,
        TraceRayParameters::InstanceMask,
        TraceRayParameters::HitGroup::Offset[PathtracerRayType::Shadow],
        TraceRayParameters::HitGroup::GeometryStride,
        TraceRayParameters::MissShader::Offset[PathtracerRayType::Shadow],
        rayDesc, shadowPayload);
    
    // Report a hit if Miss Shader didn't set the value to HitDistanceOnMiss.
    tHit = shadowPayload.tHit;

    return shadowPayload.tHit > 0;
}

bool TraceShadowRayAndReportIfHit(out float tHit, in Ray ray, in float3 N, in UINT currentRayRecursionDepth, in bool retrieveTHit = true, in float TMax = 10000)
{
    // Only trace if the surface is facing the target.
    if (dot(ray.direction, N) > 0)
    {
        return TraceShadowRayAndReportIfHit(tHit, ray, currentRayRecursionDepth, retrieveTHit, TMax);
    }
    return false;
}

bool TraceShadowRayAndReportIfHit(in float3 hitPosition, in float3 direction, in float3 N, in PathtracerRayPayload rayPayload, in float TMax = 10000)
{
    float tOffset = 0.001f;
    Ray visibilityRay = { hitPosition + tOffset * N, direction };
    float dummyTHit;   
    return TraceShadowRayAndReportIfHit(dummyTHit, visibilityRay, N, rayPayload.rayRecursionDepth, false, TMax);
}

PathtracerRayPayload TraceRadianceRay(in Ray ray, in UINT currentRayRecursionDepth, float tMin = NEAR_PLANE, float tMax = FAR_PLANE, float bounceContribution = 1, bool cullNonOpaque = false)
{
    PathtracerRayPayload rayPayload;
    rayPayload.rayRecursionDepth = currentRayRecursionDepth + 1;
    rayPayload.radiance = 0;
    rayPayload.AOGBuffer.tHit = HitDistanceOnMiss;
    rayPayload.AOGBuffer.hitPosition = 0;
    rayPayload.AOGBuffer.diffuseByte3 = 0;
    rayPayload.AOGBuffer.encodedNormal = 0;
    rayPayload.AOGBuffer._virtualHitPosition = 0;
    rayPayload.AOGBuffer._encodedNormal = 0; 

    if (currentRayRecursionDepth >= g_cb.maxRadianceRayRecursionDepth)
    {
        // Sample Sky Light
        //rayPayload.radiance = float3(133, 161, 179) / 255.0;
        rayPayload.radiance = SampleGradient3SkyColor(ray.direction);
        return rayPayload;
    }

    // Set the ray's extents.
    RayDesc rayDesc;
    rayDesc.Origin = ray.origin;
    rayDesc.Direction = ray.direction;
    rayDesc.TMin = tMin;
    rayDesc.TMax = tMax;

    UINT rayFlags = (cullNonOpaque ? RAY_FLAG_CULL_NON_OPAQUE : 0); 

	TraceRay(g_scene,
        rayFlags,
		TraceRayParameters::InstanceMask,
		TraceRayParameters::HitGroup::Offset[PathtracerRayType::Radiance],
		TraceRayParameters::HitGroup::GeometryStride,
		TraceRayParameters::MissShader::Offset[PathtracerRayType::Radiance],
		rayDesc, rayPayload);

	return rayPayload;
}

PTRayPayload TracePathTracingRay(in Ray ray, in UINT currentRayRecursionDepth, float tMin = NEAR_PLANE, float tMax = FAR_PLANE, float bounceContribution = 1, bool cullNonOpaque = false)
{
    PTRayPayload rayPayload;
    //rayPayload.rayRecursionDepth = currentRayRecursionDepth + 1;
    //rayPayload.radiance = float3(0,0,0);
    //rayPayload.passThrough = float3(1,1,1);
    /*rayPayload.AOGBuffer.tHit = HitDistanceOnMiss;
    rayPayload.AOGBuffer.hitPosition = 0;
    rayPayload.AOGBuffer.diffuseByte3 = 0;
    rayPayload.AOGBuffer.encodedNormal = 0;
    rayPayload.AOGBuffer._virtualHitPosition = 0;
    rayPayload.AOGBuffer._encodedNormal = 0; */

    if (currentRayRecursionDepth >= g_cb.maxRadianceRayRecursionDepth)
    {
        // Sample Sky Light
        // TODO shoot a shadow ray to avoid light leak
        //rayPayload.radiance = float3(133, 161, 179) / 255.0;
        return rayPayload;
    }

    // Set the ray's extents.
    RayDesc rayDesc;
    rayDesc.Origin = ray.origin;
    rayDesc.Direction = ray.direction;
    rayDesc.TMin = tMin;
    rayDesc.TMax = tMax;

    UINT rayFlags = (cullNonOpaque ? RAY_FLAG_CULL_NON_OPAQUE : 0); 
	TraceRay(g_scene,
        rayFlags,
		TraceRayParameters::InstanceMask,
		TraceRayParameters::HitGroup::Offset[PathtracerRayType::PathTracing],
		TraceRayParameters::HitGroup::GeometryStride,
		TraceRayParameters::MissShader::Offset[PathtracerRayType::PathTracing],
		rayDesc, rayPayload);

	return rayPayload;
}

// Returns radiance of the traced reflected ray.
float3 TraceReflectedGBufferRay(in float3 hitPosition, in float3 wi, in float3 N, in float3 objectNormal, inout PathtracerRayPayload rayPayload, in float TMax = 10000)
{
    // Here we offset ray start along the ray direction instead of surface normal 
    // so that the reflected ray projects to the same screen pixel. 
    // Offsetting by surface normal would result in incorrect mappating in temporally accumulated buffer. 
    float tOffset = 0.001f;
    float3 offsetAlongRay = tOffset * wi;

    float3 adjustedHitPosition = hitPosition + offsetAlongRay;

    Ray ray = { adjustedHitPosition,  wi };

    float tMin = 0; 
    float tMax = TMax;

    rayPayload = TraceRadianceRay(ray, rayPayload.rayRecursionDepth, tMin, tMax);
    if (rayPayload.AOGBuffer.tHit != HitDistanceOnMiss)
    {
        // Get the current planar mirror in the previous frame.
        float3x4 _mirrorBLASTransform = g_prevFrameBottomLevelASInstanceTransform[InstanceIndex()];
        float3 _mirrorHitPosition = mul(_mirrorBLASTransform, float4(HitObjectPosition(), 1));

        // Pass the virtual hit position reflected across the current mirror surface upstream 
        // as if the ray went through the mirror to be able to recursively reflect at correct ray depths and then projecting to the screen.
        // Skipping normalization as it's not required for the uses of the transformed normal here.
        float3 _mirrorNormal = mul((float3x3)_mirrorBLASTransform, objectNormal);

        rayPayload.AOGBuffer._virtualHitPosition = ReflectFrontPointThroughPlane(rayPayload.AOGBuffer._virtualHitPosition, _mirrorHitPosition, _mirrorNormal);

        // Add current thit and the added offset to the thit of the traced ray.
        rayPayload.AOGBuffer.tHit += RayTCurrent() + tOffset;
    }

    return rayPayload.radiance;
}

// Returns radiance of the traced refracted ray.
float3 TraceRefractedGBufferRay(in float3 hitPosition, in float3 wt, in float3 N, in float3 objectNormal, inout PathtracerRayPayload rayPayload, in float TMax = 10000)
{
    // Here we offset ray start along the ray direction instead of surface normal 
    // so that the reflected ray projects to the same screen pixel. 
    // Offsetting by surface normal would result in incorrect mappating in temporally accumulated buffer. 
    float tOffset = 0.001f;
    float3 offsetAlongRay = tOffset * wt;

    float3 adjustedHitPosition = hitPosition + offsetAlongRay;

    Ray ray = { adjustedHitPosition,  wt };

    float tMin = 0; 
    float tMax = TMax; 

    // TRADEOFF: Performance vs visual quality
    // Cull transparent surfaces when casting a transmission ray for a transparent surface.
    // Spaceship in particular has multiple layer glass causing a substantial perf hit 
    // with multiple bounces along the way.
    // This can cause visual pop ins however, such as in a case of looking at the spaceship's
    // glass cockpit through a window in the house. The cockpit will be skipped in this case.
    bool cullNonOpaque = true;

    rayPayload = TraceRadianceRay(ray, rayPayload.rayRecursionDepth, tMin, tMax, 0, cullNonOpaque);

    if (rayPayload.AOGBuffer.tHit != HitDistanceOnMiss)
    {
        // Add current thit and the added offset to the thit of the traced ray.
        rayPayload.AOGBuffer.tHit += RayTCurrent() + tOffset;
    }

    return rayPayload.radiance;
}

// Update AO GBuffer with the hit that has the largest diffuse component.
// Prioritize larger diffuse component hits as it is a direct scale of the AO contribution to the final color value.
// This doesn't always result in the largest AO contribution as the final color contribution depends on the AO coefficient as well,
// but this is the best estimate at this stage.
void UpdateAOGBufferOnLargerDiffuseComponent(inout PathtracerRayPayload rayPayload, in PathtracerRayPayload _rayPayload, in float3 diffuseScale)
{
    float3 diffuse = Byte3ToNormalizedFloat3(rayPayload.AOGBuffer.diffuseByte3);

    // Adjust the diffuse by the diffuse scale, i.e. BRDF value of the returned ray.
    float3 _diffuse = Byte3ToNormalizedFloat3(_rayPayload.AOGBuffer.diffuseByte3) * diffuseScale;
    
    if (_rayPayload.AOGBuffer.tHit != HitDistanceOnMiss && RGBtoLuminance(diffuse) < RGBtoLuminance(_diffuse))
    {
        rayPayload.AOGBuffer = _rayPayload.AOGBuffer;
        rayPayload.AOGBuffer.diffuseByte3 = NormalizedFloat3ToByte3(_diffuse);
    }
}

float3 TraceIndirectLight(in float3 N, in float3 objectNormal, in float3 samplePosition, in PrimitiveMaterialBuffer)
{
	const int IndirectRayCount = 64;
    // for each ray
    // random ray direction
    // theta angle, and cos(beta) [0,1]
    // convert to unit dir
    // shoot ray
    // accumulate
    return float3(0,0,0);
}

float3 Shade(
    inout PathtracerRayPayload rayPayload,
    in float3 N,
    in float3 objectNormal,
    in float3 hitPosition,
    in PrimitiveMaterialBuffer material)
{
    float3 V = -WorldRayDirection();
    float pdf;
    float3 indirectContribution = 0;
    float3 L = 0;

    const float3 Kd = material.Kd;
    const float3 Ks = material.Ks;
    const float3 Kr = material.Kr;
    const float3 Kt = material.Kt;
    const float roughness = material.roughness;

     // Direct illumination
    rayPayload.AOGBuffer.diffuseByte3 = NormalizedFloat3ToByte3(Kd);
    if (!BxDF::IsBlack(material.Kd) || !BxDF::IsBlack(material.Ks))
    {
        float3 wi;
        if (g_cb.mainLightIsDirectional)
        {
	        wi = g_cb.lightDirection;
        }
        else
        {
	        wi = normalize(g_cb.lightPosition.xyz - hitPosition);
        }

        // Raytraced shadows.
        bool isInShadow = TraceShadowRayAndReportIfHit(hitPosition, wi, N, rayPayload);

        L += BxDF::DirectLighting::Shade(
            material.type,
            Kd,
            Ks,
            g_cb.lightColor.xyz,
            isInShadow,
            roughness,
            N,
            V,
            wi);
    }

    // Ambient Indirect Illumination
    // Add a default ambient contribution to all hits. 
    // This will be subtracted for hitPositions with 
    // calculated Ambient coefficient in the composition pass.
    L += g_cb.defaultAmbientIntensity * Kd;

    // TODO add fake diffuse ambient here

    // Specular Indirect Illumination
    bool isReflective = !BxDF::IsBlack(Kr);
    bool isTransmissive = !BxDF::IsBlack(Kt);

    // Handle cases where ray is coming from behind due to imprecision,
    // don't cast reflection rays in that case.
    float smallValue = 1e-6f;
    isReflective = dot(V, N) > smallValue ? isReflective : false;

    if (isReflective || isTransmissive)
    {
        if (isReflective 
            && (BxDF::Specular::Reflection::IsTotalInternalReflection(V, N) 
                || material.type == MaterialType::Mirror))
        {
            PathtracerRayPayload reflectedRayPayLoad = rayPayload;
            float3 wi = reflect(-V, N);
                
            L += Kr * TraceReflectedGBufferRay(hitPosition, wi, N, objectNormal, reflectedRayPayLoad);
            UpdateAOGBufferOnLargerDiffuseComponent(rayPayload, reflectedRayPayLoad, Kr);
        }
        else // No total internal reflection
        {
            float3 Fo = Ks;
            if (isReflective)
            {
                // Radiance contribution from reflection.
                float3 wi;
                float3 Fr = Kr * BxDF::Specular::Reflection::Sample_Fr(V, wi, N, Fo);    // Calculates wi
                
                PathtracerRayPayload reflectedRayPayLoad = rayPayload;
                // Ref: eq 24.4, [Ray-tracing from the Ground Up]
                L += Fr * TraceReflectedGBufferRay(hitPosition, wi, N, objectNormal, reflectedRayPayLoad);
                UpdateAOGBufferOnLargerDiffuseComponent(rayPayload, reflectedRayPayLoad, Fr);
            }

            if (isTransmissive)
            {
                // Radiance contribution from refraction.
                float3 wt;
                float3 Ft = Kt * BxDF::Specular::Transmission::Sample_Ft(V, wt, N, Fo);    // Calculates wt

                PathtracerRayPayload refractedRayPayLoad = rayPayload;

                L += Ft * TraceRefractedGBufferRay(hitPosition, wt, N, objectNormal, refractedRayPayLoad);
                UpdateAOGBufferOnLargerDiffuseComponent(rayPayload, refractedRayPayLoad, Ft);
            }
        }
    }

    return L;
}

[shader("raygeneration")]
void MyRayGenShader_RadianceRay()
{
    uint2 DTid = DispatchRaysIndex().xy;

	// Generate a ray for a camera pixel corresponding to an index from the dispatched 2D grid.
	Ray ray = GenerateCameraRay(DTid, g_cb.cameraPosition, g_cb.projectionToWorldWithCameraAtOrigin);

	// Cast a ray into the scene and retrieve GBuffer information.
	UINT currentRayRecursionDepth = 0;
    PathtracerRayPayload rayPayload = TraceRadianceRay(ray, currentRayRecursionDepth);

    // Invalidate perfect mirror reflections that missed. 
    // There is no We don't need to calculate AO for those.
    bool hasNonZeroDiffuse = rayPayload.AOGBuffer.diffuseByte3 != 0;
    rayPayload.AOGBuffer.tHit = hasNonZeroDiffuse ? rayPayload.AOGBuffer.tHit : HitDistanceOnMiss;
    bool hasCameraRayHitGeometry = rayPayload.AOGBuffer.tHit != HitDistanceOnMiss;

	// Write out GBuffer information to rendertargets.
    g_rtGBufferPosition[DTid] = float4(rayPayload.AOGBuffer.hitPosition, 1);

    float rayLength = HitDistanceOnMiss;
    if (hasCameraRayHitGeometry)
    {
        rayLength = rayPayload.AOGBuffer.tHit;
    
        // Calculate the motion vector.
        float _depth;
        float2 motionVector = CalculateMotionVector(rayPayload.AOGBuffer._virtualHitPosition, _depth, DTid);
        g_rtTextureSpaceMotionVector[DTid] = motionVector;
        g_rtReprojectedNormalDepth[DTid] = EncodeNormalDepth(DecodeNormal(rayPayload.AOGBuffer._encodedNormal), _depth);
        
        // Calculate linear z-depth
        float3 cameraDirection = GenerateForwardCameraRayDirection(g_cb.projectionToWorldWithCameraAtOrigin);
        float linearDepth = rayLength * dot(ray.direction, cameraDirection);

        g_rtGBufferNormalDepth[DTid] = EncodeNormalDepth(DecodeNormal(rayPayload.AOGBuffer.encodedNormal), linearDepth);
        g_rtGBufferDepth[DTid] = linearDepth;

        g_rtAOSurfaceAlbedo[DTid] = float4(Byte3ToNormalizedFloat3(rayPayload.AOGBuffer.diffuseByte3), 0);
    }
    else // No geometry hit.
    {
        g_rtGBufferNormalDepth[DTid] = 0;
        g_rtGBufferDepth[DTid] = 0;
        g_rtAOSurfaceAlbedo[DTid] = 0;

        // Invalidate the motion vector - set it to move well out of texture bounds.
        g_rtTextureSpaceMotionVector[DTid] = 1e3f;
        g_rtReprojectedNormalDepth[DTid] = 0;
    }

    g_rtColor[DTid] = float4(rayPayload.radiance, 1);
}


[shader("raygeneration")]
void MyRayGenShader_PathTracingRay()
{
    uint2 DTid = DispatchRaysIndex().xy;
    // Initialize random numbers generator
	RngStateType rngState = initRNG(DispatchRaysIndex().xy, DispatchRaysDimensions().xy, g_cb.ptFrameID);

	// Generate a ray for a camera pixel corresponding to an index from the dispatched 2D grid.
    float2 offset = float2(rand(rngState), rand(rngState)) - 0.5f;
	Ray ray = GenerateCameraRay(DTid, g_cb.cameraPosition, g_cb.projectionToWorldWithCameraAtOrigin, offset);
    //Ray ray = GenerateCameraRay(DTid, g_cb.cameraPosition, g_cb.projectionToWorldWithCameraAtOrigin);
	// uint2 LaunchIndex = DispatchRaysIndex().xy;
	// uint2 LaunchDimensions = DispatchRaysDimensions().xy;

		// Cast a ray into the scene and retrieve GBuffer information.
	UINT currentRayRecursionDepth = 0;
    //PTRayPayload rayPayload = TracePathTracingRay(ray, currentRayRecursionDepth);
    const int maxRecursionDepth = g_cb.maxRadianceRayRecursionDepth;

    RayDesc rayDesc;
    rayDesc.Origin = ray.origin;
    rayDesc.Direction = ray.direction;
    rayDesc.TMin = NEAR_PLANE;
    rayDesc.TMax = FAR_PLANE;
    float3 radiance = float3(0,0,0);
    float3 passTrough = float3(1,1,1);
    UINT rayFlags = 0;//(cullNonOpaque ? RAY_FLAG_CULL_NON_OPAQUE : 0);
    PTRayPayload rayPayload;
    PTRayPayload gbufferPayload;
    gbufferPayload.tHit = HitDistanceOnMiss;
    for (int bounce = 0; bounce < maxRecursionDepth; bounce++)
    {
        TraceRay(g_scene,
        rayFlags,
		TraceRayParameters::InstanceMask,
		TraceRayParameters::HitGroup::Offset[PathtracerRayType::PathTracing],
		TraceRayParameters::HitGroup::GeometryStride,
		TraceRayParameters::MissShader::Offset[PathtracerRayType::PathTracing],
		rayDesc, rayPayload);
        if (bounce == 0)
        {
	        gbufferPayload = rayPayload;
        }
	    if (rayPayload.tHit == HitDistanceOnMiss)
	    {
		    // ok we hit the sky, terminate
            float3 skyLight = float3(1, 1, 1);// SampleGradient3SkyColor(rayDesc.Direction);//
            radiance += skyLight * passTrough;
            break;
	    }
        
        float3 hitPosition = rayPayload.hitPosition;//rayDesc.origin + rayDesc.Direction * rayPayload.tHit;
        float3 hitNormal = rayPayload.hitNormal;

        passTrough *= clamp( dot(-rayDesc.Direction, hitNormal),0, 1) * rayPayload.hitAlbedo;// / 3.1415926f;
        if (dot(passTrough, float3(1,1,1)) <= 0.00001)
        {
	        break;
        }

    	float3 reflectDir = normalize(reflect(rayDesc.Direction, hitNormal));
        float2 u = float2(rand(rngState), rand(rngState));
        float3 rayDirectionLocal = sampleHemisphere(u);
        float3 sampleDirLocal;
        // Transform view direction into local space of our sampling routines 
		// (local space is oriented so that its positive Z axis points along the shading normal)
		float4 qRotationToZ = getRotationToZAxis(hitNormal);
		float3 Vlocal = rotatePoint(qRotationToZ, -rayDesc.Direction);
		const float3 Nlocal = float3(0.0f, 0.0f, 1.0f);
        // fully diffuse
        reflectDir = normalize(rotatePoint(invertRotation(qRotationToZ), rayDirectionLocal));
        rayDesc.Origin = hitPosition + reflectDir * 0.0001f;
		rayDesc.Direction = reflectDir;
    }
    // Invalidate perfect mirror reflections that missed. 
    // There is no We don't need to calculate AO for those.
    //bool hasNonZeroDiffuse = rayPayload.diffuseByte3 != 0;
    //rayPayload.AOGBuffer.tHit = hasNonZeroDiffuse ? rayPayload.AOGBuffer.tHit : HitDistanceOnMiss;
    bool hasCameraRayHitGeometry = gbufferPayload.tHit != HitDistanceOnMiss;

	// Write out GBuffer information to rendertargets.
    g_rtGBufferPosition[DTid] = float4(gbufferPayload.hitPosition, 1);

    float rayLength = HitDistanceOnMiss;
    if (hasCameraRayHitGeometry)
    {
        rayLength = gbufferPayload.tHit;
    
        // Calculate the motion vector.
        float _depth;
        //float2 motionVector = CalculateMotionVector(rayPayload.AOGBuffer._virtualHitPosition, _depth, DTid);
        //g_rtTextureSpaceMotionVector[DTid] = motionVector;
        //g_rtReprojectedNormalDepth[DTid] = EncodeNormalDepth(DecodeNormal(rayPayload.AOGBuffer._encodedNormal), _depth);
        g_rtTextureSpaceMotionVector[DTid] = 1e3f;
        g_rtReprojectedNormalDepth[DTid] = 0;
        // Calculate linear z-depth
        float3 cameraDirection = GenerateForwardCameraRayDirection(g_cb.projectionToWorldWithCameraAtOrigin);
        float linearDepth = rayLength * dot(ray.direction, cameraDirection);

        g_rtGBufferNormalDepth[DTid] = EncodeNormalDepth(gbufferPayload.hitNormal, linearDepth);
        g_rtGBufferDepth[DTid] = linearDepth;

        g_rtAOSurfaceAlbedo[DTid] = float4(gbufferPayload.hitAlbedo, 0);
    }
    else // No geometry hit.
    {
        g_rtGBufferNormalDepth[DTid] = 0;
        g_rtGBufferDepth[DTid] = 0;
        g_rtAOSurfaceAlbedo[DTid] = 0;

        // Invalidate the motion vector - set it to move well out of texture bounds.
        g_rtTextureSpaceMotionVector[DTid] = 1e3f;
        g_rtReprojectedNormalDepth[DTid] = 0;
    }
    // add frame id debugger ui later
    float3 finalColor = radiance;
    if (g_cb.ptFrameID == 0) // first frame
    {
	    g_rtColor[DTid] = float4(linearToSrgb(finalColor), 1); // may need tone mapping, check later
		g_rtAccumulator[DTid] = float4(finalColor, 1);
    }
    else
    {
        float4 historyColor = g_rtAccumulator[DTid];
        //float3 blendColor = finalColor * 0.03 + historyColor.xyz * 0.97;
	    g_rtColor[DTid] = float4(linearToSrgb(float3(finalColor + historyColor.xyz) / float(g_cb.ptFrameID+1)), 1); // may need tone mapping, check later
		g_rtAccumulator[DTid] += float4(finalColor, 0);
    }
    
    
}

float3 NormalMap(
    in float3 normal,
    in float2 texCoord,
    in VertexPositionNormalTextureTangent vertices[3],
    in PrimitiveMaterialBuffer material,
    in BuiltInTriangleIntersectionAttributes attr)
{
    float3 tangent;
    if (material.hasPerVertexTangents)
    {
        float3 vertexTangents[3] = { vertices[0].tangent, vertices[1].tangent, vertices[2].tangent };
        tangent = HitAttribute(vertexTangents, attr);
    }
    else 
    {
        float3 v0 = vertices[0].position;
        float3 v1 = vertices[1].position;
        float3 v2 = vertices[2].position;
        float2 uv0 = vertices[0].textureCoordinate;
        float2 uv1 = vertices[1].textureCoordinate;
        float2 uv2 = vertices[2].textureCoordinate;
        tangent = CalculateTangent(v0, v1, v2, uv0, uv1, uv2);
    }

    float3 texSample = l_texNormalMap.SampleLevel(LinearWrapSampler, texCoord, 0).xyz;
    float3 bumpNormal = normalize(texSample * 2.f - 1.f);
    return BumpMapNormalToWorldSpaceNormal(bumpNormal, normal, tangent);
}

// OK maybe I should restart here
[shader("closesthit")]
void MyClosestHitShader_PathTracingRay(inout PTRayPayload rayPayload, in BuiltInTriangleIntersectionAttributes attr)
{
	uint startIndex = PrimitiveIndex() * 3;
    const uint3 indices = { l_indices[startIndex], l_indices[startIndex + 1], l_indices[startIndex + 2] };

    // Retrieve vertices for the hit triangle.
    VertexPositionNormalTextureTangent vertices[3] = {
        l_vertices[indices[0]],
        l_vertices[indices[1]],
        l_vertices[indices[2]] };

    float2 vertexTexCoords[3] = { vertices[0].textureCoordinate, vertices[1].textureCoordinate, vertices[2].textureCoordinate };
    float2 texCoord = HitAttribute(vertexTexCoords, attr);


    UINT materialID = l_materialCB.materialID;
    PrimitiveMaterialBuffer material = g_materials[materialID];

    // Load triangle normal.
    float3 normal;
    float3 objectNormal;
    {
        // Retrieve corresponding vertex normals for the triangle vertices.
        float3 vertexNormals[3] = { vertices[0].normal, vertices[1].normal, vertices[2].normal };
        objectNormal = normalize(HitAttribute(vertexNormals, attr));

        float orientation = HitKind() == HIT_KIND_TRIANGLE_FRONT_FACE ? 1 : -1;
        objectNormal *= orientation;

        // BLAS Transforms in this sample are uniformly scaled so it's OK to directly apply the BLAS transform.
        normal = normalize(mul((float3x3)ObjectToWorld3x4(), objectNormal));
    }
    float3 hitPosition = HitWorldPosition();
    float3 hitAlbedo = float3(1,1,1);
    if (g_cb.useNormalMaps && material.hasNormalTexture)
    {
        normal = NormalMap(normal, texCoord, vertices, material, attr);
    }

    if (material.hasDiffuseTexture && !g_cb.useBaseAlbedoFromMaterial)
    {
        float3 texSample = l_texDiffuse.SampleLevel(LinearWrapSampler, texCoord, 0).xyz;
        hitAlbedo = texSample;
    }
    else
    {
	    hitAlbedo = material.Kd;
    }

    if (material.type == MaterialType::AnalyticalCheckerboardTexture)
    {
        float2 uv = hitPosition.xz * 0.1;
        uv.x *= -1;
        float2 ddx = 1;
        float2 ddy = 1;
        /*float checkers = CheckersTextureBoxFilter(uv, ddx, ddy);
        if (length(uv) < 45 && (checkers > 0.5))
        {
            material.Kd = float3(21, 33, 45) / 255;
        }*/
        hitAlbedo = float3(1,1,1);//g_texUVChecker.SampleLevel(LinearWrapSampler, uv, 0).xyz;
    }
    //float3 reflectDir = normalize(reflect(WorldRayDirection(), normal));
	//Ray reflectionRay = { HitWorldPosition() + reflectDir * 0.0001f, reflectDir };
    //rayPayload = TracePathTracingRay(reflectionRay, rayPayload.rayRecursionDepth);
    //rayPayload.passThrough *= clamp(dot(normal, -WorldRayDirection()) , 0, 1); // maybe we do not store passthrough anymore
    rayPayload.tHit = RayTCurrent();
    rayPayload.hitNormal = normal;
    rayPayload.hitPosition = HitWorldPosition();
    rayPayload.hitAlbedo = hitAlbedo;

}


[shader("closesthit")]
void MyClosestHitShader_RadianceRay(inout PathtracerRayPayload rayPayload, in BuiltInTriangleIntersectionAttributes attr)
{
    uint startIndex = PrimitiveIndex() * 3;
    const uint3 indices = { l_indices[startIndex], l_indices[startIndex + 1], l_indices[startIndex + 2] };

    // Retrieve vertices for the hit triangle.
    VertexPositionNormalTextureTangent vertices[3] = {
        l_vertices[indices[0]],
        l_vertices[indices[1]],
        l_vertices[indices[2]] };

    float2 vertexTexCoords[3] = { vertices[0].textureCoordinate, vertices[1].textureCoordinate, vertices[2].textureCoordinate };
    float2 texCoord = HitAttribute(vertexTexCoords, attr);

    UINT materialID = l_materialCB.materialID;
    PrimitiveMaterialBuffer material = g_materials[materialID];

    // Load triangle normal.
    float3 normal;
    float3 objectNormal;
    {
        // Retrieve corresponding vertex normals for the triangle vertices.
        float3 vertexNormals[3] = { vertices[0].normal, vertices[1].normal, vertices[2].normal };
        objectNormal = normalize(HitAttribute(vertexNormals, attr));

        float orientation = HitKind() == HIT_KIND_TRIANGLE_FRONT_FACE ? 1 : -1;
        objectNormal *= orientation;

        // BLAS Transforms in this sample are uniformly scaled so it's OK to directly apply the BLAS transform.
        normal = normalize(mul((float3x3)ObjectToWorld3x4(), objectNormal));
    }
    float3 hitPosition = HitWorldPosition();

    if (g_cb.useNormalMaps && material.hasNormalTexture)
    {
        normal = NormalMap(normal, texCoord, vertices, material, attr);
    }

    if (material.hasDiffuseTexture && !g_cb.useBaseAlbedoFromMaterial)
    {
        float3 texSample = l_texDiffuse.SampleLevel(LinearWrapSampler, texCoord, 0).xyz;
        material.Kd = texSample;
    }

    if (material.type == MaterialType::AnalyticalCheckerboardTexture)
    {
        float2 uv = hitPosition.xz * 0.1;
        uv.x *= -1;
        float2 ddx = 1;
        float2 ddy = 1;
        /*float checkers = CheckersTextureBoxFilter(uv, ddx, ddy);
        if (length(uv) < 45 && (checkers > 0.5))
        {
            material.Kd = float3(21, 33, 45) / 255;
        }*/
        material.Kd = g_texUVChecker.SampleLevel(LinearWrapSampler, uv, 0).xyz;
    }

    rayPayload.AOGBuffer.tHit = RayTCurrent();
    rayPayload.AOGBuffer.hitPosition = hitPosition;
    rayPayload.AOGBuffer.encodedNormal = EncodeNormal(normal);

    // Calculate hit position and normal for the current hit in the previous frame.
    // Note: This is redundant if the AOGBuffer gets overwritten in the Shade function. 
    // However, delaying this computation to post-Shade which casts additional rays results 
    // in bigger live state carried across trace calls and thus higher overhead.
    {
        float3x4 _BLASTransform;
        rayPayload.AOGBuffer._virtualHitPosition = GetWorldHitPositionInPreviousFrame(HitObjectPosition(), InstanceIndex(), indices, attr, _BLASTransform);

        // Calculate normal at the hit in the previous frame.
        // BLAS Transforms in this sample are uniformly scaled so it's OK to directly apply the BLAS transform.
        rayPayload.AOGBuffer._encodedNormal = EncodeNormal(normalize(mul((float3x3)_BLASTransform, objectNormal)));
    }

    // Shade the current hit point, including casting any further rays into the scene 
    // based on current's surface material properties.
    rayPayload.radiance = Shade(rayPayload, normal, objectNormal, hitPosition, material);
}

[shader("closesthit")]
void MyClosestHitShader_ShadowRay(inout ShadowRayPayload rayPayload, in BuiltInTriangleIntersectionAttributes attr)
{
    rayPayload.tHit = RayTCurrent();
}


//***************************************************************************
//**********************------ Miss shaders -------**************************
//***************************************************************************

[shader("miss")]
void MyMissShader_RadianceRay(inout PathtracerRayPayload rayPayload)
{
    //rayPayload.radiance = g_texEnvironmentMap.SampleLevel(LinearWrapSampler, WorldRayDirection(), 0).xyz;
    rayPayload.radiance = SampleGradient3SkyColor(WorldRayDirection());
}

[shader("miss")]
void MyMissShader_ShadowRay(inout ShadowRayPayload rayPayload)
{
    rayPayload.tHit = HitDistanceOnMiss;
}

[shader("miss")]
void MyMissShader_PathTracingRay(inout PTRayPayload rayPayload)
{
    //rayPayload.radiance = float3(1.0, 1.0, 1.0);
    rayPayload.tHit= HitDistanceOnMiss;
}
#endif // PATHTRACER_HLSL