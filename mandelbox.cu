#include <../samples/common/inc/helper_math.h>
#include <float.h>

#define Gauss(a, c, w, x) ((a) * exp(-(((x) - (c)) * ((x) - (c))) / (float)(2 * (w) * (w))))

#define Scale 2.5f
#define FoldingLimit 1.0f
#define FixedRadius2 1.0f
#define MinRadius2 0.25f
#define ColorSharpness 1.0f
#define Saturation 0.6f
#define HueVariance 0.0005f
#define Reflectivity 1.0f
#define DofAmount(hue) (hue * 0.005f)
#define FovAbberation 0.01f
#define SpecularHighlight(angle) Gauss(1, 0, 0.1f, angle)
#define LightBrightness(hue) Gauss(4, 0.25f, 0.5f, hue)
#define AmbientBrightness(hue) Gauss(2, 0.75f, 0.25f, hue)
#define LightPos 3,2,2
#define LightSize 0.02f
#define FogDensity(hue) (hue * 0.5f)
#define FogColor(hue) Gauss(1, 0.5f, 10.0f, hue)
#define WhiteClamp 1
#define BrightThresh 8

#define MaxIters 64
#define Bailout 256
#define DeMultiplier 0.95f
#define RandSeedInitSteps 128
#define MaxRayDist 16
#define MaxRaySteps 256
#define NumRayBounces 3
#define QualityFirstRay 2
#define QualityRestRay 64

// http://en.wikipedia.org/wiki/Stereographic_projection
__device__ float3 RayDir(float3 forward, float3 up, float2 screenCoords, float fov) {
    screenCoords *= -fov;
    float len2 = dot(screenCoords, screenCoords);
    float3 look = make_float3(2 * screenCoords.x, 2 * screenCoords.y, len2 - 1)
            / -(len2 + 1);

    float3 right = cross(forward, up);

    return look.x * right + look.y * up + look.z * forward;
}

__device__ inline float dotXyz(float4 a) {
    float3 xyz = make_float3(a.x, a.y, a.z);
    return dot(xyz, xyz);
}

__device__ float De(float3 offset) {
    float4 z = make_float4(offset, 1.0f);
    for (int n = 0; n < MaxIters; n++) {
        float3 znew = make_float3(z.x, z.y, z.z);
        znew = clamp(znew, -FoldingLimit, FoldingLimit) * 2.0f - znew;
        z = make_float4(znew.x, znew.y, znew.z, z.w);

        float len2 = dot(znew, znew);
        if (len2 > Bailout)
            break;
        z *= FixedRadius2 / clamp(len2, MinRadius2, FixedRadius2);

        z = make_float4(Scale, Scale, Scale, fabs(Scale)) * z
                + make_float4(offset.x, offset.y, offset.z, 1.0f);
    }
    float3 zxyz = make_float3(z.x, z.y, z.z);
    return length(zxyz) / z.w;
}

__device__ float DeColor(float3 z, float lightHue) {
    float3 offset = z;
    float hue = 0.0f;
    for (int n = 0; n < MaxIters && dot(z, z) < Bailout; n++) {
        float3 zold = z;
        z = clamp(z, -FoldingLimit, FoldingLimit) * 2.0f - z;
        hue += dot(zold - z, zold - z);

        float len2 = dot(z, z);
        if (len2 > Bailout)
            break;
        float temp = FixedRadius2 / clamp(len2, MinRadius2, FixedRadius2);
        z *= temp;
        hue += temp;

        z = Scale * z + offset;
    }
    float fullValue = lightHue - hue * HueVariance;
    fullValue *= 3.14159f;
    fullValue = cos(fullValue);
    fullValue *= fullValue;
    fullValue = pow(fullValue, ColorSharpness);
    fullValue = 1 - (1 - fullValue) * Saturation;
    return fullValue;
}

__device__ uint MWC64X(ulong *state)
{
    uint c=(*state)>>32, x=(*state)&0xFFFFFFFF;
    *state = x*((ulong)4294883355U) + c;
    return x^c;
}

__device__ float Rand(ulong* seed)
{
    return (float)MWC64X(seed) / UINT_MAX;
}

__device__ float2 RandCircle(ulong* rand)
{
    float2 polar = make_float2(Rand(rand) * 6.28318531f, sqrt(Rand(rand)));
    return make_float2(cos(polar.x) * polar.y, sin(polar.x) * polar.y);
}

// Box-Muller transform
// returns two normally-distributed independent variables
__device__ float2 RandNormal(ulong* rand)
{
    float mul = sqrt(-2 * log2(Rand(rand)));
    float angle = 6.28318530718f * Rand(rand);
    return mul * make_float2(cos(angle), sin(angle));
}

__device__ float3 RandSphere(ulong* rand)
{
    float2 normal;
    float rest;
    do
    {
        normal = RandNormal(rand);
        rest = RandNormal(rand).x;
    } while (normal.x == 0 && normal.y == 0 && rest == 0);
    return normalize(make_float3(normal.x, normal.y, rest));
}

__device__ float3 RandHemisphere(ulong* rand, float3 normal)
{
    float3 result = RandSphere(rand);
    if (dot(result, normal) < 0)
        result = -result;
    return result;
}

__device__ void ApplyDof(float3* position, float3* lookat, float focalPlane, float hue, ulong* rand)
{
    float3 focalPosition = *position + *lookat * focalPlane;
    float3 xShift = cross(make_float3(0, 0, 1), *lookat);
    float3 yShift = cross(*lookat, xShift);
    float2 offset = RandCircle(rand);
    float dofPickup = DofAmount(hue);
    *lookat = normalize(*lookat + offset.x * dofPickup * xShift + offset.y * dofPickup * yShift);
    *position = focalPosition - *lookat * focalPlane;
}

__device__ float3 Normal(float3 pos) {
    const float delta = FLT_EPSILON * 2;
    float dppn = De(pos + make_float3(delta, delta, -delta));
    float dpnp = De(pos + make_float3(delta, -delta, delta));
    float dnpp = De(pos + make_float3(-delta, delta, delta));
    float dnnn = De(pos + make_float3(-delta, -delta, -delta));

    return normalize(make_float3(
                (dppn + dpnp) - (dnpp + dnnn),
                (dppn + dnpp) - (dpnp + dnnn),
                (dpnp + dnpp) - (dppn + dnnn)
                ));
}

__device__ float RaySphereIntersection(float3 rayOrigin, float3 rayDir,
    float3 sphereCenter, float sphereSize,
    bool canBePast)
{
    float3 omC = rayOrigin - sphereCenter;
    float lDotOmC = dot(rayDir, omC);
    float underSqrt = lDotOmC * lDotOmC - dot(omC, omC) + sphereSize * sphereSize;
    if (underSqrt < 0)
        return FLT_MAX;
    float theSqrt = sqrt(underSqrt);
    float dist = -lDotOmC - theSqrt;
    if (dist > 0)
        return dist;
    dist = -lDotOmC + theSqrt;
    if (canBePast && dist > 0)
        return dist;
    return FLT_MAX;
}

__device__ float Trace(float3 origin, float3 direction, float quality, float hue, ulong* rand,
        int* isFog, int* hitLightsource)
{
    float distance = 1.0f;
    float totalDistance = De(origin) * Rand(rand) * DeMultiplier;
    float sphereDist = RaySphereIntersection(origin, direction, make_float3(LightPos), LightSize, false);
    float fogDist = -log2(Rand(rand)) / (float)(FogDensity(hue));
    float maxRayDist = min(min((float)MaxRayDist, fogDist), sphereDist);
    for (int i = 0; i < MaxRaySteps && totalDistance < maxRayDist &&
            distance * quality > totalDistance; i++) {
        distance = De(origin + direction * totalDistance) * DeMultiplier;
        totalDistance += distance;
    }
    if (totalDistance > sphereDist)
        *hitLightsource = 1;
    else
        *hitLightsource = 0;
    if (totalDistance > fogDist)
    {
        *isFog = 1;
        totalDistance = fogDist;
    }
    else if (totalDistance > MaxRayDist)
        *isFog = 1;
    else
        *isFog = 0;
    return totalDistance;
}

__device__ float SimpleTrace(float3 origin, float3 direction, float quality)
{
    float distance = 1.0f;
    float totalDistance = 0.0f;
    float sphereDist = RaySphereIntersection(origin, direction, make_float3(LightPos), LightSize, false);
    float maxRayDist = min((float)MaxRayDist, sphereDist);
    int i;
    for (i = 0; i < MaxRaySteps && totalDistance < maxRayDist &&
            distance * quality > totalDistance; i++)
    {
        distance = De(origin + direction * totalDistance) * DeMultiplier;
        totalDistance += distance;
    }
    return (float)i / MaxRaySteps;
}

__device__ bool Reaches(float3 initial, float3 final)
{
    float3 direction = final - initial;
    float lenDir = length(direction);
    direction /= lenDir;
    float totalDistance = 0;
    float distance = FLT_MAX;
    float threshHold = fabs(De(final)) * (DeMultiplier * 0.5f);
    for (int i = 0; i < MaxRaySteps && totalDistance < MaxRayDist &&
                distance > threshHold; i++) {
        distance = De(initial + direction * totalDistance) * DeMultiplier;
        if (i == 0 && fabs(distance * 0.5f) < threshHold)
            threshHold = fabs(distance * 0.5f);
        totalDistance += distance;
        if (totalDistance > lenDir)
            return true;
    }
    return false;
}

__device__ float DirectLighting(float3 rayPos, float hue, ulong* rand, float3* lightDir)
{
    float3 lightToRay = normalize(rayPos - make_float3(LightPos));
    float3 lightPos = make_float3(LightPos) + LightSize * RandHemisphere(rand, lightToRay);
    *lightDir = normalize(lightPos - rayPos);
    if (Reaches(rayPos, lightPos))
    {
        return LightBrightness(hue);
    }
    return 0.0f;
}

__device__ float BRDF(float3 normal, float3 incoming, float3 outgoing)
{
    float3 halfV = normalize(incoming + outgoing);
    float angle = acos(dot(normal, halfV));
    return 1 + SpecularHighlight(angle);
}


__device__ float RenderingEquation(float3 rayPos, float3 rayDir, float qualityMul, float hue, ulong* rand)
{
    float total = 0;
    float color = 1;
    int isFog;
    for (int i = 0; i < NumRayBounces; i++)
    {
        bool isQuality = i == 0;
        float quality = isQuality?QualityFirstRay*qualityMul:QualityRestRay;
        int hitLightsource;
        float distance = Trace(rayPos, rayDir, quality, hue, rand, &isFog, &hitLightsource);
        if (hitLightsource)
        {
            if (i == 0)
            {
                total += color * LightBrightness(hue);
            }
            break;
        }
        if (distance > MaxRayDist)
        {
            isFog = 1;
            //isFog = i != 0;
            break;
        }

        float3 newRayPos = rayPos + rayDir * distance;
        float3 newRayDir;

        float3 normal;
        if (isFog)
        {
            newRayDir = RandSphere(rand);
            color *= FogColor(hue);
        }
        else
        {
            normal = Normal(newRayPos);
            newRayDir = RandHemisphere(rand, normal);
            color *= DeColor(newRayPos, hue) * Reflectivity;
        }

        float3 lightingRayDir;
        float direct = DirectLighting(newRayPos, hue, rand, &lightingRayDir);
        if (isnan(direct))
        {
            return -1.0f;
        }

        if (!isFog)
        {
            color *= BRDF(normal, newRayDir, -rayDir) *
                dot(normal, newRayDir);
            direct *= BRDF(normal, lightingRayDir, -rayDir)
                * dot(normal, lightingRayDir);
        }
        total += color * direct;

        rayPos = newRayPos;
        rayDir = newRayDir;
    }
    if (isFog)
    {
        total += color * AmbientBrightness(hue);
    }
    return total;
}

__device__ float3 HueToRGB(float hue, float value)
{
    hue *= 4;
    float frac = fmod(hue, 1.0f);
    float3 color;
    switch ((int)hue)
    {
        case 0:
            color = make_float3(frac, 0, 0);
            break;
        case 1:
            color = make_float3(1 - frac, frac, 0);
            break;
        case 2:
            color = make_float3(0, 1 - frac, frac);
            break;
        case 3:
            color = make_float3(0, 0, 1 - frac);
            break;
        default:
            color = make_float3(value);
            break;
    }
    color.x = sqrtf(color.x);
    color.y = sqrtf(color.y);
    color.z = sqrtf(color.z);
    color *= value;
    return color;
}

__device__ uint PackPixel(float4 pixel)
{
    if (WhiteClamp)
    {
        float maxVal = max(max(pixel.x, pixel.y), pixel.z);
        if (maxVal > 1)
            pixel /= maxVal;
    }
    pixel = clamp(pixel, 0.0f, 1.0f) * 255;
    return ((int)pixel.x << 16) | ((int)pixel.y << 8) | ((int)pixel.z);
}

extern "C" __global__ void kern(
        uint* __restrict__ screenPixels,
        float4* __restrict__ screen,
        uint2* __restrict__ rngBuffer,
        int screenX, int screenY, int width, int height,
        float posX, float posY, float posZ,
        float lookX, float lookY, float lookZ,
        float upX, float upY, float upZ,
        float fov, float focalDistance, float frame)
{
    int x = blockDim.x * blockIdx.x + threadIdx.x;
    int y = blockDim.y * blockIdx.y + threadIdx.y;
    if (x >= width || y >= height)
        return;

    float3 pos = make_float3(posX, posY, posZ);
    float3 look = make_float3(lookX, lookY, lookZ);
    float3 up = make_float3(upX, upY, upZ);

    ulong rand;
    uint2 randBuffer = rngBuffer[y * width + x];
    rand = (ulong)randBuffer.x << 32 | (ulong)randBuffer.y;
    rand += y * width + x;
    if (frame == 0)
    {
        for (int i = 0; (float)i / RandSeedInitSteps - 1 < Rand(&rand) * RandSeedInitSteps; i++)
        {
        }
    }

    float hue = Rand(&rand);

    float2 screenCoords = make_float2((float)(x + screenX), (float)(y + screenY));
    fov *= exp((hue - 0.5f) * FovAbberation);
    float3 rayDir = RayDir(look, up, screenCoords, fov);
    ApplyDof(&pos, &rayDir, focalDistance, hue, &rand);
    int screenIndex = y * width + x;

    float4 final;
    if (frame == 0)
    {
        float dist = SimpleTrace(pos, rayDir, 1 / fov);
        dist = sqrt(dist);
        screen[screenIndex] = final = make_float4(dist);
    }
    else
    {
        frame -= 1;

        const float weight = 1;
        float intensity = RenderingEquation(pos, rayDir, 1 / fov, hue, &rand);
        float3 color = HueToRGB(hue, intensity);

        float4 old = screen[screenIndex];
        float3 oldxyz = make_float3(old.x, old.y, old.z);
        float3 diff = oldxyz - color;
        if (!isnan(color.x) && !isnan(color.y) && !isnan(color.z) && !isnan(weight)
            && (!BrightThresh || intensity < BrightThresh))
        {
            if (frame != 0 && old.w + weight > 0)
                final = make_float4((color * weight + oldxyz * old.w) / (old.w + weight), old.w + weight);
            else
                final = make_float4(color, weight);
        }
        else
        {
            if (frame != 0)
                final = old;
            else
                final = make_float4(0);
        }
        if (intensity == -1.0f)
            final.x += 100;
        screen[screenIndex] = final;
    }
    screenPixels[screenIndex] = PackPixel(final);
    rngBuffer[screenIndex] = make_uint2((uint)(rand >> 32), (uint)rand);
}
