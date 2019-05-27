struct MandelboxCfg;
typedef __local struct MandelboxCfg const* Cfg;

#if NOT_EDITOR
#define COPY_TO_LOCAL                      \
    __local struct MandelboxCfg cfg_local; \
    cfg_local = *cfg_global;               \
    Cfg cfg = &cfg_local;
#else
#define COPY_TO_LOCAL Cfg cfg;
#endif

extern float pos_x(Cfg cfg);                     // 0.0 1.0
extern float pos_y(Cfg cfg);                     // 0.0 1.0
extern float pos_z(Cfg cfg);                     // 5.0 1.0
extern float look_x(Cfg cfg);                    // 0.0 1.0
extern float look_y(Cfg cfg);                    // 0.0 1.0
extern float look_z(Cfg cfg);                    // -1.0 1.0
extern float up_x(Cfg cfg);                      // 0.0 1.0
extern float up_y(Cfg cfg);                      // 1.0 1.0
extern float up_z(Cfg cfg);                      // 0.0 1.0
extern float fov(Cfg cfg);                       // 1.0 -1.0
extern float focal_distance(Cfg cfg);            // 3.0 -1.0
extern float scale(Cfg cfg);                     // -2.0 0.5 const
extern float folding_limit(Cfg cfg);             // 1.0 -0.5 const
extern float fixed_radius_2(Cfg cfg);            // 1.0 -0.5 const
extern float min_radius_2(Cfg cfg);              // 0.125 -0.5 const
extern float dof_amount(Cfg cfg);                // 0.0 -1.0
extern float fog_distance(Cfg cfg);              // 10.0 -1.0
extern float fog_brightness(Cfg cfg);            // 1.0 0.5
extern float light_pos_1_x(Cfg cfg);             // 3.0 1.0
extern float light_pos_1_y(Cfg cfg);             // 3.5 1.0
extern float light_pos_1_z(Cfg cfg);             // 2.5 1.0
extern float light_radius_1(Cfg cfg);            // 1.0 -0.5
extern float light_brightness_1_hue(Cfg cfg);    // 0.0 0.25
extern float light_brightness_1_sat(Cfg cfg);    // 0.4 -1.0
extern float light_brightness_1_val(Cfg cfg);    // 4.0 -1.0
extern float ambient_brightness_hue(Cfg cfg);    // 0.65 0.25
extern float ambient_brightness_sat(Cfg cfg);    // 0.2 -1.0
extern float ambient_brightness_val(Cfg cfg);    // 1.0 -1.0
extern float reflect_brightness(Cfg cfg);        // 1.0 0.125
extern float surface_color_variance(Cfg cfg);    // 1.0 -0.25
extern float surface_color_shift(Cfg cfg);       // 0.0 0.25
extern float surface_color_saturation(Cfg cfg);  // 1.0 0.125
extern float surface_color_specular(Cfg cfg);    // 0.5 0.125
extern float plane_x(Cfg cfg);                   // 3.0 1.0
extern float plane_y(Cfg cfg);                   // 3.5 1.0
extern float plane_z(Cfg cfg);                   // 2.5 1.0
extern float rotation(Cfg cfg);                  // 0.0 0.125
extern float bailout(Cfg cfg);                   // 32.0 -1.0 const
extern float bailout_normal(Cfg cfg);            // 64.0 -1.0 const
extern float de_multiplier(Cfg cfg);             // 0.9375 0.125 const
extern float max_ray_dist(Cfg cfg);              // 16.0 -0.5 const
extern float quality_first_ray(Cfg cfg);         // 1.0 -0.5 const
extern float quality_rest_ray(Cfg cfg);          // 64.0 -0.5 const
extern float gamma(Cfg cfg);                     // 0.0 0.25 const
extern int white_clamp(Cfg cfg);                 // 0 const
extern int max_iters(Cfg cfg);                   // 20 const
extern int max_ray_steps(Cfg cfg);               // 256 const
extern int num_ray_bounces(Cfg cfg);             // 3 const

#ifdef VR
#define PREVIEW 1
#endif

// Note: When num_ray_bounces is a dynamic variable in MandelboxCfg, the intel
// opencl runtime cannot vectorize the kernel.

static float3 HueToRGB(float hue, float saturation, float value)
{
    hue *= 3;
    float frac = fmod(hue, 1.0f);
    float3 color;
    switch ((int)hue)
    {
        case 0:
            color = (float3)(1 - frac, frac, 0);
            break;
        case 1:
            color = (float3)(0, 1 - frac, frac);
            break;
        case 2:
            color = (float3)(frac, 0, 1 - frac);
            break;
        default:
            color = (float3)(1, 1, 1);
            break;
    }
    saturation = value * (1 - saturation);
    color = color * (value - saturation) + (float3)(saturation, saturation, saturation);
    return color;
}

static float3 LightPos1(Cfg cfg)
{
    return (float3)(light_pos_1_x(cfg), light_pos_1_y(cfg), light_pos_1_z(cfg));
}

static float3 PlanePos(Cfg cfg)
{
    return (float3)(plane_x(cfg), plane_y(cfg), plane_z(cfg));
}

static float3 LightBrightness1(Cfg cfg)
{
    return HueToRGB(light_brightness_1_hue(cfg),
                    light_brightness_1_sat(cfg),
                    light_brightness_1_val(cfg)) /
           reflect_brightness(cfg);
}

static float3 AmbientBrightness(Cfg cfg)
{
    return HueToRGB(ambient_brightness_hue(cfg),
                    ambient_brightness_sat(cfg),
                    ambient_brightness_val(cfg)) /
           reflect_brightness(cfg);
}

struct Random
{
    ulong seed;
};

static float Random_Next(struct Random* this)
{
    uint c = this->seed >> 32;
    uint x = this->seed & 0xFFFFFFFF;
    this->seed = x * ((ulong)4294883355U) + c;
    return (x ^ c) / 4294967296.0f;
}

static struct Random new_Random(uint idx, uint frame, uint global_size)
{
    struct Random result;
    result.seed = (ulong)idx + (ulong)global_size * (ulong)frame;
    for (int i = 0; i < 8; i++)
    {
        Random_Next(&result);
    }
    return result;
}

static float2 Random_Disk(struct Random* this)
{
    const float2 polar = (float2)(Random_Next(this) * 2.0f, sqrt(Random_Next(this)));
    return (float2)(cospi(polar.x) * polar.y, sinpi(polar.x) * polar.y);
}

static float3 Random_Sphere(struct Random* this)
{
    const float theta = Random_Next(this);
    const float phi = acospi(2 * Random_Next(this) - 1);
    const float x = sinpi(phi) * cospi(theta);
    const float y = sinpi(phi) * sinpi(theta);
    const float z = cospi(phi);
    return (float3)(x, y, z);
}

static float3 Random_Ball(struct Random* this)
{
    return rootn(Random_Next(this), 3) * Random_Sphere(this);
}

static float3 Random_Lambertian(struct Random* this, float3 normal)
{
    return normalize(Random_Ball(this) + normal);
}

struct Ray
{
    float3 pos;
    float3 dir;
};

static struct Ray new_Ray(float3 pos, float3 dir)
{
    struct Ray result;
    result.pos = pos;
    result.dir = dir;
    return result;
}

// http://en.wikipedia.org/wiki/Stereographic_projection
static float3 RayDir(float3 forward, float3 up, float2 screenCoords, float calcFov)
{
    screenCoords *= -calcFov;
    const float len2 = dot(screenCoords, screenCoords);
    const float3 look = (float3)(2 * screenCoords.x, 2 * screenCoords.y, len2 - 1) / -(len2 + 1);
    const float3 right = cross(forward, up);
    return look.x * right + look.y * up + look.z * forward;
}

static float3 Ray_At(struct Ray this, float time)
{
    return this.pos + this.dir * time;
}

static void Ray_Dof(Cfg cfg, struct Ray* this, float focalPlane, struct Random* rand)
{
    const float3 focalPosition = Ray_At(*this, focalPlane);
    const float3 xShift = cross((float3)(0, 0, 1), this->dir);
    const float3 yShift = cross(this->dir, xShift);
    const float2 offset = Random_Disk(rand);
    const float dofPickup = dof_amount(cfg);
    this->dir =
        normalize(this->dir + offset.x * dofPickup * xShift + offset.y * dofPickup * yShift);
    this->pos = focalPosition - this->dir * focalPlane;
}

static struct Ray Camera(Cfg cfg, uint x, uint y, uint width, uint height, struct Random* rand)
{
    const float3 origin = (float3)(pos_x(cfg), pos_y(cfg), pos_z(cfg));
    const float3 look = (float3)(look_x(cfg), look_y(cfg), look_z(cfg));
    const float3 up = (float3)(up_x(cfg), up_y(cfg), up_z(cfg));
    const float2 antialias = (float2)(Random_Next(rand), Random_Next(rand)) - (float2)(0.5f, 0.5f);
    const float2 screenCoords =
        (float2)((float)x - (float)(width / 2), (float)y - (float)(height / 2)) + antialias;
    const float calcFov = fov(cfg) * 2 / (width + height);
    const float3 direction = RayDir(look, up, screenCoords, calcFov);
    struct Ray result = new_Ray(origin, direction);
    Ray_Dof(cfg, &result, focal_distance(cfg), rand);
    return result;
}

/*
static float4 Mandelbulb(float4 z, const float Power)
{
    const float r = length(z.xyz);
    // convert to polar coordinates
    float theta = asin(z.z / r);
    float phi = atan2(z.y, z.x);
    float dr = pow(r, Power - 1.0f) * Power * z.w + 1.0f;
    // scale and rotate the point
    float zr = pow(r, Power);
    theta = theta * Power;
    phi = phi * Power;
    // convert back to cartesian coordinates
    float3 z3 =
        zr * (float3)(cos(theta) * cos(phi), cos(theta) * sin(phi), sin(theta));
    return (float4)(z3.x, z3.y, z3.z, dr);
}
*/

static float3 BoxfoldD(Cfg cfg, float3 z)
{
    return clamp(z, -folding_limit(cfg), folding_limit(cfg)) * 2.0f - z;
}

/*
static float4 ContBoxfoldD(float4 z)
{
    float3 znew = z.xyz;
    float3 zsq = (float3)(znew.x * znew.x, znew.y * znew.y, znew.z * znew.z);
    zsq += (float3)(1, 1, 1);
    float3 res = (float3)(
        znew.x / sqrt(zsq.x), znew.y / sqrt(zsq.y), znew.z / sqrt(zsq.z));
    res *= sqrt(8.0f);
    res = znew - res;
    return (float4)(res.x, res.y, res.z, z.w);
}
*/

static float3 SpherefoldD(Cfg cfg, float3 z, float* dz)
{
    const float factor =
        fixed_radius_2(cfg) / clamp(dot(z, z), min_radius_2(cfg), fixed_radius_2(cfg));
    *dz *= factor;
    return z * factor;
}

/*
static float4 ContSpherefoldD(Cfg cfg, float4 z)
{
    z *= min_radius_2 / dot(z.xyz, z.xyz) + fixed_radius_2;
    return z;
}
*/

static float3 TScaleD(Cfg cfg, float3 z, float* dz)
{
    *dz *= fabs(scale(cfg));
    return z * scale(cfg);
}

static float3 TOffsetD(float3 z, float* dz, float3 offset)
{
    *dz += 1.0f;
    return z + offset;
}

static float3 Rotate(Cfg cfg, float3 z)
{
    float3 axis = normalize(PlanePos(cfg));
    float3 angle = rotation(cfg);
    return cos(angle) * z + sin(angle) * cross(z, axis) +
           (1 - cos(angle)) * dot(axis, angle) * axis;
}

static float3 MandelboxD(Cfg cfg, float3 z, float* dz, float3 offset, int* color)
{
    // z = ContBoxfoldD(cfg, z);
    // z = ContSpherefoldD(cfg, z);
    z = BoxfoldD(cfg, z);
    if (dot(z, z) < min_radius_2(cfg))
    {
        (*color)--;
    }
    else if (dot(z, z) < fixed_radius_2(cfg))
    {
        (*color)++;
    }
#ifdef ROTATE
    z = Rotate(cfg, z);
#endif
    z = SpherefoldD(cfg, z, dz);
    z = TScaleD(cfg, z, dz);
    z = TOffsetD(z, dz, offset);
    return z;
}

static float DeSphere(float3 pos, float radius, float3 test)
{
    if (radius == 0)
    {
        return FLT_MAX;
    }
    return length(test - pos) - radius;
}

static float DeMandelbox(Cfg cfg, float3 offset, bool isNormal, int* color)
{
    float3 z = (float3)(offset.x, offset.y, offset.z);
    float dz = 1.0f;
    int n = max(max_iters(cfg), 1);
    int bail = isNormal ? bailout_normal(cfg) : bailout(cfg);
    do
    {
        z = MandelboxD(cfg, z, &dz, offset, color);
    } while (dot(z, z) < bail * bail && --n);
    return length(z) / dz;
}

static float Plane(float3 pos, float3 plane)
{
    return dot(pos, normalize(plane)) - length(plane);
}

static float De(Cfg cfg, float3 offset, bool isNormal)
{
    int color;
    const float mbox = DeMandelbox(cfg, offset, isNormal, &color);
    const float light1 = DeSphere(LightPos1(cfg), light_radius_1(cfg), offset);
#ifdef PLANE
    const float cut = Plane(offset, PlanePos(cfg));
    return min(light1, max(mbox, cut));
#else
    return min(light1, mbox);
#endif
}

struct Material
{
    float3 color;
    float3 normal;
    float3 emissive;
    float specular;
};

// (r, g, b, spec)
static struct Material Material(Cfg cfg, float3 offset)
{
    int raw_color_data = 0;
    const float de = DeMandelbox(cfg, offset, true, &raw_color_data);
    float base_color = raw_color_data / 8.0f;

    base_color *= surface_color_variance(cfg);
    base_color += surface_color_shift(cfg);
    float3 color = (float3)(
        sinpi(base_color), sinpi(base_color + 2.0f / 3.0f), sinpi(base_color + 4.0f / 3.0f));
    color = color * 0.5f + (float3)(0.5f, 0.5f, 0.5f);
    color = surface_color_saturation(cfg) * (color - (float3)(1, 1, 1)) + (float3)(1, 1, 1);

    const float light1 = DeSphere(LightPos1(cfg), light_radius_1(cfg), offset);

    struct Material result;
    if (de < light1)
    {
        result.color = color * reflect_brightness(cfg);
        result.specular = surface_color_specular(cfg);
        result.emissive = (float3)(0, 0, 0);
    }
    else
    {
        result.color = (float3)(1, 1, 1);
        result.specular = 0.0f;
        result.emissive = LightBrightness1(cfg);
    }

    const float delta = max(1e-6f, de * 0.5f);  // aprox. 8.3x float epsilon
    const float dnpp = De(cfg, offset + (float3)(-delta, delta, delta), true);
    const float dpnp = De(cfg, offset + (float3)(delta, -delta, delta), true);
    const float dppn = De(cfg, offset + (float3)(delta, delta, -delta), true);
    const float dnnn = De(cfg, offset + (float3)(-delta, -delta, -delta), true);
    result.normal = (float3)((dppn + dpnp) - (dnpp + dnnn),
                             (dppn + dnpp) - (dpnp + dnnn),
                             (dpnp + dnpp) - (dppn + dnnn));
    result.normal.x += (dot(result.normal, result.normal) == 0.0f);  // ensure nonzero
    result.normal = normalize(result.normal);

    return result;
}

static float Cast(Cfg cfg, struct Ray ray, const float quality, const float maxDist)
{
    float distance;
    float totalDistance = 0.0f;
    uint i = (uint)max(max_ray_steps(cfg), 1);
    do
    {
        distance = De(cfg, Ray_At(ray, totalDistance), false) * de_multiplier(cfg);
        totalDistance += distance;
        i--;
    } while (totalDistance < maxDist && distance * quality > totalDistance && i > 0);

    // correction step
    if (distance * quality <= totalDistance)
    {
        totalDistance -= totalDistance / quality;
        for (int correctStep = 0; correctStep < 4; correctStep++)
        {
            distance = De(cfg, Ray_At(ray, totalDistance), false) * de_multiplier(cfg);
            totalDistance += distance - totalDistance / quality;
        }
    }
    return totalDistance;
}

static float3 Trace(
    Cfg cfg, struct Ray ray, const uint width, const uint height, struct Random* rand)
{
    float3 rayColor = (float3)(0, 0, 0);
    float3 reflectionColor = (float3)(1, 1, 1);
    float quality = quality_first_ray(cfg) * ((width + height) / (2 * fov(cfg)));

    for (int photonIndex = 0; photonIndex < num_ray_bounces(cfg); photonIndex++)
    {
        const float fog_dist =
            fog_distance(cfg) == 0 ? FLT_MAX : -native_log(Random_Next(rand)) * fog_distance(cfg);
        const float max_dist = min(max_ray_dist(cfg), fog_dist);
        const float distance = min(Cast(cfg, ray, quality, max_dist), fog_dist);

        if (distance >= max_ray_dist(cfg) ||
            (photonIndex + 1 == num_ray_bounces(cfg) && distance >= fog_dist))
        {
            // went out-of-bounds, or last fog ray didn't hit anything
            const float3 color = AmbientBrightness(cfg);
            rayColor += color * reflectionColor;
            break;
        }

        const float3 newPos = Ray_At(ray, min(distance, fog_dist));

        float3 newDir;
        struct Material material;

        bool is_fog = (distance >= fog_dist);
        if (is_fog)
        {
            // hit fog, do fog calculations
            newDir = Random_Sphere(rand);
            reflectionColor *= fog_brightness(cfg);
            material.color = (float3)(1, 1, 1);
            material.normal = (float3)(0, 0, 0);
            material.specular = 0;
            material.emissive = (float3)(0, 0, 0);
        }
        else
        {
            // hit surface, do material calculations
            material = Material(cfg, newPos);
            rayColor += reflectionColor * material.emissive;  // ~bling~!

            if (Random_Next(rand) < material.specular)
            {
                // specular
                newDir = ray.dir - 2 * dot(ray.dir, material.normal) * material.normal;
            }
            else
            {
                // diffuse
                newDir = Random_Lambertian(rand, material.normal);
                quality = quality_rest_ray(cfg);
            }
        }

        if (light_radius_1(cfg) == 0)
        {
            float3 lightPos = LightPos1(cfg);
            float3 dir = lightPos - newPos;
            float light_dist = length(dir);
            dir = normalize(dir);
            if (is_fog || dot(dir, material.normal) > 0)
            {
                float dist = Cast(cfg, new_Ray(newPos, dir), quality_rest_ray(cfg), light_dist);
                if (dist >= light_dist)
                {
                    float prod = is_fog ? 1.0f : dot(material.normal, dir);
                    // Fixes tiny lil bright pixels
                    float fixed_dist = fmax(distance / 2.0f, light_dist);
                    float3 color =
                        prod / (fixed_dist * fixed_dist) * material.color * LightBrightness1(cfg);
                    rayColor += reflectionColor * color;  // ~bling~!
                }
            }
        }

        const float incident_angle_weakening = (is_fog ? 1.0f : dot(material.normal, newDir));
        reflectionColor *= incident_angle_weakening * material.color;

        ray = new_Ray(newPos, newDir);

        if (dot(reflectionColor, reflectionColor) == 0)
        {
            break;
        }
    }
    return rayColor;
}

static float3 PreviewTrace(Cfg cfg, struct Ray ray, const uint width, const uint height)
{
    const float quality = quality_first_ray(cfg) * ((width + height) / (2 * fov(cfg)));
    const float max_dist = min(max_ray_dist(cfg), focal_distance(cfg) * 10);
    const float distance = Cast(cfg, ray, quality, max_dist);
    // #ifdef PREVIEW_NORMAL
    const float3 pos = Ray_At(ray, distance);
    return fabs(Material(cfg, pos).normal);
    // #else
    //     const float value = distance / max_dist;
    //     return (float3)(value);
    // #endif
}

static float3 GammaTest(int x, int y, int width, int height)
{
    const float centerValue = (float)x / width;
    const float offset = ((float)(height - y) / height) * (0.5f - fabs(centerValue - 0.5f));
    float result;
    if (x % 16 < 8)
    {
        result = centerValue;
    }
    else if (y % 2 == 0)
    {
        result = centerValue + offset;
    }
    else
    {
        result = centerValue - offset;
    }
    return (float3)(result, result, result);
}

// Perfect, original sRGB
static float GammaSRGB(float value)
{
    if (value < 0.0031308f)
    {
        return 12.92f * value;
    }
    else
    {
        float a = 0.055f;
        return (1 + a) * powr(value, 1.0f / 2.4f) - a;
    }
}

// http://mimosa-pudica.net/fast-gamma/
static float GammaFast(float value)
{
    const float a = 0.00279491f;
    const float b = 1.15907984f;
    // float c = b * native_rsqrt(1.0f + a) - 1.0f;
    const float c = 0.15746346551f;
    return (b * native_rsqrt(value + a) - c) * value;
}

static float GammaPow(float value, float power)
{
    return native_powr(value, power);
}

static float GammaCompression(Cfg cfg, float value)
{
    float gam = gamma(cfg);
    if (gam < 0)
    {
        return GammaSRGB(value);
    }
    else if (gam == 0)
    {
        return GammaFast(value);
    }
    else
    {
        return GammaPow(value, 1 / gam);
    }
}

static uint PackPixel(Cfg cfg, float3 pixel)
{
    if (isnan(pixel.x) || isnan(pixel.y) || isnan(pixel.z))
    {
        return ((uint)255 << 24) | ((uint)(uchar)255 << 0) | ((uint)(uchar)0 << 8) |
               ((uint)(uchar)255 << 16);
    }

    if (white_clamp(cfg))
    {
        const float maxVal = max(max(pixel.x, pixel.y), pixel.z);
        if (maxVal > 1)
        {
            pixel *= 1.0f / maxVal;
        }
        pixel = max(pixel, (float3)(0.0f, 0.0f, 0.0f));
    }
    else
    {
        pixel = clamp(pixel, 0.0f, 1.0f);
    }

    pixel.x = GammaCompression(cfg, pixel.x);
    pixel.y = GammaCompression(cfg, pixel.y);
    pixel.z = GammaCompression(cfg, pixel.z);

    pixel = pixel * 255;

#ifdef VR
    return ((uint)(uchar)pixel.z << 24) | ((uint)(uchar)pixel.y << 16) |
           ((uint)(uchar)pixel.x << 8) | ((uint)255);
#else
    return ((uint)255 << 24) | ((uint)(uchar)pixel.x << 0) | ((uint)(uchar)pixel.y << 8) |
           ((uint)(uchar)pixel.z << 16);
#endif
}

// yay SOA
static float3 GetScratch(__global uchar* rawData, uint idx, uint size)
{
    const __global float* data = (__global float*)rawData;
    return (float3)(data[idx + size], data[idx + size * 2], data[idx + size * 3]);
}

static void SetScratch(__global uchar* rawData, uint idx, uint size, float3 value)
{
    __global float* data = (__global float*)rawData;
    data[idx + size] = value.x;
    data[idx + size * 2] = value.y;
    data[idx + size * 3] = value.z;
}

static struct Random GetRand(__global uchar* rawData, uint idx, uint size)
{
    const __global struct Random* data = (__global struct Random*)rawData;
    // this is scary: sizeof(random) is bigger than sizeof(float), so divide the
    // size multiplier by 2
    return data[idx + size * 2];
}

static void SetRand(__global uchar* rawData, uint idx, uint size, struct Random value)
{
    __global struct Random* data = (__global struct Random*)rawData;
    data[idx + size * 2] = value;
}

static void SetScreen(__global uchar* rawData, uint idx, uint size, uint value)
{
    __global uint* data = (__global uint*)rawData;
    data[idx] = value;
}

// type: -1 is preview, 0 is init, 1 is continue
__kernel void Main(__global uchar* data,
                   __global struct MandelboxCfg const* cfg_global,
                   uint width,
                   uint height,
                   uint frame)
{
    ((__global float*)data)[get_global_id(0)] = 0.5f;
    return;
    COPY_TO_LOCAL

    const uint idx = (uint)get_global_id(0);
    const uint size = width * height;
    const uint x = idx % width;
    // flip image - in screen space, 0,0 is top-left, in 3d space, 0,0 is
    // bottom-left
    const uint y = height - (idx / width + 1);

    // const uint packedColor_ = PackPixel(cfg, (float3)((float)x / width, (float)y / height, 0.5f));

    // SetScreen(data, idx, size, packedColor_);
    // return;

    // out-of-bounds checks aren't needed, due to the ocl driver being awesome
    // and supporting exact-size launches

    const float3 oldColor = frame > 0 ? GetScratch(data, idx, size) : (float3)(0, 0, 0);

    struct Random rand = frame > 0 ? GetRand(data, idx, size) : new_Random(idx, frame, size);
    const struct Ray ray = Camera(cfg, x, y, width, height, &rand);
#ifdef PREVIEW
    const float3 colorComponents = PreviewTrace(cfg, ray, width, height);
#else
    const float3 colorComponents = Trace(cfg, ray, width, height, &rand);
#endif
#ifdef GAMMA_TEST
    const float3 newColor = GammaTest(x, y, width, height);
#else
    const float3 newColor = (colorComponents + oldColor * frame) / (frame + 1);
    SetScratch(data, idx, size, newColor);
    SetRand(data, idx, size, rand);
#endif
    const uint packedColor = PackPixel(cfg, newColor);

    SetScreen(data, idx, size, packedColor);
}
