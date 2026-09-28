#ifndef RAVEN_COMMON_H
#define RAVEN_COMMON_H

#include <cstdint>
#include <cstddef>

#import <Foundation/Foundation.h>
#import <os/log.h>

#define RAVEN_LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "[raven] " fmt, ##__VA_ARGS__)

#define RAVEN_LOCAL_VERSION "1.0.0"

struct Vec3 { float x, y, z; };
struct Vec2 { float x, y; };
struct Matrix4x4 { float m[16]; };

#define RAVEN_RED    [UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:1.0]
#define RAVEN_SILVER [UIColor colorWithRed:0.949 green:0.949 blue:0.957 alpha:1.0]
#define RAVEN_GREY   [UIColor colorWithRed:0.573 green:0.573 blue:0.608 alpha:1.0]

#endif
