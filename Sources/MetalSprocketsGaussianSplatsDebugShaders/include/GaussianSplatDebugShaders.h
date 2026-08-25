#pragma once
#import "GaussianSplatShaders.h"

struct DebugDistanceParams {
    simd_float3 center;
    float maxDistance;
};

struct DebugSizeParams {
    float minSize;
    float maxSize;
};

struct DebugDepthParams {
    float minDepth;
    float maxDepth;
};

struct DebugAspectRatioParams {
    float minRatio;
    float maxRatio;
};

#define MAX_DEBUG_CLOUD_COLORS 16

struct DebugCloudIndexParams {
    unsigned int cloudCount;
    simd_float3 cloudColors[MAX_DEBUG_CLOUD_COLORS];
};
