// Adapted from https://github.com/microsoft/terminal/blob/1283c0f5b99a2961673249fa77c6b986efb5086c/src/renderer/atlas/dwrite.hlsl
// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

float color_brightness(float3 color) {
    // REC. 601 luminance coefficients for perceived brightness
    return dot(color, float3(0.30f, 0.59f, 0.11f));
}

float light_on_dark_contrast(float enhancedContrast, float3 color) {
    float brightness = color_brightness(color);
    float multiplier = saturate(4.0f * (0.75f - brightness));
    return enhancedContrast * multiplier;
}

float enhance_contrast(float alpha, float k) {
    return alpha * (k + 1.0f) / (alpha * k + 1.0f);
}

float3 enhance_contrast3(float3 alpha, float k) {
    return alpha * (k + 1.0f) / (alpha * k + 1.0f);
}

float apply_alpha_correction(float a, float b, float4 g) {
    float brightness_adjustment = g.x * b + g.y;
    float correction = brightness_adjustment * a + (g.z * b + g.w);
    return a + a * (1.0f - a) * correction;
}

float3 apply_alpha_correction3(float3 a, float3 b, float4 g) {
    float3 brightness_adjustment = g.x * b + g.y;
    float3 correction = brightness_adjustment * a + (g.z * b + g.w);
    return a + a * (1.0f - a) * correction;
}

float apply_contrast_and_gamma_correction(float sample, float3 color, float enhanced_contrast_factor, float4 gamma_ratios) {
    float enhanced_contrast = light_on_dark_contrast(enhanced_contrast_factor, color);
    float brightness = color_brightness(color);

    float contrasted = enhance_contrast(sample, enhanced_contrast);
    return apply_alpha_correction(contrasted, brightness, gamma_ratios);
}

float3 apply_contrast_and_gamma_correction3(float3 sample, float3 color, float enhanced_contrast_factor, float4 gamma_ratios) {
    float enhanced_contrast = light_on_dark_contrast(enhanced_contrast_factor, color);

    float3 contrasted = enhance_contrast3(sample, enhanced_contrast);
    return apply_alpha_correction3(contrasted, color, gamma_ratios);
}

// Glyph coverage corrected as Skia corrects a glyph mask before a plain blend (SkMaskGamma.cpp,
// SkTMaskGamma_build_correcting_lut; SkScalerContext.cpp, PreprocessRec): a table entry is what
// makes a blend in the device's gamma land where a blend of linear light with some added contrast
// would. The paint's luminance picks one of eight tables for grey text, each channel's value its
// own table for LCD text. The HLSL port of gpui-pre-wgpu's shaders.wgsl (third_party/
// gpui-pre-wgpu/TSUKIMI.md), so Windows draws text as the wgpu build does. The Terminal
// correction above stays for DirectWrite's color glyph layers (color_text_raster.hlsl).
// Copyright 2012 Google Inc. Use of this source code is governed by a BSD-style license.

float skia_scale255_3(float index) {
    uint i = (uint)index;
    return (float)((i << 5u) | (i << 2u) | (i >> 1u));
}

float skia_luminance_index(float3 color) {
    float3 bytes = round(saturate(color) * 255.0f);
    float3 canonical = float3(
        skia_scale255_3(floor(bytes.r / 32.0f)),
        skia_scale255_3(floor(bytes.g / 32.0f)),
        skia_scale255_3(floor(bytes.b / 32.0f)));
    float luminance = floor(dot(canonical, float3(54.0f, 183.0f, 19.0f)) / 256.0f);
    return floor(luminance / 32.0f);
}

float skia_mask_gamma_entry(float sample, float index, float contrast, float gamma) {
    float src = skia_scale255_3(index) / 255.0f;
    float dst = 1.0f - src;
    float lin_src = pow(src, gamma);
    float lin_dst = pow(dst, gamma);
    float raw = round(saturate(sample) * 255.0f) / 255.0f;
    float srca = raw + (1.0f - raw) * contrast * lin_dst * raw;
    float out_value = pow(lin_src * srca + (1.0f - srca) * lin_dst, 1.0f / gamma);
    float result = (abs(src - dst) < 1.0f / 256.0f) ? srca : (out_value - dst) / (src - dst);
    return round(255.0f * result) / 255.0f;
}

float skia_mask_gamma(float sample, float3 color, float contrast, float gamma) {
    return skia_mask_gamma_entry(sample, skia_luminance_index(color), contrast, gamma);
}

float3 skia_mask_gamma3(float3 sample, float3 color, float contrast, float gamma) {
    float3 index = floor(round(saturate(color) * 255.0f) / 32.0f);
    return float3(
        skia_mask_gamma_entry(sample.r, index.r, contrast, gamma),
        skia_mask_gamma_entry(sample.g, index.g, contrast, gamma),
        skia_mask_gamma_entry(sample.b, index.b, contrast, gamma));
}
