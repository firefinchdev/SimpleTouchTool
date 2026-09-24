// Private MultitouchSupport.framework types (loaded at runtime via dlopen).
#pragma once
#include <CoreFoundation/CoreFoundation.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int fingerID;
    int handID;
    MTVector normalized;   // 0..1 across the trackpad surface
    float size;
    int zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;     // millimetres
    int zero2[2];
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef device, const MTTouch *touches, int count, double timestamp, int frame);

typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallback);
typedef void (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, MTContactCallback);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int);
typedef void (*MTDeviceStopFn)(MTDeviceRef);
