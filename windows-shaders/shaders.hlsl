#include "alpha_correction.hlsl"

cbuffer GlobalParams: register(b0) {
    float2 global_viewport_size;
    float text_contrast;
    float text_gamma;
    uint is_bgr;
    uint3 global_pad;
};

cbuffer BatchParams: register(b1) {
    uint batch_start_index;
    uint3 batch_pad;
};

Texture2D<float4> t_sprite: register(t0);
SamplerState s_sprite: register(s0);

struct SubpixelSpriteFragmentOutput {
    float4 foreground : SV_Target0;
    float4 alpha : SV_Target1;
};

struct Bounds {
    float2 origin;
    float2 size;
};

struct Corners {
    float top_left;
    float top_right;
    float bottom_right;
    float bottom_left;
};

struct Edges {
    float top;
    float right;
    float bottom;
    float left;
};

struct Hsla {
    float h;
    float s;
    float l;
    float a;
};

struct LinearColorStop {
    Hsla color;
    float percentage;
};

struct Background {
    // 0u is Solid
    // 1u is LinearGradient
    // 2u is PatternSlash
    uint tag;
    // 0u is sRGB linear color
    // 1u is Oklab color
    uint color_space;
    Hsla solid;
    float gradient_angle_or_pattern_height;
    LinearColorStop colors[2];
    uint pad;
};

struct GradientColor {
  float4 solid;
  float4 color0;
  float4 color1;
};

struct AtlasTextureId {
    uint index;
    uint kind;
};

struct AtlasBounds {
    int2 origin;
    int2 size;
};

struct AtlasTile {
    AtlasTextureId texture_id;
    uint tile_id;
    uint padding;
    AtlasBounds bounds;
};

struct TransformationMatrix {
    float2x2 rotation_scale;
    float2 translation;
};

static const float M_PI_F = 3.141592653f;
static const float3 GRAYSCALE_FACTORS = float3(0.2126f, 0.7152f, 0.0722f);

float4 to_device_position_impl(float2 position) {
    float2 device_position = position / global_viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    return float4(device_position, 0., 1.);
}

float4 to_device_position(float2 unit_vertex, Bounds bounds) {
    float2 position = unit_vertex * bounds.size + bounds.origin;
    return to_device_position_impl(position);
}

float4 distance_from_clip_rect_impl(float2 position, Bounds clip_bounds) {
    float2 tl = position - clip_bounds.origin;
    float2 br = clip_bounds.origin + clip_bounds.size - position;
    return float4(tl.x, br.x, tl.y, br.y);
}

float4 distance_from_clip_rect(float2 unit_vertex, Bounds bounds, Bounds clip_bounds) {
    float2 position = unit_vertex * bounds.size + bounds.origin;
    return distance_from_clip_rect_impl(position, clip_bounds);
}

float4 distance_from_clip_rect_transformed(float2 unit_vertex, Bounds bounds, Bounds clip_bounds, TransformationMatrix transformation) {
    float2 position = unit_vertex * bounds.size + bounds.origin;
    float2 transformed = mul(position, transformation.rotation_scale) + transformation.translation;
    return distance_from_clip_rect_impl(transformed, clip_bounds);
}

// Convert linear RGB to sRGB
float3 linear_to_srgb(float3 color) {
    return pow(color, float3(1.0 / 2.2, 1.0 / 2.2, 1.0 / 2.2));
}

// Convert sRGB to linear RGB
float3 srgb_to_linear(float3 color) {
    return pow(color, float3(2.2, 2.2, 2.2));
}

/// Hsla to linear RGBA conversion.
float4 hsla_to_rgba(Hsla hsla) {
    float h = hsla.h * 6.0; // Now, it's an angle but scaled in [0, 6) range
    float s = hsla.s;
    float l = hsla.l;
    float a = hsla.a;

    float c = (1.0 - abs(2.0 * l - 1.0)) * s;
    float x = c * (1.0 - abs(fmod(h, 2.0) - 1.0));
    float m = l - c / 2.0;

    float r = 0.0;
    float g = 0.0;
    float b = 0.0;

    if (h >= 0.0 && h < 1.0) {
        r = c;
        g = x;
        b = 0.0;
    } else if (h >= 1.0 && h < 2.0) {
        r = x;
        g = c;
        b = 0.0;
    } else if (h >= 2.0 && h < 3.0) {
        r = 0.0;
        g = c;
        b = x;
    } else if (h >= 3.0 && h < 4.0) {
        r = 0.0;
        g = x;
        b = c;
    } else if (h >= 4.0 && h < 5.0) {
        r = x;
        g = 0.0;
        b = c;
    } else {
        r = c;
        g = 0.0;
        b = x;
    }

    float4 rgba;
    rgba.x = (r + m);
    rgba.y = (g + m);
    rgba.z = (b + m);
    rgba.w = a;
    return rgba;
}

// Converts a sRGB color to the Oklab color space.
// Reference: https://bottosson.github.io/posts/oklab/#converting-from-linear-srgb-to-oklab
float4 srgb_to_oklab(float4 color) {
    // Convert non-linear sRGB to linear sRGB
    color = float4(srgb_to_linear(color.rgb), color.a);

    float l = 0.4122214708 * color.r + 0.5363325363 * color.g + 0.0514459929 * color.b;
    float m = 0.2119034982 * color.r + 0.6806995451 * color.g + 0.1073969566 * color.b;
    float s = 0.0883024619 * color.r + 0.2817188376 * color.g + 0.6299787005 * color.b;

    float l_ = pow(l, 1.0/3.0);
    float m_ = pow(m, 1.0/3.0);
    float s_ = pow(s, 1.0/3.0);

    return float4(
        0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
        color.a
    );
}

// Converts an Oklab color to the sRGB color space.
float4 oklab_to_srgb(float4 color) {
    float l_ = color.r + 0.3963377774 * color.g + 0.2158037573 * color.b;
    float m_ = color.r - 0.1055613458 * color.g - 0.0638541728 * color.b;
    float s_ = color.r - 0.0894841775 * color.g - 1.2914855480 * color.b;

    float l = l_ * l_ * l_;
    float m = m_ * m_ * m_;
    float s = s_ * s_ * s_;

    float3 linear_rgb = float3(
        4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    );

    // Convert linear sRGB to non-linear sRGB
    return float4(linear_to_srgb(linear_rgb), color.a);
}

// This approximates the error function, needed for the gaussian integral
float2 erf(float2 x) {
    float2 s = sign(x);
    float2 a = abs(x);
    x = 1. + (0.278393 + (0.230389 + 0.078108 * (a * a)) * a) * a;
    x *= x;
    return s - s / (x * x);
}

float blur_along_x(float x, float y, float sigma, float corner, float2 half_size) {
    float delta = min(half_size.y - corner - abs(y), 0.);
    float curved = half_size.x - corner + sqrt(max(0., corner * corner - delta * delta));
    float2 integral = 0.5 + 0.5 * erf((x + float2(-curved, curved)) * (sqrt(0.5) / sigma));
    return integral.y - integral.x;
}

// A standard gaussian function, used for weighting samples
float gaussian(float x, float sigma) {
    return exp(-(x * x) / (2. * sigma * sigma)) / (sqrt(2. * M_PI_F) * sigma);
}

float4 over(float4 below, float4 above) {
    float4 result;
    float alpha = above.a + below.a * (1.0 - above.a);
    result.rgb = (above.rgb * above.a + below.rgb * below.a * (1.0 - above.a)) / alpha;
    result.a = alpha;
    return result;
}

float2 to_tile_position(float2 unit_vertex, AtlasTile tile) {
    float2 atlas_size;
    t_sprite.GetDimensions(atlas_size.x, atlas_size.y);
    return (float2(tile.bounds.origin) + unit_vertex * float2(tile.bounds.size)) / atlas_size;
}

// Selects corner radius based on quadrant.
float pick_corner_radius(float2 center_to_point, Corners corner_radii) {
    if (center_to_point.x < 0.) {
        if (center_to_point.y < 0.) {
            return corner_radii.top_left;
        } else {
            return corner_radii.bottom_left;
        }
    } else {
        if (center_to_point.y < 0.) {
            return corner_radii.top_right;
        } else {
            return corner_radii.bottom_right;
        }
    }
}

float4 to_device_position_transformed(float2 unit_vertex, Bounds bounds,
                                      TransformationMatrix transformation) {
    float2 position = unit_vertex * bounds.size + bounds.origin;
    float2 transformed = mul(position, transformation.rotation_scale) + transformation.translation;
    float2 device_position = transformed / global_viewport_size * float2(2.0, -2.0) + float2(-1.0, 1.0);
    return float4(device_position, 0.0, 1.0);
}

// Implementation of quad signed distance field
float quad_sdf_impl(float2 corner_center_to_point, float corner_radius) {
    if (corner_radius == 0.0) {
        // Fast path for unrounded corners
        return max(corner_center_to_point.x, corner_center_to_point.y);
    } else {
        // Signed distance of the point from a quad that is inset by corner_radius
        // It is negative inside this quad, and positive outside
        float signed_distance_to_inset_quad =
            // 0 inside the inset quad, and positive outside
            length(max(float2(0.0, 0.0), corner_center_to_point)) +
            // 0 outside the inset quad, and negative inside
            min(0.0, max(corner_center_to_point.x, corner_center_to_point.y));

        return signed_distance_to_inset_quad - corner_radius;
    }
}

float quad_sdf(float2 pt, Bounds bounds, Corners corner_radii) {
    float2 half_size = bounds.size / 2.;
    float2 center = bounds.origin + half_size;
    float2 center_to_point = pt - center;
    float corner_radius = pick_corner_radius(center_to_point, corner_radii);
    float2 corner_to_point = abs(center_to_point) - half_size;
    float2 corner_center_to_point = corner_to_point + corner_radius;
    return quad_sdf_impl(corner_center_to_point, corner_radius);
}

GradientColor prepare_gradient_color(uint tag, uint color_space, Hsla solid, LinearColorStop colors[2]) {
    GradientColor output;
    if (tag == 0 || tag == 2 || tag == 3) {
        output.solid = hsla_to_rgba(solid);
    } else if (tag == 1) {
        output.color0 = hsla_to_rgba(colors[0].color);
        output.color1 = hsla_to_rgba(colors[1].color);

        // Prepare color space in vertex for avoid conversion
        // in fragment shader for performance reasons
        if (color_space == 1) {
            // Oklab
            output.color0 = srgb_to_oklab(output.color0);
            output.color1 = srgb_to_oklab(output.color1);
        }
    }

    return output;
}

float2x2 rotate2d(float angle) {
    float s = sin(angle);
    float c = cos(angle);
    return float2x2(c, -s, s, c);
}

float4 gradient_color(Background background,
                      float2 position,
                      Bounds bounds,
                      float4 solid_color, float4 color0, float4 color1) {
    float4 color;

    switch (background.tag) {
        case 0:
            color = solid_color;
            break;
        case 1: {
            // -90 degrees to match the CSS gradient angle.
            float gradient_angle = background.gradient_angle_or_pattern_height;
            float radians = (fmod(gradient_angle, 360.0) - 90.0) * (M_PI_F / 180.0);
            float2 direction = float2(cos(radians), sin(radians));

            // Expand the short side to be the same as the long side
            if (bounds.size.x > bounds.size.y) {
                direction.y *= bounds.size.y / bounds.size.x;
            } else {
                direction.x *=  bounds.size.x / bounds.size.y;
            }

            // Get the t value for the linear gradient with the color stop percentages.
            float2 half_size = bounds.size * 0.5;
            float2 center = bounds.origin + half_size;
            float2 center_to_point = position - center;
            float t = dot(center_to_point, direction) / length(direction);
            // Check the direct to determine the use x or y
            if (abs(direction.x) > abs(direction.y)) {
                t = (t + half_size.x) / bounds.size.x;
            } else {
                t = (t + half_size.y) / bounds.size.y;
            }

            // Adjust t based on the stop percentages
            t = (t - background.colors[0].percentage)
                / (background.colors[1].percentage
                - background.colors[0].percentage);
            t = clamp(t, 0.0, 1.0);

            switch (background.color_space) {
                case 0:
                    color = lerp(color0, color1, t);
                    break;
                case 1: {
                    float4 oklab_color = lerp(color0, color1, t);
                    color = oklab_to_srgb(oklab_color);
                    break;
                }
            }

            // Dither to reduce banding in gradients (especially dark/alpha).
            // Triangular-distributed noise breaks up 8-bit quantization steps.
            // ±2/255 for RGB (enough for dark-on-dark compositing),
            // ±3/255 for alpha (needs more because alpha × dark color = tiny steps).
            {
                float2 seed = position * 0.6180339887; // golden ratio spread
                float r1 = frac(sin(dot(seed, float2(12.9898, 78.233))) * 43758.5453);
                float r2 = frac(sin(dot(seed, float2(39.3460, 11.135))) * 24634.6345);
                float tri = r1 + r2 - 1.0; // triangular PDF, range [-1, +1]
                color.rgb += tri * 2.0 / 255.0;
                color.a   += tri * 3.0 / 255.0;
            }

            break;
        }
        case 2: {
            float gradient_angle_or_pattern_height = background.gradient_angle_or_pattern_height;
            float pattern_width = (gradient_angle_or_pattern_height / 65535.0f) / 255.0f;
            float pattern_interval = fmod(gradient_angle_or_pattern_height, 65535.0f) / 255.0f;
            float pattern_height = pattern_width + pattern_interval;
            float stripe_angle = M_PI_F / 4.0;
            float pattern_period = pattern_height * sin(stripe_angle);
            float2x2 rotation = rotate2d(stripe_angle);
            float2 relative_position = position - bounds.origin;
            float2 rotated_point = mul(relative_position, rotation);
            float pattern = fmod(rotated_point.x, pattern_period);
            float distance = min(pattern, pattern_period - pattern) - pattern_period * (pattern_width / pattern_height) /  2.0f;
            color = solid_color;
            color.a *= saturate(0.5 - distance);
            break;
        }
        case 3: {
            // checkerboard
            float size = background.gradient_angle_or_pattern_height;
            float2 relative_position = position - bounds.origin;

            float x_index = floor(relative_position.x / size);
            float y_index = floor(relative_position.y / size);
            float should_be_colored = (x_index + y_index) % 2.0;

            color = solid_color;
            color.a *= saturate(should_be_colored);
            break;
        }
    }

    return color;
}

// Returns the dash velocity of a corner given the dash velocity of the two
// sides, by returning the slower velocity (larger dashes).
//
// Since 0 is used for dash velocity when the border width is 0 (instead of
// +inf), this returns the other dash velocity in that case.
//
// An alternative to this might be to appropriately interpolate the dash
// velocity around the corner, but that seems overcomplicated.
float corner_dash_velocity(float dv1, float dv2) {
    if (dv1 == 0.0) {
        return dv2;
    } else if (dv2 == 0.0) {
        return dv1;
    } else {
        return min(dv1, dv2);
    }
}

// Returns alpha used to render antialiased dashes.
// `t` is within the dash when `fmod(t, period) < length`.
float dash_alpha(
    float t, float period, float length, float dash_velocity,
    float antialias_threshold
) {
    float half_period = period / 2.0;
    float half_length = length / 2.0;
    // Value in [-half_period, half_period]
    // The dash is in [-half_length, half_length]
    float centered = fmod(t + half_period - half_length, period) - half_period;
    // Signed distance for the dash, negative values are inside the dash
    float signed_distance = abs(centered) - half_length;
    // Antialiased alpha based on the signed distance
    return saturate(antialias_threshold - signed_distance / dash_velocity);
}

// This approximates distance to the nearest point to a quarter ellipse in a way
// that is sufficient for anti-aliasing when the ellipse is not very eccentric.
// The components of `point` are expected to be positive.
//
// Negative on the outside and positive on the inside.
float quarter_ellipse_sdf(float2 pt, float2 radii) {
    // Scale the space to treat the ellipse like a unit circle
    float2 circle_vec = pt / radii;
    float unit_circle_sdf = length(circle_vec) - 1.0;
    // Approximate up-scaling of the length by using the average of the radii.
    //
    // TODO: A better solution would be to use the gradient of the implicit
    // function for an ellipse to approximate a scaling factor.
    return unit_circle_sdf * (radii.x + radii.y) * -0.5;
}

/*
**
**              Quads
**
*/

struct Quad {
    uint order;
    uint border_style;
    Bounds bounds;
    Bounds content_mask;
    Background background;
    Hsla border_color;
    Corners corner_radii;
    Edges border_widths;
};

struct QuadVertexOutput {
    nointerpolation uint quad_id: TEXCOORD0;
    float4 position: SV_Position;
    nointerpolation float4 border_color: COLOR0;
    nointerpolation float4 background_solid: COLOR1;
    nointerpolation float4 background_color0: COLOR2;
    nointerpolation float4 background_color1: COLOR3;
    float4 clip_distance: SV_ClipDistance;
};

struct QuadFragmentInput {
    nointerpolation uint quad_id: TEXCOORD0;
    float4 position: SV_Position;
    nointerpolation float4 border_color: COLOR0;
    nointerpolation float4 background_solid: COLOR1;
    nointerpolation float4 background_color0: COLOR2;
    nointerpolation float4 background_color1: COLOR3;
};

StructuredBuffer<Quad> quads: register(t1);

// The whole device pixels a quad's bounds touch: a quad drawn through a paint transform
// (`Window::with_paint_scale`) has edges between pixels, which the fragment stage antialiases, as a
// browser draws a transformed box. A snapped quad covers exactly its own pixels.
Bounds covering_pixels(Bounds bounds) {
    float2 origin = floor(bounds.origin);
    Bounds covered;
    covered.origin = origin;
    covered.size = ceil(bounds.origin + bounds.size) - origin;
    return covered;
}

QuadVertexOutput quad_vertex(uint vertex_id: SV_VertexID, uint instance_id: SV_InstanceID) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    uint quad_id = batch_start_index + instance_id;
    Quad quad = quads[quad_id];
    Bounds covered = covering_pixels(quad.bounds);
    float4 device_position = to_device_position(unit_vertex, covered);

    GradientColor gradient = prepare_gradient_color(
        quad.background.tag,
        quad.background.color_space,
        quad.background.solid,
        quad.background.colors
    );
    float4 clip_distance = distance_from_clip_rect(unit_vertex, covered, quad.content_mask);
    float4 border_color = hsla_to_rgba(quad.border_color);

    QuadVertexOutput output;
    output.position = device_position;
    output.border_color = border_color;
    output.quad_id = quad_id;
    output.background_solid = gradient.solid;
    output.background_color0 = gradient.color0;
    output.background_color1 = gradient.color1;
    output.clip_distance = clip_distance;
    return output;
}

float blink_dash_signed(float t, float dash, float period, float total) {
    float m = t - floor(t / period) * period;
    float start = t - m;
    float end = min(dash, total - start);
    float s = (m < end ? min(m, end - m) : -min(m - end, period - m));
    s = max(s, t - total);
    return s;
}

float2 blink_dash_conic(float r, float t) {
    float w = 0.70710678;
    float u = 1.0 - t;
    float2 p0 = float2(-r, 0.0);
    float2 p1 = float2(-r, -r);
    float2 p2 = float2(0.0, -r);
    float2 numer = u * u * p0 + 2.0 * w * t * u * p1 + t * t * p2;
    return numer / (u * u + 2.0 * w * t * u + t * t);
}

float blink_dash_arc_length(float r) {
    if (r <= 0.0) {
        return 0.0;
    }
    uint lo[24];
    uint hi[24];
    lo[0] = 0u;
    hi[0] = 0x3FFFFFFFu;
    int top = 1;
    float measured = 0.0;
    float scale = 1.0 / float(0x3FFFFFFFu);
    [loop]
    for (int step = 0; step < 4096 && top > 0; step++) {
        top -= 1;
        uint a = lo[top];
        uint b = hi[top];
        uint mid_t = (a + b) >> 1u;
        float2 pa = blink_dash_conic(r, float(a) * scale);
        float2 pb = blink_dash_conic(r, float(b) * scale);
        float2 ph = blink_dash_conic(r, float(mid_t) * scale);
        float2 off = ph - (pa + pb) * 0.5;
        if (((b - a) >> 10u) != 0u && max(abs(off.x), abs(off.y)) > 0.5 && top < 22) {
            lo[top] = mid_t;
            hi[top] = b;
            lo[top + 1] = a;
            hi[top + 1] = mid_t;
            top += 2;
        } else {
            measured += distance(pa, pb);
        }
    }
    return measured;
}

float blink_rounded_dash_alpha(float2 p, Bounds snapped, Corners radii, float width) {
    float inset = floor(width * 0.5);
    float x0 = snapped.origin.x + inset;
    float y0 = snapped.origin.y + inset;
    float x1 = max(snapped.origin.x + snapped.size.x - inset, x0);
    float y1 = max(snapped.origin.y + snapped.size.y - inset, y0);
    float r_tl = max(radii.top_left - inset, 0.0);
    float r_tr = max(radii.top_right - inset, 0.0);
    float r_br = max(radii.bottom_right - inset, 0.0);
    float r_bl = max(radii.bottom_left - inset, 0.0);

    float quarter = M_PI_F / 2.0;
    float a_tl = blink_dash_arc_length(r_tl);
    float a_tr = blink_dash_arc_length(r_tr);
    float a_br = blink_dash_arc_length(r_br);
    float a_bl = blink_dash_arc_length(r_bl);
    float s_t = x1 - x0 - r_tl - r_tr;
    float s_r = y1 - y0 - r_tr - r_br;
    float s_b = x1 - x0 - r_br - r_bl;
    float s_l = y1 - y0 - r_bl - r_tl;
    float at_tr = s_t;
    float at_r = at_tr + a_tr;
    float at_br = at_r + s_r;
    float at_b = at_br + a_br;
    float at_bl = at_b + s_b;
    float at_l = at_bl + a_bl;
    float at_tl = at_l + s_l;
    float total = at_tl + a_tl;
    float measured = floor(total);

    float dash = width * (width >= 3.0 ? 2.0 : 3.0);
    float gap = width * (width >= 3.0 ? 1.0 : 2.0);
    if (measured <= dash * 2.0) {
        return 1.0;
    }
    float two = 2.0 * dash + 2.0 * gap;
    if (measured <= two) {
        dash *= measured / two;
        gap *= measured / two;
    } else {
        float fewer = floor(measured / (dash + gap));
        float more = fewer + 1.0;
        float fewer_gap = (measured - fewer * dash) / fewer;
        float more_gap = (measured - more * dash) / more;
        gap = ((more_gap <= 0.0 || abs(fewer_gap - gap) < abs(more_gap - gap)) ? fewer_gap : more_gap);
    }

    float t = 0.0;
    float stretch = 1.0;
    if (r_tl > 0.0 && p.x < x0 + r_tl && p.y < y0 + r_tl) {
        float2 v = p - float2(x0 + r_tl, y0 + r_tl);
        t = at_tl + a_tl / quarter * clamp(atan2(-v.y, -v.x), 0.0, quarter);
        stretch = length(v) * quarter / a_tl;
    } else if (r_tr > 0.0 && p.x > x1 - r_tr && p.y < y0 + r_tr) {
        float2 v = p - float2(x1 - r_tr, y0 + r_tr);
        t = at_tr + a_tr / quarter * clamp(atan2(v.x, -v.y), 0.0, quarter);
        stretch = length(v) * quarter / a_tr;
    } else if (r_br > 0.0 && p.x > x1 - r_br && p.y > y1 - r_br) {
        float2 v = p - float2(x1 - r_br, y1 - r_br);
        t = at_br + a_br / quarter * clamp(atan2(v.y, v.x), 0.0, quarter);
        stretch = length(v) * quarter / a_br;
    } else if (r_bl > 0.0 && p.x < x0 + r_bl && p.y > y1 - r_bl) {
        float2 v = p - float2(x0 + r_bl, y1 - r_bl);
        t = at_bl + a_bl / quarter * clamp(atan2(-v.x, v.y), 0.0, quarter);
        stretch = length(v) * quarter / a_bl;
    } else {
        float4 to_side = abs(float4(p.y - y0, p.x - x1, p.y - y1, p.x - x0));
        float nearest = min(min(to_side.x, to_side.y), min(to_side.z, to_side.w));
        if (nearest == to_side.x) {
            t = p.x - (x0 + r_tl);
        } else if (nearest == to_side.y) {
            t = at_r + p.y - (y0 + r_tr);
        } else if (nearest == to_side.z) {
            t = at_b + (x1 - r_br) - p.x;
        } else {
            t = at_l + (y1 - r_bl) - p.y;
        }
    }
    t = clamp((t < 0.0 ? t + total : t), 0.0, total);
    float s = blink_dash_signed(t, dash, dash + gap, total);
    return saturate(s * stretch + 0.5);
}

// --- Skia's analytic antialiasing of a rounded rect, as Chrome rasterizes it on the CPU --- //
// The WGSL of gpui-pre-wgpu's shaders_aaa.wgsl, ported edge_color for edge_color (its comments say what each
// part reproduces: SkScan_AAAPath.cpp's convex and general walkers, SkAnalyticEdge's quarter-pixel
// snapping, SkEdgeBuilder's conics, Blink's bleed avoidance, Skia's thin strokes as hairlines).

static const uint AAA_SIDE = 40u;
static const int AAA_FIXED_ONE = 65536;

static float aaa_ux[80];
static float aaa_uy[80];
static float aaa_ly[80];
static float aaa_dx[80];
static uint aaa_flags[80];
static uint aaa_count[2];
static float aaa_hair_alpha;

int aaa_snap_y(int y) {
    return ((y + (AAA_FIXED_ONE >> 3)) >> 14) << 14;
}

int aaa_fixed(float v) {
    return (((int)(v * 256.0)) << 10) >> 2;
}

int aaa_bit_length(uint v) {
    return v == 0u ? 0 : firstbithigh(v) + 1;
}

void aaa_push(uint side, float ux, float uy, float ly, float dx, bool first, bool more, bool steady) {
    uint n = aaa_count[side];
    if (n >= AAA_SIDE) {
        return;
    }
    uint i = side * AAA_SIDE + n;
    aaa_ux[i] = ux;
    aaa_uy[i] = uy;
    aaa_ly[i] = ly;
    aaa_dx[i] = dx;
    aaa_flags[i] = (first ? 1u : 0u) | (more ? 2u : 0u) | ((more && steady) ? 4u : 0u);
    aaa_count[side] = n + 1u;
}

void aaa_line(uint side, float2 a, float2 b) {
    int x0 = aaa_fixed(a.x);
    int y0 = aaa_snap_y(aaa_fixed(a.y));
    int x1 = aaa_fixed(b.x);
    int y1 = aaa_snap_y(aaa_fixed(b.y));
    if (y0 > y1) {
        int tx = x0; x0 = x1; x1 = tx;
        int ty = y0; y0 = y1; y1 = ty;
    }
    int dy = (y1 - y0) >> 10;
    if (dy == 0) {
        return;
    }
    float dx = (float)((x1 - x0) >> 10) / (float)dy;
    aaa_push(side, (float)x0 / 65536.0, (float)y0 / 65536.0, (float)y1 / 65536.0, dx, true, false, false);
}

void aaa_quad(uint side, float2 p0, float2 p1, float2 p2) {
    int x0 = (int)(p0.x * 256.0);
    int y0 = (int)(p0.y * 256.0);
    int x1 = (int)(p1.x * 256.0);
    int y1 = (int)(p1.y * 256.0);
    int x2 = (int)(p2.x * 256.0);
    int y2 = (int)(p2.y * 256.0);
    if (y0 > y2) {
        int tx = x0; x0 = x2; x2 = tx;
        int ty = y0; y0 = y2; y2 = ty;
    }
    if (((y0 + 32) >> 6) == ((y2 + 32) >> 6)) {
        return;
    }
    int ddx = abs(((x1 << 1) - x0 - x2) >> 2);
    int ddy = abs(((y1 << 1) - y0 - y2) >> 2);
    int dist = ddx > ddy ? ddx + (ddy >> 1) : ddy + (ddx >> 1);
    dist = (dist + 16) >> 5;
    int cs = clamp(aaa_bit_length((uint)dist) >> 1, 1, 6);
    int count = 1 << cs;
    int s = cs - 1;
    int ax = (x0 - x1 - x1 + x2) << 9;
    int bx = (x1 - x0) << 10;
    int ay = (y0 - y1 - y1 + y2) << 9;
    int by = (y1 - y0) << 10;
    int qdx = (bx + (ax >> cs)) >> 2;
    int qddx = (ax >> (cs - 1)) >> 2;
    int qdy = (by + (ay >> cs)) >> 2;
    int qddy = (ay >> (cs - 1)) >> 2;
    int lastx = (x2 << 10) >> 2;
    int lasty = aaa_snap_y((y2 << 10) >> 2);
    int oldx = (x0 << 10) >> 2;
    int oldy = aaa_snap_y((y0 << 10) >> 2);
    int sx = oldx;
    int sy = oldy;
    bool first = true;
    [loop]
    for (int guard = 0; guard < 64 && count > 0; guard += 1) {
        int newx;
        int newy;
        int nsx;
        int nsy;
        float slope = 0.0;
        bool has_slope = false;
        count -= 1;
        if (count > 0) {
            newx = oldx + (qdx >> s);
            newy = oldy + (qdy >> s);
            if (abs(qdy >> s) >= AAA_FIXED_ONE * 2 && (abs(qdy) << 6) > abs(qdx)) {
                int d = (newy - sy) >> 10;
                has_slope = d != 0;
                slope = has_slope ? (float)((newx - sx) >> 10) / (float)d : 0.0;
                nsy = min(lasty, ((newy + (AAA_FIXED_ONE >> 1)) >> 16) << 16);
                nsx = newx - (int)floor(floor(slope * 65536.0) * (float)(newy - nsy) / 65536.0);
            } else {
                nsy = min(lasty, aaa_snap_y(newy));
                nsx = newx;
                int d = (nsy - sy) >> 10;
                has_slope = d != 0;
                slope = has_slope ? (float)((newx - sx) >> 10) / (float)d : 0.0;
            }
            qdx += qddx;
            qdy += qddy;
        } else {
            newx = lastx;
            newy = lasty;
            nsx = newx;
            nsy = newy;
            int d = (newy - sy) >> 10;
            has_slope = d != 0;
            slope = has_slope ? (float)((newx - sx) >> 10) / (float)d : 0.0;
        }
        if (has_slope && nsy > sy) {
            bool steady = (abs(qdx) >> 1) >= abs(qddx) && (abs(qdy) >> 1) >= abs(qddy)
                && ((qdy - qddy) >> s) >= AAA_FIXED_ONE;
            aaa_push(side, (float)sx / 65536.0, (float)sy / 65536.0, (float)nsy / 65536.0, slope, first, count > 0, steady);
            first = false;
            sx = nsx;
            sy = nsy;
        }
        oldx = newx;
        oldy = newy;
    }
}

uint aaa_conic_quads(float2 top, float2 control, float2 bottom, out float2 c0[8], out float2 c1[8], out float2 c2[8]) {
    float w0 = 0.70710677;
    float a = w0 - 1.0;
    float k = a / (4.0 * (2.0 + a));
    float2 e = k * (top - 2.0 * control + bottom);
    float error = sqrt(e.x * e.x + e.y * e.y);
    uint pow2 = 0u;
    [loop]
    for (; pow2 < 3u; pow2 += 1u) {
        if (error <= 0.25) {
            break;
        }
        error *= 0.25;
    }
    float cw[8];
    c0[0] = top;
    c1[0] = control;
    c2[0] = bottom;
    cw[0] = w0;
    uint n = 1u;
    [loop]
    for (uint level = 0u; level < pow2; level += 1u) {
        [loop]
        for (uint j = 0u; j < n; j += 1u) {
            uint i = n - 1u - j;
            float scale = 1.0 / (1.0 + cw[i]);
            float2 t0 = c0[i] * scale;
            float2 t1 = c1[i] * (cw[i] * scale);
            float2 t2 = c2[i] * scale;
            float2 mid = 0.5 * t0 + t1 + 0.5 * t2;
            float nw = sqrt(0.5 + cw[i] * 0.5);
            float2 first = c0[i];
            float2 last = c2[i];
            c0[2u * i] = first;
            c1[2u * i] = t0 + t1;
            c2[2u * i] = mid;
            c0[2u * i + 1u] = mid;
            c1[2u * i + 1u] = t1 + t2;
            c2[2u * i + 1u] = last;
            cw[2u * i] = nw;
            cw[2u * i + 1u] = nw;
        }
        n *= 2u;
    }
    return n;
}

void aaa_corner(uint side, float2 top, float2 control, float2 bottom) {
    float2 c0[8];
    float2 c1[8];
    float2 c2[8];
    uint n = aaa_conic_quads(top, control, bottom, c0, c1, c2);
    [loop]
    for (uint i = 0u; i < n; i += 1u) {
        aaa_quad(side, c0[i], c1[i], c2[i]);
    }
}

void aaa_build(Bounds bounds, Corners radii, bool top_half) {
    float l = bounds.origin.x;
    float t = bounds.origin.y;
    float r = bounds.origin.x + bounds.size.x;
    float b = bounds.origin.y + bounds.size.y;
    aaa_count[0] = 0u;
    aaa_count[1] = 0u;
    if (top_half) {
        if (radii.top_left > 0.0) {
            aaa_corner(0u, float2(l + radii.top_left, t), float2(l, t), float2(l, t + radii.top_left));
        }
        aaa_line(0u, float2(l, t + radii.top_left), float2(l, b - radii.bottom_left));
        if (radii.top_right > 0.0) {
            aaa_corner(1u, float2(r - radii.top_right, t), float2(r, t), float2(r, t + radii.top_right));
        }
        aaa_line(1u, float2(r, t + radii.top_right), float2(r, b - radii.bottom_right));
    } else {
        aaa_line(0u, float2(l, t + radii.top_left), float2(l, b - radii.bottom_left));
        if (radii.bottom_left > 0.0) {
            aaa_corner(0u, float2(l, b - radii.bottom_left), float2(l, b), float2(l + radii.bottom_left, b));
        }
        aaa_line(1u, float2(r, t + radii.top_right), float2(r, b - radii.bottom_right));
        if (radii.bottom_right > 0.0) {
            aaa_corner(1u, float2(r, b - radii.bottom_right), float2(r, b), float2(r - radii.bottom_right, b));
        }
    }
}

float aaa_clamped_mean(float a, float b) {
    if (abs(b - a) < 1e-6) {
        return saturate(0.5 * (a + b));
    }
    float ga = a <= 0.0 ? 0.0 : (a >= 1.0 ? a - 0.5 : 0.5 * a * a);
    float gb = b <= 0.0 ? 0.0 : (b >= 1.0 ? b - 0.5 : 0.5 * b * b);
    return (gb - ga) / (b - a);
}

int aaa_find(uint side, float y) {
    uint n = aaa_count[side];
    [loop]
    for (uint j = 0u; j < n; j += 1u) {
        uint i = side * AAA_SIDE + j;
        if (aaa_uy[i] <= y && y < aaa_ly[i]) {
            return (int)i;
        }
    }
    return -1;
}

int aaa_next_edge(uint side, int after_index) {
    int end = (int)(side * AAA_SIDE + aaa_count[side]);
    [loop]
    for (int j = after_index + 1; j < end; j += 1) {
        if ((aaa_flags[j] & 1u) != 0u) {
            return j;
        }
    }
    return -1;
}

bool aaa_before(int a, int b) {
    return aaa_uy[a] < aaa_uy[b] || (aaa_uy[a] == aaa_uy[b] && aaa_ux[a] <= aaa_ux[b]);
}

bool aaa_smooth_one(int segment, int next) {
    if ((aaa_flags[segment] & 2u) != 0u) {
        return (aaa_flags[segment] & 4u) != 0u;
    }
    return next >= 0 && abs(aaa_dx[next] - aaa_dx[segment]) <= 1.0 && aaa_ly[next] - aaa_uy[next] >= 1.0;
}

bool aaa_steady(int li, int ri) {
    int l1 = aaa_next_edge(0u, li);
    int r1 = aaa_next_edge(1u, ri);
    int next = -1;
    int after = -1;
    if (l1 >= 0 && (r1 < 0 || aaa_before(l1, r1))) {
        next = l1;
        int l2 = aaa_next_edge(0u, l1);
        after = (l2 >= 0 && (r1 < 0 || aaa_before(l2, r1))) ? l2 : r1;
    } else if (r1 >= 0) {
        next = r1;
        int r2 = aaa_next_edge(1u, r1);
        after = (r2 >= 0 && (l1 < 0 || aaa_before(r2, l1))) ? r2 : l1;
    }
    if (next < 0) {
        return false;
    }
    float lb = aaa_ly[li];
    float rb = aaa_ly[ri];
    if (lb + 1.0 < rb) {
        return aaa_smooth_one(li, next);
    }
    if (lb > rb + 1.0) {
        return aaa_smooth_one(ri, next);
    }
    if (after < 0) {
        return false;
    }
    int a = next;
    int b = after;
    if (aaa_ux[after] < aaa_ux[next]) {
        a = after;
        b = next;
    }
    return aaa_smooth_one(li, a) && aaa_smooth_one(ri, b);
}

float aaa_snap16(float v) {
    return floor(v * 16.0 + 0.5) / 16.0;
}

float aaa_rrect(float2 pixel, Bounds bounds, Corners radii, bool convex) {
    bool top_half = pixel.y + 0.5 < bounds.origin.y + bounds.size.y * 0.5;
    aaa_build(bounds, radii, top_half);
    if (aaa_count[0] == 0u || aaa_count[1] == 0u) {
        return 0.0;
    }
    float row_end = pixel.y + 1.0;
    float y = pixel.y;
    float covered = 0.0;
    [loop]
    for (int guard = 0; guard < 48 && y < row_end; guard += 1) {
        int li = aaa_find(0u, y);
        int ri = aaa_find(1u, y);
        if (li < 0 || ri < 0) {
            float first = min(aaa_uy[0], aaa_uy[AAA_SIDE]);
            if (y < first && first < row_end) {
                y = first;
                continue;
            }
            break;
        }
        float lb = aaa_ly[li];
        float rb = aaa_ly[ri];
        float bottom = min(lb, rb);
        bool vertical = aaa_dx[li] == 0.0 && aaa_dx[ri] == 0.0;
        if (convex && aaa_steady(li, ri)) {
            bottom = ceil(bottom);
        }
        float end = min(bottom, row_end);
        float l0 = aaa_ux[li] + aaa_dx[li] * (y - aaa_uy[li]);
        float l1 = aaa_ux[li] + aaa_dx[li] * (end - aaa_uy[li]);
        float r0 = aaa_ux[ri] + aaa_dx[ri] * (y - aaa_uy[ri]);
        float r1 = aaa_ux[ri] + aaa_dx[ri] * (end - aaa_uy[ri]);
        if (convex && !vertical) {
            l0 = aaa_snap16(l0);
            l1 = aaa_snap16(l1);
            r0 = aaa_snap16(r0);
            r1 = aaa_snap16(r1);
        }
        covered += (end - y) * max(0.0, aaa_clamped_mean(r0 - pixel.x, r1 - pixel.x)
            - aaa_clamped_mean(l0 - pixel.x, l1 - pixel.x));
        y = end;
    }
    return saturate(covered);
}

float aaa_rect(float2 pixel, Bounds bounds) {
    float2 lo = round(bounds.origin * 256.0) / 256.0;
    float2 hi = round((bounds.origin + bounds.size) * 256.0) / 256.0;
    float2 span = max(min(hi, pixel + 1.0) - max(lo, pixel), float2(0.0, 0.0));
    return span.x * span.y;
}

Bounds aaa_inset(Bounds bounds, Edges widths) {
    Bounds inner;
    inner.origin = bounds.origin + float2(widths.left, widths.top);
    inner.size = max(bounds.size - float2(widths.left + widths.right, widths.top + widths.bottom), float2(0.0, 0.0));
    return inner;
}

Corners aaa_inset_radii(Corners radii, Edges widths) {
    Corners inner;
    inner.top_left = max(0.0, radii.top_left - max(widths.top, widths.left));
    inner.top_right = max(0.0, radii.top_right - max(widths.top, widths.right));
    inner.bottom_right = max(0.0, radii.bottom_right - max(widths.bottom, widths.right));
    inner.bottom_left = max(0.0, radii.bottom_left - max(widths.bottom, widths.left));
    return inner;
}

float aaa_hair_line(int2 pixel, float2 a, float2 b) {
    int x0 = (int)(a.x * 64.0);
    int y0 = (int)(a.y * 64.0);
    int x1 = (int)(b.x * 64.0);
    int y1 = (int)(b.y * 64.0);
    bool horizontal = abs(x1 - x0) > abs(y1 - y0);
    if (!horizontal) {
        int tx = x0; x0 = y0; y0 = tx;
        int tx1 = x1; x1 = y1; y1 = tx1;
    }
    if (x0 > x1) {
        int tx = x0; x0 = x1; x1 = tx;
        int ty = y0; y0 = y1; y1 = ty;
    }
    int major = horizontal ? pixel.x : pixel.y;
    int minor = horizontal ? pixel.y : pixel.x;
    int start = x0 >> 6;
    int stop = (x1 + 63) >> 6;
    if (x0 == x1 || major < start || major >= stop) {
        return 0.0;
    }
    int slope = 0;
    int fstart = y0 << 10;
    if (y0 != y1) {
        slope = (int)floor((float)(y1 - y0) * 65536.0 / (float)(x1 - x0));
        fstart = (y0 << 10) + ((slope * (32 - (x0 & 63)) + 32) >> 6);
    }
    int start_coverage = 64 - (x0 & 63);
    int stop_coverage = x1 & 63;
    if (stop - start == 1) {
        start_coverage = x1 - x0;
        stop_coverage = 0;
    }
    int f = fstart + slope * (major - start) + (AAA_FIXED_ONE >> 1);
    int lower = f >> 16;
    int fraction = (f >> 8) & 255;
    int alpha = 0;
    if (minor == lower) {
        alpha = fraction;
    } else if (minor == lower - 1) {
        alpha = 255 - fraction;
    }
    if (major == start) {
        alpha = (alpha * start_coverage) >> 6;
    } else if (stop_coverage > 0 && major == stop - 1) {
        alpha = (alpha * stop_coverage) >> 6;
    }
    return aaa_hair_alpha * (float)alpha / 255.0;
}

float aaa_hair_quad(int2 pixel, float2 p0, float2 p1, float2 p2, float kept) {
    float2 d = abs(0.5 * (p0 + p2) - p1);
    uint2 id = (uint2)ceil(d);
    uint dist = id.x > id.y ? id.x + (id.y >> 1u) : id.y + (id.x >> 1u);
    uint level = min(5u, (uint)(aaa_bit_length(dist) + 1) >> 1u);
    uint lines = 1u << level;
    float2 qa = p2 - 2.0 * p1 + p0;
    float2 qb = 2.0 * (p1 - p0);
    float left = kept;
    float2 previous = p0;
    [loop]
    for (uint i = 1u; i <= lines; i += 1u) {
        float t = (float)i / (float)lines;
        float2 at = i == lines ? p2 : (qa * t + qb) * t + p0;
        left *= 1.0 - aaa_hair_line(pixel, previous, at);
        previous = at;
    }
    return left;
}

float aaa_hair_corner(int2 pixel, float2 top, float2 control, float2 bottom, float kept) {
    float2 c0[8];
    float2 c1[8];
    float2 c2[8];
    uint n = aaa_conic_quads(top, control, bottom, c0, c1, c2);
    float left = kept;
    [loop]
    for (uint i = 0u; i < n; i += 1u) {
        left = aaa_hair_quad(pixel, c0[i], c1[i], c2[i], left);
    }
    return left;
}

float aaa_hair_rrect(float2 pixel, Bounds bounds, Corners radii) {
    int2 p = (int2)pixel;
    float l = bounds.origin.x;
    float t = bounds.origin.y;
    float r = bounds.origin.x + bounds.size.x;
    float b = bounds.origin.y + bounds.size.y;
    float left = 1.0;
    left *= 1.0 - aaa_hair_line(p, float2(l + radii.top_left, t), float2(r - radii.top_right, t));
    left *= 1.0 - aaa_hair_line(p, float2(r, t + radii.top_right), float2(r, b - radii.bottom_right));
    left *= 1.0 - aaa_hair_line(p, float2(r - radii.bottom_right, b), float2(l + radii.bottom_left, b));
    left *= 1.0 - aaa_hair_line(p, float2(l, b - radii.bottom_left), float2(l, t + radii.top_left));
    if (radii.top_left > 0.0) {
        left = aaa_hair_corner(p, float2(l + radii.top_left, t), float2(l, t), float2(l, t + radii.top_left), left);
    }
    if (radii.top_right > 0.0) {
        left = aaa_hair_corner(p, float2(r - radii.top_right, t), float2(r, t), float2(r, t + radii.top_right), left);
    }
    if (radii.bottom_right > 0.0) {
        left = aaa_hair_corner(p, float2(r, b - radii.bottom_right), float2(r, b), float2(r - radii.bottom_right, b), left);
    }
    if (radii.bottom_left > 0.0) {
        left = aaa_hair_corner(p, float2(l, b - radii.bottom_left), float2(l, b), float2(l + radii.bottom_left, b), left);
    }
    return left;
}

float4 blink_border_ring(float2 pixel, Bounds bounds, Corners radii, Edges widths, Bounds inner,
        Corners inner_radii, float4 edge_color) {
    float w = widths.top;
    bool uniform_width = widths.right == w && widths.bottom == w && widths.left == w;
    if (uniform_width && w <= 1.0) {
        Edges half_width;
        half_width.top = w * 0.5;
        half_width.right = w * 0.5;
        half_width.bottom = w * 0.5;
        half_width.left = w * 0.5;
        float alpha = floor(edge_color.a * 255.0 + 0.5);
        aaa_hair_alpha = floor(alpha * floor(w * 256.0) / 256.0) / 255.0;
        float middle = aaa_hair_rrect(pixel, aaa_inset(bounds, half_width), aaa_inset_radii(radii, half_width));
        float4 shade = float4(edge_color.a > 0.0 ? edge_color.rgb / edge_color.a : float3(0.0, 0.0, 0.0), 1.0);
        return shade * (1.0 - middle);
    }
    float ring = max(0.0, aaa_rrect(pixel, bounds, radii, false) - aaa_rrect(pixel, inner, inner_radii, false));
    return edge_color * ring;
}

float4 blink_scaled_box(float2 pixel, Bounds bounds, Corners radii, Edges widths, float4 background,
        float4 border) {
    bool bordered = max(max(widths.top, widths.bottom), max(widths.left, widths.right)) > 0.0;
    float4 fill = float4(background.rgb * background.a, background.a);
    float4 edge_color = float4(border.rgb * border.a, border.a);
    if (!bordered) {
        return fill * aaa_rrect(pixel, bounds, radii, true);
    }
    Bounds inner = aaa_inset(bounds, widths);
    Corners inner_radii = aaa_inset_radii(radii, widths);
    if (background.a <= 0.0) {
        return blink_border_ring(pixel, bounds, radii, widths, inner, inner_radii, edge_color);
    }
    bool every_side = min(min(widths.top, widths.bottom), min(widths.left, widths.right)) > 0.0;
    if (every_side && border.a >= 1.0) {
        Edges half_width;
        half_width.top = widths.top * 0.5;
        half_width.right = widths.right * 0.5;
        half_width.bottom = widths.bottom * 0.5;
        half_width.left = widths.left * 0.5;
        float shrunk = aaa_rrect(pixel, aaa_inset(bounds, half_width), aaa_inset_radii(radii, half_width), true);
        float4 ring = blink_border_ring(pixel, bounds, radii, widths, inner, inner_radii, edge_color);
        float4 below = fill * shrunk;
        return ring + below * (1.0 - ring.a);
    }
    float rect = aaa_rect(pixel, bounds);
    float outside_inner = 1.0 - aaa_rrect(pixel, inner, inner_radii, false);
    float4 layer = edge_color * outside_inner + fill * rect * (1.0 - edge_color.a * outside_inner);
    return layer * aaa_rrect(pixel, bounds, radii, true);
}

float4 quad_fragment(QuadFragmentInput input): SV_Target {
    Quad quad = quads[input.quad_id];
    if (quad.border_style == 2) {
        return float4(0.0, 0.0, 0.0, 0.0);
    }
    float4 background_color = gradient_color(quad.background, input.position.xy, quad.bounds,
    input.background_solid, input.background_color0, input.background_color1);

    bool unrounded = quad.corner_radii.top_left == 0.0 &&
        quad.corner_radii.top_right == 0.0 &&
        quad.corner_radii.bottom_left == 0.0 &&
        quad.corner_radii.bottom_right == 0.0;

    // Fast path when the quad is not rounded, doesn't have any border, and lies on whole pixels
    bool whole = all(frac(quad.bounds.origin) == float2(0.0, 0.0)) && all(frac(quad.bounds.size) == float2(0.0, 0.0));
    bool borderless = quad.border_widths.top == 0.0 && quad.border_widths.left == 0.0 &&
        quad.border_widths.right == 0.0 && quad.border_widths.bottom == 0.0;
    if (!whole && unrounded && borderless) {
        return background_color * float4(1.0, 1.0, 1.0, aaa_rect(floor(input.position.xy), quad.bounds));
    }
    if (!whole && !unrounded && quad.border_style == 0) {
        float4 painted = blink_scaled_box(floor(input.position.xy), quad.bounds, quad.corner_radii,
            quad.border_widths, background_color, input.border_color);
        if (painted.a <= 0.0) {
            return float4(0.0, 0.0, 0.0, 0.0);
        }
        return float4(painted.rgb / painted.a, painted.a);
    }
    if (quad.border_widths.top == 0.0 &&
        quad.border_widths.left == 0.0 &&
        quad.border_widths.right == 0.0 &&
        quad.border_widths.bottom == 0.0 &&
        unrounded && whole) {
        return background_color;
    }

    float2 size = quad.bounds.size;
    float2 half_size = size / 2.;
    float2 the_point = input.position.xy - quad.bounds.origin;
    float2 center_to_point = the_point - half_size;

    // Signed distance field threshold for inclusion of pixels. 0.5 is the
    // minimum distance between the center of the pixel and the edge.
    const float antialias_threshold = 0.5;

    // Radius of the nearest corner
    float corner_radius = pick_corner_radius(center_to_point, quad.corner_radii);

    float2 border = float2(
        center_to_point.x < 0.0 ? quad.border_widths.left : quad.border_widths.right,
        center_to_point.y < 0.0 ? quad.border_widths.top : quad.border_widths.bottom
    );

    // 0-width borders are reduced so that `inner_sdf >= antialias_threshold`.
    // The purpose of this is to not draw antialiasing pixels in this case.
    float2 reduced_border = float2(
        border.x == 0.0 ? -antialias_threshold : border.x,
        border.y == 0.0 ? -antialias_threshold : border.y
    );

    // Vector from the corner of the quad bounds to the point, after mirroring
    // the point into the bottom right quadrant. Both components are <= 0.
    float2 corner_to_point = abs(center_to_point) - half_size;

    // Vector from the point to the center of the rounded corner's circle, also
    // mirrored into bottom right quadrant.
    float2 corner_center_to_point = corner_to_point + corner_radius;

    // Whether the nearest point on the border is rounded
    bool is_near_rounded_corner =
        corner_center_to_point.x >= 0.0 &&
        corner_center_to_point.y >= 0.0;

    // Vector from straight border inner corner to point.
    //
    // 0-width borders are turned into width -1 so that inner_sdf is > 1.0 near
    // the border. Without this, antialiasing pixels would be drawn.
    float2 straight_border_inner_corner_to_point = corner_to_point + reduced_border;

    // Whether the point is beyond the inner edge of the straight border
    bool is_beyond_inner_straight_border =
        straight_border_inner_corner_to_point.x > 0.0 ||
        straight_border_inner_corner_to_point.y > 0.0;

    // Whether the point is far enough inside the quad, such that the pixels are
    // not affected by the straight border.
    bool is_within_inner_straight_border =
        straight_border_inner_corner_to_point.x < -antialias_threshold &&
        straight_border_inner_corner_to_point.y < -antialias_threshold;

    // Fast path for points that must be part of the background. A side without a border is reduced to
    // -antialias_threshold, so between pixels the pixels within half a pixel of the outer edge take the
    // antialiased path.
    bool clear_of_edge = whole ||
        (corner_to_point.x < -antialias_threshold && corner_to_point.y < -antialias_threshold);
    if (is_within_inner_straight_border && !is_near_rounded_corner && clear_of_edge) {
        return background_color;
    }

    // Signed distance of the point to the outside edge of the quad's border
    float outer_sdf = quad_sdf_impl(corner_center_to_point, corner_radius);

    // Approximate signed distance of the point to the inside edge of the quad's
    // border. It is negative outside this edge (within the border), and
    // positive inside.
    //
    // This is not always an accurate signed distance:
    // * The rounded portions with varying border width use an approximation of
    //   nearest-point-on-ellipse.
    // * When it is quickly known to be outside the edge, -1.0 is used.
    float inner_sdf = 0.0;
    if (corner_center_to_point.x <= 0.0 || corner_center_to_point.y <= 0.0) {
        // Fast paths for straight borders
        inner_sdf = -max(straight_border_inner_corner_to_point.x,
                        straight_border_inner_corner_to_point.y);
    } else if (is_beyond_inner_straight_border) {
        // Fast path for points that must be outside the inner edge
        inner_sdf = -1.0;
    } else if (reduced_border.x == reduced_border.y) {
        // Fast path for circular inner edge.
        inner_sdf = -(outer_sdf + reduced_border.x);
    } else {
        float2 ellipse_radii = max(float2(0.0, 0.0), float2(corner_radius, corner_radius) - reduced_border);
        inner_sdf = quarter_ellipse_sdf(corner_center_to_point, ellipse_radii);
    }

    // Negative when inside the border
    float border_sdf = max(inner_sdf, outer_sdf);

    float coverage = saturate(antialias_threshold - outer_sdf);
    float4 background = background_color;

    float4 color = background;
    if (border_sdf < antialias_threshold) {
        float4 border_color = input.border_color;
        bool uniform_border = quad.border_widths.top == quad.border_widths.right
            && quad.border_widths.top == quad.border_widths.bottom
            && quad.border_widths.top == quad.border_widths.left;
        if (quad.border_style == 1 && !unrounded && uniform_border) {
            border_color.a *= blink_rounded_dash_alpha(input.position.xy, quad.bounds,
                quad.corner_radii, quad.border_widths.top);
        } else if (quad.border_style == 1) {
            // Position along the perimeter in "dash space", where each dash
            // period has length 1
            float t = 0.0;

            // Total number of dash periods, so that the dash spacing can be
            // adjusted to evenly divide it
            float max_t = 0.0;

            // Border width is proportional to dash size. This is the behavior
            // used by browsers, but also avoids dashes from different segments
            // overlapping when dash size is smaller than the border width.
            //
            // Dash pattern: (2 * border width) dash, (1 * border width) gap
            const float dash_length_per_width = 2.0;
            const float dash_gap_per_width = 1.0;
            const float dash_period_per_width = dash_length_per_width + dash_gap_per_width;

            // Since the dash size is determined by border width, the density of
            // dashes varies. Multiplying a pixel distance by this returns a
            // position in dash space - it has units (dash period / pixels). So
            // a dash velocity of (1 / 10) is 1 dash every 10 pixels.
            float dash_velocity = 0.0;

            // Dividing this by the border width gives the dash velocity
            const float dv_numerator = 1.0 / dash_period_per_width;

            if (unrounded) {
                // When corners aren't rounded, the dashes are separately laid
                // out on each straight line, rather than around the whole
                // perimeter. This way each line starts and ends with a dash.
                bool is_horizontal = corner_center_to_point.x < corner_center_to_point.y;
                // Choosing the right border width for dashed borders.
                // TODO: A better solution exists taking a look at the whole file.
                // this does not fix single dashed borders at the corners
                float2 dashed_border = float2(
                    max(quad.border_widths.bottom, quad.border_widths.top),
                    max(quad.border_widths.right, quad.border_widths.left)
                );
                float border_width = is_horizontal ? dashed_border.x : dashed_border.y;
                dash_velocity = dv_numerator / border_width;
                t = is_horizontal ? the_point.x : the_point.y;
                t *= dash_velocity;
                max_t = is_horizontal ? size.x : size.y;
                max_t *= dash_velocity;
            } else {
                // When corners are rounded, the dashes are laid out clockwise
                // around the whole perimeter.

                float r_tr = quad.corner_radii.top_right;
                float r_br = quad.corner_radii.bottom_right;
                float r_bl = quad.corner_radii.bottom_left;
                float r_tl = quad.corner_radii.top_left;

                float w_t = quad.border_widths.top;
                float w_r = quad.border_widths.right;
                float w_b = quad.border_widths.bottom;
                float w_l = quad.border_widths.left;

                // Straight side dash velocities
                float dv_t = w_t <= 0.0 ? 0.0 : dv_numerator / w_t;
                float dv_r = w_r <= 0.0 ? 0.0 : dv_numerator / w_r;
                float dv_b = w_b <= 0.0 ? 0.0 : dv_numerator / w_b;
                float dv_l = w_l <= 0.0 ? 0.0 : dv_numerator / w_l;

                // Straight side lengths in dash space
                float s_t = (size.x - r_tl - r_tr) * dv_t;
                float s_r = (size.y - r_tr - r_br) * dv_r;
                float s_b = (size.x - r_br - r_bl) * dv_b;
                float s_l = (size.y - r_bl - r_tl) * dv_l;

                float corner_dash_velocity_tr = corner_dash_velocity(dv_t, dv_r);
                float corner_dash_velocity_br = corner_dash_velocity(dv_b, dv_r);
                float corner_dash_velocity_bl = corner_dash_velocity(dv_b, dv_l);
                float corner_dash_velocity_tl = corner_dash_velocity(dv_t, dv_l);

                // Corner lengths in dash space
                float c_tr = r_tr * (M_PI_F / 2.0) * corner_dash_velocity_tr;
                float c_br = r_br * (M_PI_F / 2.0) * corner_dash_velocity_br;
                float c_bl = r_bl * (M_PI_F / 2.0) * corner_dash_velocity_bl;
                float c_tl = r_tl * (M_PI_F / 2.0) * corner_dash_velocity_tl;

                // Cumulative dash space upto each segment
                float upto_tr = s_t;
                float upto_r = upto_tr + c_tr;
                float upto_br = upto_r + s_r;
                float upto_b = upto_br + c_br;
                float upto_bl = upto_b + s_b;
                float upto_l = upto_bl + c_bl;
                float upto_tl = upto_l + s_l;
                max_t = upto_tl + c_tl;

                if (is_near_rounded_corner) {
                    float radians = atan2(corner_center_to_point.y, corner_center_to_point.x);
                    float corner_t = radians * corner_radius;

                    if (center_to_point.x >= 0.0) {
                        if (center_to_point.y < 0.0) {
                            dash_velocity = corner_dash_velocity_tr;
                            // Subtracted because radians is pi/2 to 0 when
                            // going clockwise around the top right corner,
                            // since the y axis has been flipped
                            t = upto_r - corner_t * dash_velocity;
                        } else {
                            dash_velocity = corner_dash_velocity_br;
                            // Added because radians is 0 to pi/2 when going
                            // clockwise around the bottom-right corner
                            t = upto_br + corner_t * dash_velocity;
                        }
                    } else {
                        if (center_to_point.y >= 0.0) {
                            dash_velocity = corner_dash_velocity_bl;
                            // Subtracted because radians is pi/1 to 0 when
                            // going clockwise around the bottom-left corner,
                            // since the x axis has been flipped
                            t = upto_l - corner_t * dash_velocity;
                        } else {
                            dash_velocity = corner_dash_velocity_tl;
                            // Added because radians is 0 to pi/2 when going
                            // clockwise around the top-left corner, since both
                            // axis were flipped
                            t = upto_tl + corner_t * dash_velocity;
                        }
                    }
                } else {
                    // Straight borders
                    bool is_horizontal = corner_center_to_point.x < corner_center_to_point.y;
                    if (is_horizontal) {
                        if (center_to_point.y < 0.0) {
                            dash_velocity = dv_t;
                            t = (the_point.x - r_tl) * dash_velocity;
                        } else {
                            dash_velocity = dv_b;
                            t = upto_bl - (the_point.x - r_bl) * dash_velocity;
                        }
                    } else {
                        if (center_to_point.x < 0.0) {
                            dash_velocity = dv_l;
                            t = upto_tl - (the_point.y - r_tl) * dash_velocity;
                        } else {
                            dash_velocity = dv_r;
                            t = upto_r + (the_point.y - r_tr) * dash_velocity;
                        }
                    }
                }
            }
            float dash_length = dash_length_per_width / dash_period_per_width;
            float desired_dash_gap = dash_gap_per_width / dash_period_per_width;

            // Straight borders should start and end with a dash, so max_t is
            // reduced to cause this.
            max_t -= unrounded ? dash_length : 0.0;
            if (max_t >= 1.0) {
                // Adjust dash gap to evenly divide max_t
                float dash_count = floor(max_t);
                float dash_period = max_t / dash_count;
                border_color.a *= dash_alpha(t, dash_period, dash_length, dash_velocity, antialias_threshold);
            } else if (unrounded) {
                // When there isn't enough space for the full gap between the
                // two start / end dashes of a straight border, reduce gap to
                // make them fit.
                float dash_gap = max_t - dash_length;
                if (dash_gap > 0.0) {
                    float dash_period = dash_length + dash_gap;
                    border_color.a *= dash_alpha(t, dash_period, dash_length, dash_velocity, antialias_threshold);
                }
            }
        }

        // Blend the border on top of the background and then linearly interpolate
        // between the two as we slide inside the background.
        float4 blended_border = over(background, border_color);
        color = lerp(background, blended_border,
                    saturate(antialias_threshold - inner_sdf));
    }

    return color * float4(1.0, 1.0, 1.0, coverage);
}

/*
**
**              Shadows
**
*/

struct Shadow {
    uint order;
    float blur_radius;
    Bounds bounds;
    Corners corner_radii;
    Bounds content_mask;
    Hsla color;
    Bounds element_bounds;
    Corners element_corner_radii;
    uint inset;
    uint pad; // align to 8 bytes
};

struct ShadowVertexOutput {
    nointerpolation uint shadow_id: TEXCOORD0;
    float4 position: SV_Position;
    nointerpolation float4 color: COLOR;
    float4 clip_distance: SV_ClipDistance;
};

struct ShadowFragmentInput {
  nointerpolation uint shadow_id: TEXCOORD0;
  float4 position: SV_Position;
  nointerpolation float4 color: COLOR;
};

StructuredBuffer<Shadow> shadows: register(t1);

ShadowVertexOutput shadow_vertex(uint vertex_id: SV_VertexID, uint instance_id: SV_InstanceID) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    uint shadow_id = batch_start_index + instance_id;
    Shadow shadow = shadows[shadow_id];

    Bounds bounds;
    if (shadow.inset != 0u) {
        bounds = shadow.element_bounds;
    } else {
        // Leave room for the gaussian tail outside the shadow rect.
        float margin = 3.0 * shadow.blur_radius;
        bounds = shadow.bounds;
        bounds.origin -= margin;
        bounds.size += 2.0 * margin;
    }

    float4 device_position = to_device_position(unit_vertex, bounds);
    float4 clip_distance = distance_from_clip_rect(unit_vertex, bounds, shadow.content_mask);
    float4 color = hsla_to_rgba(shadow.color);

    ShadowVertexOutput output;
    output.position = device_position;
    output.color = color;
    output.shadow_id = shadow_id;
    output.clip_distance = clip_distance;

    return output;
}

float4 shadow_fragment(ShadowFragmentInput input): SV_TARGET {
    Shadow shadow = shadows[input.shadow_id];

    float2 half_size = shadow.bounds.size / 2.;
    float2 center = shadow.bounds.origin + half_size;
    float2 point0 = input.position.xy - center;
    float corner_radius = pick_corner_radius(point0, shadow.corner_radii);

    float alpha;
    if (shadow.blur_radius == 0.) {
        float distance = quad_sdf(input.position.xy, shadow.bounds, shadow.corner_radii);
        alpha = saturate(0.5 - distance);
    } else {
        // The signal is only non-zero in a limited range, so don't waste samples
        float low = point0.y - half_size.y;
        float high = point0.y + half_size.y;
        float start = clamp(-3. * shadow.blur_radius, low, high);
        float end = clamp(3. * shadow.blur_radius, low, high);

        // Accumulate samples (we can get away with surprisingly few samples)
        float step = (end - start) / 4.;
        float y = start + step * 0.5;
        alpha = 0.;
        for (int i = 0; i < 4; i++) {
            alpha += blur_along_x(point0.x, point0.y - y, shadow.blur_radius,
                                corner_radius, half_size) *
                    gaussian(y, shadow.blur_radius) * step;
            y += step;
        }
    }

    if (shadow.inset != 0u) {
        // The inset shadow is the complement of the (blurred) hole rect, clipped to the element.
        // `saturate(0.5 - d)` gives a 1-pixel antialiased edge: d <= -0.5 -> 1, d >= 0.5 -> 0.
        alpha = 1.0 - alpha;
        float element_distance = quad_sdf(input.position.xy, shadow.element_bounds,
                                          shadow.element_corner_radii);
        alpha *= saturate(0.5 - element_distance);
    } else {
        // A drop shadow is drawn only outside its box, cut by the box's own antialiased edge, as a
        // browser clips it: a corner pixel the box half covers keeps half the shadow under it, and a
        // translucent box does not show its own shadow through its fill.
        Bounds element = shadow.element_bounds;
        Corners radii = shadow.element_corner_radii;
        bool whole = all(frac(element.origin) == float2(0.0, 0.0)) && all(frac(element.size) == float2(0.0, 0.0));
        bool rounded = max(max(radii.top_left, radii.top_right), max(radii.bottom_right, radii.bottom_left)) > 0.0;
        if (!whole && rounded) {
            alpha *= 1.0 - aaa_rrect(floor(input.position.xy), element, radii, true);
        } else {
            float element_distance = quad_sdf(input.position.xy, element, radii);
            alpha *= 1.0 - saturate(0.5 - element_distance);
        }
    }

    return input.color * float4(1., 1., 1., alpha);
}

/*
**
**              Path Rasterization
**
*/

struct PathRasterizationSprite {
    float2 xy_position;
    float2 st_position;
    Background color;
    Bounds bounds;
};

StructuredBuffer<PathRasterizationSprite> path_rasterization_sprites: register(t1);

struct PathVertexOutput {
    float4 position: SV_Position;
    float2 st_position: TEXCOORD0;
    nointerpolation uint vertex_id: TEXCOORD1;
    float4 clip_distance: SV_ClipDistance;
};

struct PathFragmentInput {
    float4 position: SV_Position;
    float2 st_position: TEXCOORD0;
    nointerpolation uint vertex_id: TEXCOORD1;
};

PathVertexOutput path_rasterization_vertex(uint vertex_id: SV_VertexID) {
    PathRasterizationSprite sprite = path_rasterization_sprites[vertex_id];

    PathVertexOutput output;
    output.position = to_device_position_impl(sprite.xy_position);
    output.st_position = sprite.st_position;
    output.vertex_id = vertex_id;
    output.clip_distance = distance_from_clip_rect_impl(sprite.xy_position, sprite.bounds);

    return output;
}

float4 path_rasterization_fragment(PathFragmentInput input): SV_Target {
    float2 dx = ddx(input.st_position);
    float2 dy = ddy(input.st_position);
    PathRasterizationSprite sprite = path_rasterization_sprites[input.vertex_id];

    Background background = sprite.color;
    Bounds bounds = sprite.bounds;

    float alpha;
    if (length(float2(dx.x, dy.x))) {
        alpha = 1.0;
    } else {
        float2 gradient = 2.0 * input.st_position.xx * float2(dx.x, dy.x) - float2(dx.y, dy.y);
        float f = input.st_position.x * input.st_position.x - input.st_position.y;
        float distance = f / length(gradient);
        alpha = saturate(0.5 - distance);
    }

    GradientColor gradient = prepare_gradient_color(
        background.tag, background.color_space, background.solid, background.colors);

    float4 color = gradient_color(background, input.position.xy, bounds,
        gradient.solid, gradient.color0, gradient.color1);
    return float4(color.rgb * color.a * alpha, alpha * color.a);
}

/*
**
**              Path Sprites
**
*/

struct PathSprite {
    Bounds bounds;
};

struct PathSpriteVertexOutput {
    float4 position: SV_Position;
    float2 texture_coords: TEXCOORD0;
};

StructuredBuffer<PathSprite> path_sprites: register(t1);

PathSpriteVertexOutput path_sprite_vertex(uint vertex_id: SV_VertexID, uint sprite_id: SV_InstanceID) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    PathSprite sprite = path_sprites[sprite_id];

    // Don't apply content mask because it was already accounted for when rasterizing the path
    float4 device_position = to_device_position(unit_vertex, sprite.bounds);

    float2 screen_position = sprite.bounds.origin + unit_vertex * sprite.bounds.size;
    float2 texture_coords = screen_position / global_viewport_size;

    PathSpriteVertexOutput output;
    output.position = device_position;
    output.texture_coords = texture_coords;
    return output;
}

float4 path_sprite_fragment(PathSpriteVertexOutput input): SV_Target {
    return t_sprite.Sample(s_sprite, input.texture_coords);
}

/*
**
**              Underlines
**
*/

struct Underline {
    uint order;
    uint pad;
    Bounds bounds;
    Bounds content_mask;
    Hsla color;
    float thickness;
    uint wavy;
};

struct UnderlineVertexOutput {
  nointerpolation uint underline_id: TEXCOORD0;
  float4 position: SV_Position;
  nointerpolation float4 color: COLOR;
  float4 clip_distance: SV_ClipDistance;
};

struct UnderlineFragmentInput {
  nointerpolation uint underline_id: TEXCOORD0;
  float4 position: SV_Position;
  nointerpolation float4 color: COLOR;
};

StructuredBuffer<Underline> underlines: register(t1);

UnderlineVertexOutput underline_vertex(uint vertex_id: SV_VertexID, uint instance_id: SV_InstanceID) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    uint underline_id = batch_start_index + instance_id;
    Underline underline = underlines[underline_id];
    float4 device_position = to_device_position(unit_vertex, underline.bounds);
    float4 clip_distance = distance_from_clip_rect(unit_vertex, underline.bounds,
                                                    underline.content_mask);
    float4 color = hsla_to_rgba(underline.color);

    UnderlineVertexOutput output;
    output.position = device_position;
    output.color = color;
    output.underline_id = underline_id;
    output.clip_distance = clip_distance;
    return output;
}

float4 underline_fragment(UnderlineFragmentInput input): SV_Target {
    const float WAVE_FREQUENCY = 2.0;
    const float WAVE_HEIGHT_RATIO = 0.8;

    Underline underline = underlines[input.underline_id];
    if (underline.wavy) {
        float half_thickness = underline.thickness * 0.5;
        float2 origin = underline.bounds.origin;

        float2 st = ((input.position.xy - origin) / underline.bounds.size.y) - float2(0., 0.5);
        float frequency = (M_PI_F * WAVE_FREQUENCY * underline.thickness) / underline.bounds.size.y;
        float amplitude = (underline.thickness * WAVE_HEIGHT_RATIO) / underline.bounds.size.y;

        float sine = sin(st.x * frequency) * amplitude;
        float dSine = cos(st.x * frequency) * amplitude * frequency;
        float distance = (st.y - sine) / sqrt(1. + dSine * dSine);
        float distance_in_pixels = distance * underline.bounds.size.y;
        float distance_from_top_border = distance_in_pixels - half_thickness;
        float distance_from_bottom_border = distance_in_pixels + half_thickness;
        float alpha = saturate(
            0.5 - max(-distance_from_bottom_border, distance_from_top_border));
        return input.color * float4(1., 1., 1., alpha);
    } else {
        return input.color;
    }
}

/*
**
**              Monochrome sprites
**
*/

struct MonochromeSprite {
    uint order;
    uint pad;
    AtlasTile tile;
    Bounds bounds;
    Bounds content_mask;
    Hsla color;
    TransformationMatrix transformation;
};

struct MonochromeSpriteVertexOutput {
    float4 position: SV_Position;
    float2 tile_position: POSITION;
    nointerpolation float4 color: COLOR;
    nointerpolation uint plain: PLAIN;
    float4 clip_distance: SV_ClipDistance;
};

struct MonochromeSpriteFragmentInput {
    float4 position: SV_Position;
    float2 tile_position: POSITION;
    nointerpolation float4 color: COLOR;
    nointerpolation uint plain: PLAIN;
    float4 clip_distance: SV_ClipDistance;
};

StructuredBuffer<MonochromeSprite> mono_sprites: register(t1);

MonochromeSpriteVertexOutput monochrome_sprite_vertex(uint vertex_id: SV_VertexID, uint instance_id: SV_InstanceID) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    uint sprite_id = batch_start_index + instance_id;
    MonochromeSprite sprite = mono_sprites[sprite_id];
    float4 device_position =
        to_device_position_transformed(unit_vertex, sprite.bounds, sprite.transformation);
    float4 clip_distance = distance_from_clip_rect_transformed(unit_vertex, sprite.bounds, sprite.content_mask, sprite.transformation);
    float2 tile_position = to_tile_position(unit_vertex, sprite.tile);
    float4 color = hsla_to_rgba(sprite.color);

    MonochromeSpriteVertexOutput output;
    output.position = device_position;
    output.tile_position = tile_position;
    output.color = color;
    output.plain = sprite.pad;
    output.clip_distance = clip_distance;
    return output;
}

// A sprite marked plain (an SVG icon, marked by paint_svg in gpui-pre's window.rs) blends its
// coverage as it is, as a browser blends a path's antialiased edge; a glyph's coverage is
// corrected as Chrome's is.
float4 monochrome_sprite_fragment(MonochromeSpriteFragmentInput input): SV_Target {
    float sample = t_sprite.Sample(s_sprite, input.tile_position).r;
    float corrected = skia_mask_gamma(sample, input.color.rgb, text_contrast, text_gamma);
    float alpha_corrected = (input.plain == 1u) ? sample : corrected;
    return float4(input.color.rgb, input.color.a * alpha_corrected);
}

MonochromeSpriteVertexOutput subpixel_sprite_vertex(uint vertex_id: SV_VertexID, uint instance_id: SV_InstanceID) {
    return monochrome_sprite_vertex(vertex_id, instance_id);
}

SubpixelSpriteFragmentOutput subpixel_sprite_fragment(MonochromeSpriteFragmentInput input) {
    float3 sample = t_sprite.Sample(s_sprite, input.tile_position).rgb;
    if (is_bgr) {
        sample = sample.bgr;
    }
    float3 alpha_corrected = skia_mask_gamma3(sample, input.color.rgb, text_contrast, text_gamma);

    SubpixelSpriteFragmentOutput output;
    output.foreground = float4(input.color.rgb, 1.0f);
    output.alpha = float4(input.color.a * alpha_corrected, 1.0f);
    return output;
}

/*
**
**              Polychrome sprites
**
*/

struct PolychromeSprite {
    uint order;
    uint pad;
    AtlasTile tile;
    uint grayscale;
    float opacity;
    Bounds bounds;
    Bounds content_mask;
    Corners corner_radii;
};

struct PolychromeSpriteVertexOutput {
    nointerpolation uint sprite_id: TEXCOORD0;
    float4 position: SV_Position;
    float2 tile_position: POSITION;
    float4 clip_distance: SV_ClipDistance;
};

struct PolychromeSpriteFragmentInput {
    nointerpolation uint sprite_id: TEXCOORD0;
    float4 position: SV_Position;
    float2 tile_position: POSITION;
};

StructuredBuffer<PolychromeSprite> poly_sprites: register(t1);

PolychromeSpriteVertexOutput polychrome_sprite_vertex(uint vertex_id: SV_VertexID, uint instance_id: SV_InstanceID) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    uint sprite_id = batch_start_index + instance_id;
    PolychromeSprite sprite = poly_sprites[sprite_id];
    float4 device_position = to_device_position(unit_vertex, sprite.bounds);
    float4 clip_distance = distance_from_clip_rect(unit_vertex, sprite.bounds,
                                                    sprite.content_mask);
    float2 tile_position = to_tile_position(unit_vertex, sprite.tile);

    PolychromeSpriteVertexOutput output;
    output.position = device_position;
    output.tile_position = tile_position;
    output.sprite_id = sprite_id;
    output.clip_distance = clip_distance;
    return output;
}

float4 polychrome_sprite_fragment(PolychromeSpriteFragmentInput input): SV_Target {
    PolychromeSprite sprite = poly_sprites[input.sprite_id];
    float4 sample = t_sprite.Sample(s_sprite, input.tile_position);
    float distance = quad_sdf(input.position.xy, sprite.bounds, sprite.corner_radii);

    float4 color = sample;
    if (sprite.grayscale != 0u) {
        float3 grayscale = dot(color.rgb, GRAYSCALE_FACTORS);
        color = float4(grayscale, sample.a);
    }
    color.a *= sprite.opacity * saturate(0.5 - distance);
    return color;
}

/*
**
**              Backdrop blur
**
*/

// gpui-pre-wgpu's backdrop.wgsl for D3D11: the frame under the box, copied out, tiled by mirroring at its
// edges (SkImageFilters::Crop, kMirror), blurred across and then down by Skia's raster three box pass
// (SkBlurEngine.cpp, ThreeBoxApproxPass) folded into one kernel of whole weights, each pass rounded to a
// byte, and drawn back inside the box. Shader model 4.1 has no compute stage a pixel shader can feed, so
// each pass is a pixel shader over a quad covering its target.

cbuffer BackdropParams: register(b2) {
    float4 backdrop_rect;
    float2 backdrop_target;
    float2 backdrop_origin;
    uint2 backdrop_size;
    uint backdrop_axis;
    uint backdrop_taps;
    uint backdrop_border;
    uint backdrop_rounding;
    uint backdrop_factor;
    uint backdrop_pad;
};

Texture2D<float4> t_backdrop: register(t0);
StructuredBuffer<uint> backdrop_weights: register(t1);

float4 backdrop_position(uint vertex_id) {
    float2 unit_vertex = float2(float(vertex_id & 1u), 0.5 * float(vertex_id & 2u));
    float2 position = lerp(backdrop_rect.xy, backdrop_rect.zw, unit_vertex);
    return float4(position / backdrop_target * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
}

// The index taken into [0, count) by mirroring; the shift by whole periods keeps the remainder unsigned,
// as an index is never further than the kernel's border before the first pixel.
uint backdrop_mirror(int index, uint count) {
    uint period = 2u * count;
    uint at = uint(index + int(period * (backdrop_border / period + 1u))) % period;
    return at >= count ? period - 1u - at : at;
}

// The high 32 bits of a 32 by 32 bit product, from 16 bit halves.
uint backdrop_high_product(uint a, uint b) {
    uint a_low = a & 0xffffu;
    uint a_high = a >> 16u;
    uint b_low = b & 0xffffu;
    uint b_high = b >> 16u;
    uint low = a_low * b_low;
    uint middle_a = a_high * b_low;
    uint middle_b = a_low * b_high;
    uint carry = ((low >> 16u) + (middle_a & 0xffffu) + (middle_b & 0xffffu)) >> 16u;
    return a_high * b_high + (middle_a >> 16u) + (middle_b >> 16u) + carry;
}

float4 backdrop_blur_vertex(uint vertex_id: SV_VertexID): SV_Position {
    return backdrop_position(vertex_id);
}

float4 backdrop_blur_fragment(float4 position: SV_Position): SV_Target {
    int2 at = int2(position.xy);
    uint4 sum = uint4(0u, 0u, 0u, 0u);
    [loop]
    for (uint tap = 0u; tap < backdrop_taps; tap++) {
        int offset = int(tap) - int(backdrop_border);
        int2 source_at = at;
        if (backdrop_axis == 0u) {
            source_at.x = int(backdrop_mirror(at.x + offset, backdrop_size.x));
        } else {
            source_at.y = int(backdrop_mirror(at.y + offset, backdrop_size.y));
        }
        uint4 texel = uint4(round(t_backdrop.Load(int3(source_at, 0)) * 255.0));
        sum += backdrop_weights[tap] * texel;
    }
    uint4 total = sum + uint4(backdrop_rounding, backdrop_rounding, backdrop_rounding, backdrop_rounding);
    uint4 divided = uint4(
        backdrop_high_product(total.x, backdrop_factor),
        backdrop_high_product(total.y, backdrop_factor),
        backdrop_high_product(total.z, backdrop_factor),
        backdrop_high_product(total.w, backdrop_factor));
    return float4(min(divided, uint4(255u, 255u, 255u, 255u))) / 255.0;
}

float4 backdrop_composite_vertex(uint vertex_id: SV_VertexID): SV_Position {
    return backdrop_position(vertex_id);
}

float4 backdrop_composite_fragment(float4 position: SV_Position): SV_Target {
    return t_backdrop.Load(int3(int2(floor(position.xy) - backdrop_origin), 0));
}
