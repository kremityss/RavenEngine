#import "ESP.h"
#import "GameData.h"
#import "IL2CPP.h"
#import "Settings.h"
#import <UIKit/UIKit.h>
#include <cmath>

static void*  g_playerRootClass = nullptr;
static void*  g_playerHealthClass = nullptr;
static void*  g_playerMobViewClass = nullptr;
static void*  g_cameraCtrlClass = nullptr;

static void*  g_getTeamId = nullptr;
static void*  g_getIsVisible = nullptr;
static void*  g_getActiveMobView = nullptr;
static void*  g_getMainCamera = nullptr;
static void*  g_getRenderCamera = nullptr;
static void*  g_getHeadTransform = nullptr;
static void*  g_getChestTransform = nullptr;
static void*  g_getNeckTransform = nullptr;
static void*  g_getSpineTransform = nullptr;
static void*  g_getRKneeTransform = nullptr;
static void*  g_getPosition = nullptr;
static void*  g_worldToScreen = nullptr;

static void*  g_getHealth = nullptr;
static void*  g_getMaxHealth = nullptr;
static void*  g_getMaxArmor = nullptr;
static void*  g_getArmor = nullptr;
static void*  g_getIsDead = nullptr;
static void*  g_getIsDowned = nullptr;
static void*  g_getPlayerName = nullptr;

static void*  g_transformClass = nullptr;
static void*  g_cameraClass = nullptr;
static bool   g_worldToScreenTwoArg = false;
static bool   g_worldToViewport = false;

static void*  g_playerTransformGetter = nullptr;
static bool   g_resolved = false;

static inline bool ptrOk(void* p) {
    uintptr_t v = (uintptr_t)p;
    return v >= 0x100000000ULL && v <= 0x8000000000ULL;
}

// ---------------------------------------------------------------------------
// Liveness gate.
//
// AllPlayers is populated eagerly by the game and contains dead slots,
// spectator entries, stale spawn anchors, and pre-match placeholders.
// In the session-2 w2s block three separate "targets" all report the
// same Y and the same Z, differing only in X — the signature of three
// unspawned slots holding default positions. Both the ESP and the aim
// were treating these as real players.
//
// IsRealPlayer at 0x132 is the gate. The other three flag bytes are
// logged for verification but not used for filtering yet, because
// over-filtering is worse than the current bug: a fully empty ESP is
// harder to diagnose than a box on the ground.
// ---------------------------------------------------------------------------
static inline uint8_t readU8(void* obj, uint32_t off) {
    if (!obj) return 0;
    return *(uint8_t*)((uint8_t*)obj + off);
}

static inline bool isLiveCombatPlayer(void* p) {
    if (!ptrOk(p)) return false;
    return readU8(p, GameData::PlayerRoot::IsRealPlayer) != 0;
}

static void resolveHandles(void) {
    if (g_resolved) return;
    void* img = IL2CPP::gameImage();
    if (!img) return;

    g_playerRootClass   = IL2CPP::klass(GameData::kNsPlayer, GameData::kPlayerRootClass);
    g_playerHealthClass = IL2CPP::klass(GameData::kNsPlayer, GameData::kPlayerHealthClass);
    g_playerMobViewClass= IL2CPP::klass(GameData::kNsPlayer, GameData::kPlayerMobClass);
    g_cameraCtrlClass   = IL2CPP::klass(GameData::kNsCameraCtrl, GameData::kCameraCtrlClass);

    if (g_playerRootClass) {
        g_getTeamId        = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetTeamId, 0);
        g_getIsVisible     = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetIsVisible, 0);
        g_getActiveMobView = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetActiveMobView, 0);
        g_getMainCamera    = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetMainCamera, 0);
        g_playerTransformGetter = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetTransform, 0);
    }
    if (g_playerHealthClass) {
        g_getHealth   = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetHealth, 0);
        g_getMaxHealth = IL2CPP::resolveMethod(g_playerHealthClass, "get_MaxHealth", 0);
        g_getMaxArmor = IL2CPP::resolveMethod(g_playerHealthClass, "get_MaxArmor", 0);
        g_getArmor    = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetArmor, 0);
        g_getIsDead   = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetIsDead, 0);
        g_getIsDowned = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetIsDowned, 0);
    }
    if (g_playerMobViewClass) {
        g_getHeadTransform  = IL2CPP::resolveMethod(g_playerMobViewClass, GameData::kMGetHeadTransform, 0);
        g_getNeckTransform  = IL2CPP::resolveMethod(g_playerMobViewClass, GameData::kMGetNeckTransform, 0);
        g_getChestTransform = IL2CPP::resolveMethod(g_playerMobViewClass, GameData::kMGetChestTransform, 0);
        g_getSpineTransform = IL2CPP::resolveMethod(g_playerMobViewClass, GameData::kMGetSpineTransform, 0);
        g_getRKneeTransform = IL2CPP::resolveMethod(g_playerMobViewClass, "get_RKneeTransform", 0);
    }
    if (g_cameraCtrlClass) {
        g_getRenderCamera = IL2CPP::resolveMethod(g_cameraCtrlClass, GameData::kMGetRenderCamera, 0);
    }
    g_resolved = (g_playerRootClass && g_cameraCtrlClass && g_getTeamId &&
                  g_getActiveMobView && g_getRenderCamera);
}

static void ensureTransformHandles(void* transformObj) {
    if (!transformObj || g_transformClass) return;
    g_transformClass = IL2CPP::objectGetClass(transformObj);
    if (g_transformClass) {
        g_getPosition = IL2CPP::resolveMethod(g_transformClass, GameData::kMGetPosition, 0);
    }
}

static void ensureCameraHandles(void* cameraObj) {
    if (!cameraObj || g_cameraClass) return;
    g_cameraClass = IL2CPP::objectGetClass(cameraObj);
    if (!g_cameraClass)
        g_cameraClass = IL2CPP::klass("UnityEngine", "Camera");
    if (g_cameraClass) {
        g_worldToScreen = IL2CPP::resolveMethod(g_cameraClass, "WorldToViewportPoint", 1);
        g_worldToViewport = (g_worldToScreen != nullptr);
        if (!g_worldToScreen)
            g_worldToScreen = IL2CPP::resolveMethod(g_cameraClass, GameData::kMWorldToScreen, 1);
        if (!g_worldToScreen) {
            g_worldToScreen = IL2CPP::resolveMethod(g_cameraClass, GameData::kMWorldToScreen, 2);
            g_worldToScreenTwoArg = (g_worldToScreen != nullptr);
        }
    }
}

static inline int32_t readInt32(void* obj, uint32_t off) {
    if (!obj) return 0;
    return *(int32_t*)((uint8_t*)obj + off);
}
static inline void* readPtr(void* obj, uint32_t off) {
    if (!obj) return nullptr;
    return *(void**)((uint8_t*)obj + off);
}

static int32_t invokeInt(void* method, void* obj) {
    if (!method || !obj) return 0;
    void* r = IL2CPP::invokeMethod(method, obj, nullptr);
    return r ? *(int32_t*)((uint8_t*)r + 0x10) : 0;
}
static bool invokeBool(void* method, void* obj) {
    if (!method || !obj) return false;
    void* r = IL2CPP::invokeMethod(method, obj, nullptr);
    return r ? *(bool*)((uint8_t*)r + 0x10) : false;
}
static NSString* invokeString(void* method, void* obj) {
    if (!method || !obj) return nil;
    void* r = IL2CPP::invokeMethod(method, obj, nullptr);
    if (!ptrOk(r)) return nil;
    int32_t len = *(int32_t*)((uint8_t*)r + 0x10);
    if (len <= 0 || len > 64) return nil;
    unichar* chars = (unichar*)((uint8_t*)r + 0x14);
    return [NSString stringWithCharacters:chars length:(NSUInteger)len];
}
static void* invokePtr(void* method, void* obj) {
    if (!method || !obj) return nullptr;
    return IL2CPP::invokeMethod(method, obj, nullptr);
}

static bool readTransformPos(void* transformObj, Vec3* out) {
    if (!transformObj) return false;
    ensureTransformHandles(transformObj);
    if (!g_getPosition) return false;
    void* r = IL2CPP::invokeMethod(g_getPosition, transformObj, nullptr);
    if (!r) return false;
    *out = *(Vec3*)((uint8_t*)r + 0x10);
    return true;
}

static bool worldToScreen(void* camera, Vec3 world, CGSize scr, CGPoint* out) {
    if (!camera) return false;
    ensureCameraHandles(camera);
    if (!g_worldToScreen) return false;
    Vec3 arg = world;
    int monoEye = 0;
    void* oneArg[1] = { &arg };
    void* twoArgs[2] = { &arg, &monoEye };
    void** args = g_worldToScreenTwoArg ? twoArgs : oneArg;
    void* r = IL2CPP::invokeMethod(g_worldToScreen, camera, args);
    if (!r) return false;
    Vec3 sp = *(Vec3*)((uint8_t*)r + 0x10);
    if (sp.z < 0.01f) return false;
    if (g_worldToViewport) {
        out->x = sp.x * scr.width;
        out->y = scr.height - (sp.y * scr.height);
    } else {
        CGSize native = [UIScreen mainScreen].nativeBounds.size;
        CGFloat nativeW = MAX(native.width, native.height);
        CGFloat nativeH = MIN(native.width, native.height);
        if (nativeW < 1.0 || nativeH < 1.0) {
            CGFloat scale = MAX(1.0, [UIScreen mainScreen].scale);
            nativeW = scr.width * scale;
            nativeH = scr.height * scale;
        }
        out->x = (sp.x / nativeW) * scr.width;
        out->y = scr.height - ((sp.y / nativeH) * scr.height);
    }
    bool inRange = (out->x >= -100 && out->x <= scr.width + 100 &&
                    out->y >= -100 && out->y <= scr.height + 100);

    static int w2s_n = 0;
    if (w2s_n < 15) {
        RAVEN_LOG("w2s: mode=%s in=(%.2f,%.2f,%.2f) raw=(%.2f,%.2f,%.2f) scr=%.0fx%.0f out=(%.1f,%.1f) ok=%d",
                  g_worldToViewport ? "viewport" : "pixels",
                  world.x, world.y, world.z,
                  sp.x, sp.y, sp.z,
                  scr.width, scr.height,
                  out->x, out->y, inRange ? 1 : 0);
        w2s_n++;
    }
    return inRange;
}

static UIColor* espPaletteColor(int index) {
    if (RavenSettings::espRgb) {
        CGFloat hue = fmod(CACurrentMediaTime() * 0.18, 1.0);
        return [UIColor colorWithHue:hue saturation:0.92 brightness:1.0 alpha:0.95];
    }
    switch (index) {
        case 1: return [UIColor colorWithRed:0.20 green:0.95 blue:0.35 alpha:0.95];
        case 2: return [UIColor colorWithWhite:0.96 alpha:0.95];
        case 3: return [UIColor colorWithRed:1.00 green:0.82 blue:0.12 alpha:0.95];
        case 4: return [UIColor colorWithRed:0.15 green:0.85 blue:1.00 alpha:0.95];
        default: return [UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:0.95];
    }
}

static UIWindowScene* g_attachedScene = nil;
static CGRect g_attachedBounds = CGRectNull;

@implementation RavenESP

+ (instancetype)shared {
    static RavenESP *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RavenESP new]; });
    return s;
}

- (void)attach {
    if (self.window) return;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowLevel = UIWindowLevelNormal + 1.0;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.userInteractionEnabled = NO;
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window.hidden = YES;

    self.boxes = [CAShapeLayer layer];
    self.boxes.fillColor = [UIColor clearColor].CGColor;
    self.boxes.lineWidth = 1.5;
    self.boxes.strokeColor = RAVEN_RED.CGColor;
    self.boxes.anchorPoint = CGPointZero;
    self.boxes.position = CGPointZero;

    self.lines = [CAShapeLayer layer];
    self.lines.fillColor = [UIColor clearColor].CGColor;
    self.lines.lineWidth = 1.0;
    self.lines.strokeColor = RAVEN_RED.CGColor;
    self.lines.anchorPoint = CGPointZero;
    self.lines.position = CGPointZero;

    self.guides = [CAShapeLayer layer];
    self.guides.fillColor = [UIColor clearColor].CGColor;
    self.guides.lineWidth = 1.2;
    self.guides.strokeColor = [RAVEN_RED colorWithAlphaComponent:0.72].CGColor;
    self.guides.anchorPoint = CGPointZero;
    self.guides.position = CGPointZero;

    self.labels = [CATextLayer layer];
    self.labels.foregroundColor = RAVEN_SILVER.CGColor;
    self.labels.fontSize = 11;
    self.labels.contentsScale = [UIScreen mainScreen].scale;
    self.labels.alignmentMode = kCAAlignmentLeft;
    self.labels.wrapped = YES;
    self.labels.anchorPoint = CGPointZero;
    self.labels.position = CGPointZero;

    [self.window.layer addSublayer:self.boxes];
    [self.window.layer addSublayer:self.lines];
    [self.window.layer addSublayer:self.guides];
    [self.window.layer addSublayer:self.labels];
    [self attachToScene];
}

- (void)attachToScene {
    if (!self.window) return;
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if (![s isKindOfClass:[UIWindowScene class]]) continue;
        if (s.activationState != UISceneActivationStateForegroundActive &&
            s.activationState != UISceneActivationStateForegroundInactive) continue;

        UIWindowScene* ws = (UIWindowScene *)s;
        CGRect sceneBounds = ws.coordinateSpace.bounds;
        if (sceneBounds.size.width < 1 || sceneBounds.size.height < 1) {
            sceneBounds = [UIScreen mainScreen].bounds;
        }
        CGRect normalized = (CGRect){ CGPointZero, sceneBounds.size };
        BOOL sceneChanged = (g_attachedScene != ws || self.window.windowScene != ws);
        BOOL boundsChanged = !CGRectEqualToRect(g_attachedBounds, normalized);
        if (sceneChanged) self.window.windowScene = ws;
        if (sceneChanged || boundsChanged) {
            self.window.frame  = normalized;
            self.window.bounds = normalized;
            self.window.layer.transform = CATransform3DIdentity;

            UIViewController* root = self.window.rootViewController;
            root.view.frame = normalized;
            root.view.insetsLayoutMarginsFromSafeArea = NO;

            for (CALayer* L in @[self.boxes, self.lines, self.guides, self.labels]) {
                L.anchorPoint = CGPointZero;
                L.position    = CGPointZero;
                L.bounds      = normalized;
            }
            g_attachedScene = ws;
            g_attachedBounds = normalized;
        }

        self.window.hidden = !RavenSettings::espEnabled;

        static bool logged = false;
        if (!logged) {
            RAVEN_LOG("esp-scene: scene=%.0fx%.0f win=%@ boxes=%@ root=%@",
                      normalized.size.width, normalized.size.height,
                      NSStringFromCGRect(self.window.frame),
                      NSStringFromCGRect(self.boxes.frame),
                      NSStringFromCGRect(self.window.rootViewController.view.frame));
            logged = true;
        }
        return;
    }
}

- (void)begin {
    self.boxes.path = NULL;
    self.lines.path = NULL;
    self.guides.path = NULL;
    self.labels.string = @"";
}

- (void)end {}

- (void)drawBox:(CGRect)r color:(UIColor*)c {
    UIBezierPath *p = [UIBezierPath bezierPathWithRect:r];
    CGMutablePathRef cur = CGPathCreateMutableCopy(self.boxes.path ?: CGPathCreateMutable());
    CGPathAddPath(cur, NULL, p.CGPath);
    self.boxes.path = cur;
    CGPathRelease(cur);
    self.boxes.strokeColor = c.CGColor;
}

- (void)drawCornerBox:(CGRect)r color:(UIColor*)c {
    CGFloat cw = MAX(6.0, r.size.width * 0.28);
    CGFloat ch = MAX(6.0, r.size.height * 0.20);
    [self drawLine:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))
                to:CGPointMake(CGRectGetMinX(r) + cw, CGRectGetMinY(r)) color:c];
    [self drawLine:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))
                to:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r) + ch) color:c];
    [self drawLine:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))
                to:CGPointMake(CGRectGetMaxX(r) - cw, CGRectGetMinY(r)) color:c];
    [self drawLine:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))
                to:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r) + ch) color:c];
    [self drawLine:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))
                to:CGPointMake(CGRectGetMinX(r) + cw, CGRectGetMaxY(r)) color:c];
    [self drawLine:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))
                to:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r) - ch) color:c];
    [self drawLine:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))
                to:CGPointMake(CGRectGetMaxX(r) - cw, CGRectGetMaxY(r)) color:c];
    [self drawLine:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))
                to:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - ch) color:c];
}

- (void)drawRoundBox:(CGRect)r color:(UIColor*)c {
    UIBezierPath* p = [UIBezierPath bezierPathWithRoundedRect:r cornerRadius:MAX(4.0, MIN(12.0, r.size.width * 0.16))];
    CGMutablePathRef cur = CGPathCreateMutable();
    if (self.boxes.path) CGPathAddPath(cur, NULL, self.boxes.path);
    CGPathAddPath(cur, NULL, p.CGPath);
    self.boxes.path = cur;
    self.boxes.strokeColor = c.CGColor;
    CGPathRelease(cur);
}

- (void)drawHexBox:(CGRect)r color:(UIColor*)c {
    CGFloat cut = MAX(4.0, MIN(16.0, MIN(r.size.width, r.size.height) * 0.18));
    UIBezierPath* p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(CGRectGetMinX(r) + cut, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - cut, CGRectGetMinY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r) + cut)];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r) - cut)];
    [p addLineToPoint:CGPointMake(CGRectGetMaxX(r) - cut, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r) + cut, CGRectGetMaxY(r))];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r) - cut)];
    [p addLineToPoint:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r) + cut)];
    [p closePath];
    CGMutablePathRef cur = CGPathCreateMutable();
    if (self.boxes.path) CGPathAddPath(cur, NULL, self.boxes.path);
    CGPathAddPath(cur, NULL, p.CGPath);
    self.boxes.path = cur;
    self.boxes.strokeColor = c.CGColor;
    CGPathRelease(cur);
}

- (void)drawGradientBox:(CGRect)r color:(UIColor*)c {
    [self drawBox:r color:[c colorWithAlphaComponent:0.58]];
    [self drawLine:CGPointMake(CGRectGetMinX(r), CGRectGetMinY(r))
                to:CGPointMake(CGRectGetMaxX(r), CGRectGetMinY(r))
             color:[c colorWithAlphaComponent:1.0]];
    [self drawLine:CGPointMake(CGRectGetMinX(r), CGRectGetMaxY(r))
                to:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))
             color:[c colorWithAlphaComponent:0.28]];
}

- (void)drawEliteBox:(CGRect)r color:(UIColor*)c {
    [self drawRoundBox:r color:c];
    CGRect inner = CGRectInset(r, 3.0, 3.0);
    [self drawCornerBox:inner color:[c colorWithAlphaComponent:0.52]];
}

- (void)drawLine:(CGPoint)a to:(CGPoint)b color:(UIColor*)c {
    CGMutablePathRef cur = CGPathCreateMutableCopy(self.lines.path ?: CGPathCreateMutable());
    CGPathMoveToPoint(cur, NULL, a.x, a.y);
    CGPathAddLineToPoint(cur, NULL, b.x, b.y);
    self.lines.path = cur;
    CGPathRelease(cur);
    self.lines.strokeColor = c.CGColor;
}

- (void)drawGuideCircle:(CGPoint)center radius:(CGFloat)radius color:(UIColor*)c {
    if (radius <= 0.0) return;
    UIBezierPath* p = [UIBezierPath bezierPathWithArcCenter:center
                                                       radius:radius
                                                   startAngle:0
                                                     endAngle:(CGFloat)(M_PI * 2.0)
                                                    clockwise:YES];
    CGMutablePathRef cur = CGPathCreateMutableCopy(self.guides.path ?: CGPathCreateMutable());
    CGPathAddPath(cur, NULL, p.CGPath);
    self.guides.path = cur;
    CGPathRelease(cur);
    self.guides.strokeColor = c.CGColor;
}

- (void)render {
    BOOL guidesEnabled = RavenSettings::aimShowCircle || RavenSettings::visCrosshair || RavenSettings::visFovCircle || RavenSettings::espHeadDot;
    if (!RavenSettings::espEnabled && !guidesEnabled) {
        // Clear stale paths and hide the overlay even when there is no
        // guide/ESP work left for the frame loop to request.
        if (self.window) {
            [self begin];
            self.window.hidden = YES;
        }
        return;
    }
    if (!self.window) [self attach];
    [self attachToScene];
    self.window.hidden = NO;
    self.guides.hidden = !guidesEnabled;
    self.boxes.hidden = !RavenSettings::espEnabled;
    self.lines.hidden = !RavenSettings::espEnabled;
    self.labels.hidden = !RavenSettings::espEnabled;
    [self begin];

    CGSize guideScreen = self.window.bounds.size;
    CGPoint guideCenter = CGPointMake(guideScreen.width / 2.0, guideScreen.height / 2.0);
    if (RavenSettings::aimShowCircle) {
        CGFloat radius = MAX(1.0f, RavenSettings::aimCircleRadius);
        [self drawGuideCircle:guideCenter radius:radius color:[RAVEN_RED colorWithAlphaComponent:0.78]];
        self.guides.lineWidth = MAX(1.0f, RavenSettings::aimCircleThickness);
    }
    if (RavenSettings::visFovCircle) {
        [self drawGuideCircle:guideCenter radius:RavenSettings::visFovRadius
                         color:[UIColor colorWithRed:0.95 green:0.75 blue:0.20 alpha:0.78]];
        self.guides.lineWidth = MAX(1.0f, RavenSettings::visFovThickness);
    }
    if (RavenSettings::visCrosshair) {
        CGFloat s = MAX(2.0f, RavenSettings::visCrosshairSize);
        CGFloat t = MAX(1.0f, RavenSettings::visCrosshairThickness);
        UIColor* cc = [UIColor colorWithRed:0.95 green:0.95 blue:0.95 alpha:0.90];
        if (RavenSettings::visCrosshairStyle == 0) {
            [self drawGuideCircle:guideCenter radius:t color:cc];
        } else if (RavenSettings::visCrosshairStyle == 2) {
            [self drawGuideCircle:guideCenter radius:s color:cc];
        } else {
            [self drawLine:CGPointMake(guideCenter.x - s, guideCenter.y)
                        to:CGPointMake(guideCenter.x + s, guideCenter.y) color:cc];
            [self drawLine:CGPointMake(guideCenter.x, guideCenter.y - s)
                        to:CGPointMake(guideCenter.x, guideCenter.y + s) color:cc];
            if (RavenSettings::visCrosshairStyle == 3)
                [self drawLine:CGPointMake(guideCenter.x - s, guideCenter.y + s)
                            to:CGPointMake(guideCenter.x + s, guideCenter.y + s) color:cc];
        }
        self.guides.lineWidth = t;
    }
    if (!RavenSettings::espEnabled) return;
    resolveHandles();

    static double espSigAt = 0.0;
    double espSigNow = CACurrentMediaTime();
    if (espSigNow - espSigAt >= 1.0) {
        espSigAt = espSigNow;
        RAVEN_LOG("esp: pc=%p local=%p list=%p cam=%p tf=%p",
                  g_playerRootClass,
                  IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldMyPlayer),
                  IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldAllPlayers),
                  g_getMainCamera, g_playerTransformGetter);
    }

    static bool bounds_logged = false;
    if (!bounds_logged) {
        CGSize s = [UIScreen mainScreen].bounds.size;
        CGFloat sc = [UIScreen mainScreen].scale;
        RAVEN_LOG("esp-bounds: pts=%.0fx%.0f scale=%.2f px=%.0fx%.0f",
                  s.width, s.height, sc, s.width * sc, s.height * sc);
        bounds_logged = true;
    }

    if (!g_playerRootClass) return;

    void* localPlayer = IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldMyPlayer);
    if (!ptrOk(localPlayer)) return;

    void* list = IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldAllPlayers);
    if (!ptrOk(list)) return;

    void* itemsArray = readPtr(list, GameData::List::Items);
    int   count      = readInt32(list, GameData::List::Size);
    if (!ptrOk(itemsArray) || count <= 0 || count > 200) return;
    void** items = (void**)((uint8_t*)itemsArray + GameData::Array::Data);

    int localTeam = g_getTeamId ? invokeInt(g_getTeamId, localPlayer) : 0;

    void* camera = nullptr;
    {
        void* localCamCtrl = readPtr(localPlayer, GameData::PlayerRoot::CameraController);
        if (ptrOk(localCamCtrl) && g_getRenderCamera)
            camera = invokePtr(g_getRenderCamera, localCamCtrl);
    }
    if (!ptrOk(camera) && g_getMainCamera)
        camera = invokePtr(g_getMainCamera, localPlayer);
    if (!ptrOk(camera)) return;

    static bool cam_logged = false;
    if (!cam_logged) {
        void* camCtrl = readPtr(localPlayer, GameData::PlayerRoot::CameraController);
        RAVEN_LOG("esp-cam: camCtrl=%p renderCam=%p mainCam=%p chosen=%p",
                  camCtrl,
                  (camCtrl && g_getRenderCamera) ? invokePtr(g_getRenderCamera, camCtrl) : nullptr,
                  g_getMainCamera ? invokePtr(g_getMainCamera, localPlayer) : nullptr,
                  camera);
        cam_logged = true;
    }

    Vec3 localPos = {0,0,0};
    void* localTransform = g_playerTransformGetter ? invokePtr(g_playerTransformGetter, localPlayer) : nullptr;
    if (ptrOk(localTransform)) readTransformPos(localTransform, &localPos);

    CGSize screen = self.window.bounds.size;
    NSMutableString* labels = [NSMutableString string];

    static bool controls_logged = false;
    if (!controls_logged) {
        RAVEN_LOG("esp-controls: esp=%d box=%d corner=%d snap=%d aimCircle=%d aimRadius=%.1f visCircle=%d visRadius=%.1f crosshair=%d",
                  RavenSettings::espEnabled, RavenSettings::espBox,
                  RavenSettings::espCorner, RavenSettings::espSnaplines,
                  RavenSettings::aimShowCircle, RavenSettings::aimCircleRadius,
                  RavenSettings::visFovCircle, RavenSettings::visFovRadius,
                  RavenSettings::visCrosshair);
        controls_logged = true;
    }


    // -------------------------------------------------------------------
    // Slot dump. One pass per match (bound to localPlayer change), first
    // 24 slots only. This is what tells us whether IsRealPlayer at 0x132
    // actually distinguishes live players from phantom slots. If every
    // slot logs real=0, no boxes render and the offset is wrong. If
    // every slot logs real=1, the offset is wrong in the other
    // direction and the filter is a no-op.
    //
    // Run once. Grep the log for slot[ and check the correlation between
    // real= and whether the ESP drew a box on that slot.
    // -------------------------------------------------------------------
    static void* s_slotDumpMatch = nullptr;
    static int   s_slotDumpCount = 0;
    if (s_slotDumpMatch != localPlayer) {
        s_slotDumpMatch = localPlayer;
        s_slotDumpCount = 0;
    }

    for (int i = 0; i < count; i++) {
        void* p = items[i];
        if (!p || p == localPlayer) continue;
        if (!ptrOk(p)) continue;

        int team = g_getTeamId ? invokeInt(g_getTeamId, p) : 0;
        if (!RavenSettings::espTeam && team != 0 && team == localTeam) continue;
        uint8_t bOwner   = readU8(p, GameData::PlayerRoot::IsOwner);
        uint8_t bCtrl    = readU8(p, GameData::PlayerRoot::HasControl);
        uint8_t bVisible = readU8(p, GameData::PlayerRoot::IsVisible);
        uint8_t bReal    = readU8(p, GameData::PlayerRoot::IsRealPlayer);
        if (RavenSettings::espVisibleOnly && !bVisible) continue;

        if (s_slotDumpCount < 24) {
            RAVEN_LOG("slot[%d] p=%p team=%d owner=%u ctrl=%u vis=%u real=%u",
                      i, p, team, bOwner, bCtrl, bVisible, bReal);
            s_slotDumpCount++;
        }

        void* healthComp = readPtr(p, GameData::PlayerRoot::PlayerHealth);
        if (ptrOk(healthComp)) {
            if (g_getIsDead && invokeBool(g_getIsDead, healthComp)) continue;
            if (g_getIsDowned && invokeBool(g_getIsDowned, healthComp)) continue;
        }

        void* rootTransform = g_playerTransformGetter ? invokePtr(g_playerTransformGetter, p) : nullptr;
        Vec3 feetPos = {0,0,0};
        if (!ptrOk(rootTransform) || !readTransformPos(rootTransform, &feetPos)) continue;

        Vec3 headPos = feetPos;
        void* mobView = (g_getActiveMobView) ? invokePtr(g_getActiveMobView, p) : nullptr;
        if (!ptrOk(mobView)) mobView = nullptr;
        void* headTransform = (mobView && g_getHeadTransform)
            ? invokePtr(g_getHeadTransform, mobView) : nullptr;
        if (!ptrOk(headTransform) || !readTransformPos(headTransform, &headPos)) {
            headPos.y += 1.8f;
        }

        // -----------------------------------------------------------------
        // Bone height sanity. Session-2 w2s pairs show a head/feet delta
        // of 1.34 m on a standing player. Real standing height is 1.7-
        // 1.8 m; 1.34 m reads as either a crouch, a neck/chest bone, or a
        // head transform whose local-space position was read as world
        // space because the mob view's transform had gone stale. Any of
        // those corrupts the box height, which in turn corrupts the FOV
        // test in the aim path via the shared geometry.
        //
        // Fall back to a plausible standing height when the delta is out
        // of range. Do not skip the target — a suspicious height is a
        // signal, not a rejection.
        // -----------------------------------------------------------------
        float height = headPos.y - feetPos.y;
        if (height < 0.6f || height > 2.5f) {
            static int boneWarnCount = 0;
            if (boneWarnCount < 8) {
                RAVEN_LOG("esp-bone: height=%.2f head=(%.2f,%.2f,%.2f) feet=(%.2f,%.2f,%.2f)",
                          height,
                          headPos.x, headPos.y, headPos.z,
                          feetPos.x, feetPos.y, feetPos.z);
                boneWarnCount++;
            }
            headPos.y = feetPos.y + 1.75f;
        }

        CGPoint headScreen, feetScreen;
        if (!worldToScreen(camera, headPos, screen, &headScreen)) continue;
        if (!worldToScreen(camera, feetPos, screen, &feetScreen)) continue;

        float boxH = static_cast<float>(std::abs(feetScreen.y - headScreen.y));
        if (boxH < 4 || boxH > 2000) continue;
        float boxScale = fmaxf(0.7f, fminf(1.8f, RavenSettings::espBoxScale));
        boxH *= boxScale;
        float boxW = boxH * 0.42f;
        CGFloat boxTop = feetScreen.y - boxH;

        CGRect boxRect = CGRectMake(headScreen.x - boxW/2.0, boxTop, boxW, boxH);
        UIColor* boxColor = (team != 0 && team == localTeam)
            ? espPaletteColor(RavenSettings::espVisibleColor)
            : espPaletteColor(bVisible ? RavenSettings::espVisibleColor : RavenSettings::espEnemyColor);
        if (RavenSettings::espBox) {
            switch (RavenSettings::espBoxStyle) {
                case 1: [self drawHexBox:boxRect color:boxColor]; break;
                case 2: [self drawRoundBox:boxRect color:boxColor]; break;
                case 3: [self drawGradientBox:boxRect color:boxColor]; break;
                case 4: [self drawEliteBox:boxRect color:boxColor]; break;
                default:
                    if (RavenSettings::espCorner) [self drawCornerBox:boxRect color:boxColor];
                    else [self drawBox:boxRect color:boxColor];
                    break;
            }
        }

        if (RavenSettings::espHeadDot) {
            [self drawGuideCircle:headScreen radius:MAX(2.0, boxH * 0.035) color:boxColor];
        }
        if (ptrOk(healthComp)) {
            int hp = g_getHealth ? invokeInt(g_getHealth, healthComp) : 0;
            int maxHp = g_getMaxHealth ? invokeInt(g_getMaxHealth, healthComp) : 0;
            if (RavenSettings::espHealthBar && maxHp > 0) {
                CGFloat ratio = fmax(0.0, fmin(1.0, (CGFloat)hp / (CGFloat)maxHp));
                CGPoint a = CGPointMake(CGRectGetMinX(boxRect) - 4.0, CGRectGetMaxY(boxRect));
                CGPoint b = CGPointMake(a.x, CGRectGetMaxY(boxRect) - boxRect.size.height * ratio);
                [self drawLine:a to:b color:[UIColor colorWithRed:0.15 green:0.95 blue:0.35 alpha:0.9]];
            }
            if (RavenSettings::espArmorBar && g_getArmor && g_getMaxArmor) {
                int armor = invokeInt(g_getArmor, healthComp);
                int maxArmor = invokeInt(g_getMaxArmor, healthComp);
                if (maxArmor > 0) {
                    CGFloat ratio = fmax(0.0, fmin(1.0, (CGFloat)armor / (CGFloat)maxArmor));
                    CGPoint a = CGPointMake(CGRectGetMaxX(boxRect) + 4.0, CGRectGetMaxY(boxRect));
                    CGPoint b = CGPointMake(a.x, CGRectGetMaxY(boxRect) - boxRect.size.height * ratio);
                    [self drawLine:a to:b color:[UIColor colorWithRed:0.20 green:0.65 blue:1.0 alpha:0.9]];
                }
            }
        }

        if (RavenSettings::espSnaplines) {
            CGFloat snapY = RavenSettings::espSnaplinePosition == 0 ? 0.0 :
                            (RavenSettings::espSnaplinePosition == 1 ? screen.height * 0.5 : screen.height);
            [self drawLine:CGPointMake(screen.width / 2.0, snapY)
                        to:CGPointMake(headScreen.x, feetScreen.y)
                     color:[UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:0.55]];
        }

        if (RavenSettings::espSkeleton && mobView) {
            UIColor* skeletonColor = espPaletteColor(RavenSettings::espSkeletonColor);
            void* boneMethods[5] = { g_getHeadTransform, g_getNeckTransform,
                                     g_getChestTransform, g_getSpineTransform,
                                     g_getRKneeTransform };
            CGPoint projected[5];
            bool visible[5] = { false, false, false, false, false };
            for (int boneIndex = 0; boneIndex < 5; boneIndex++) {
                void* transformMethod = boneMethods[boneIndex];
                void* transform = transformMethod ? invokePtr(transformMethod, mobView) : nullptr;
                Vec3 position = {0, 0, 0};
                visible[boneIndex] = ptrOk(transform) && readTransformPos(transform, &position) &&
                                     worldToScreen(camera, position, screen, &projected[boneIndex]);
            }
            for (int boneIndex = 0; boneIndex < 4; boneIndex++) {
                if (visible[boneIndex] && visible[boneIndex + 1])
                    [self drawLine:projected[boneIndex] to:projected[boneIndex + 1] color:skeletonColor];
            }
        }

        NSMutableString* line = [NSMutableString string];
        if (RavenSettings::espName) {
            NSString* name = invokeString(g_getPlayerName, p);
            if (!name.length) name = [NSString stringWithFormat:@"Player %d", i];
            [line appendFormat:@"%@ ", name];
        }
        if (RavenSettings::espHealth && ptrOk(healthComp) && g_getHealth) {
            int32_t hp = invokeInt(g_getHealth, healthComp);
            [line appendFormat:@"HP:%d ", hp];
            if (g_getArmor) [line appendFormat:@"AR:%d ", invokeInt(g_getArmor, healthComp)];
        }
        if (RavenSettings::espDistance) {
            Vec3 d = {feetPos.x - localPos.x, feetPos.y - localPos.y, feetPos.z - localPos.z};
            float dist = sqrtf(d.x*d.x + d.y*d.y + d.z*d.z);
            [line appendFormat:@"%.0fm", dist];
        }
        if (line.length > 0) {
            [labels appendFormat:@"%.0f,%.0f|%@\n", headScreen.x, headScreen.y - 14, line];
        }
    }

    self.labels.string = labels;
}

- (NSArray<NSString*>*)snapshotPlayerRows {
    resolveHandles();
    NSMutableArray<NSString*>* rows = [NSMutableArray array];
    if (!g_playerRootClass) return rows;
    void* local = IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldMyPlayer);
    void* list = IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldAllPlayers);
    if (!ptrOk(local) || !ptrOk(list)) return rows;
    void* array = readPtr(list, GameData::List::Items);
    int count = MIN(64, MAX(0, readInt32(list, GameData::List::Size)));
    if (!ptrOk(array) || count <= 0) return rows;
    void** items = (void**)((uint8_t*)array + GameData::Array::Data);
    int localTeam = g_getTeamId ? invokeInt(g_getTeamId, local) : 0;
    for (int i = 0; i < count; i++) {
        void* p = items[i];
        if (!ptrOk(p) || p == local) continue;
        int team = g_getTeamId ? invokeInt(g_getTeamId, p) : 0;
        if (team != 0 && team == localTeam) continue;
        void* health = readPtr(p, GameData::PlayerRoot::PlayerHealth);
        if (ptrOk(health) && ((g_getIsDead && invokeBool(g_getIsDead, health)) ||
                              (g_getIsDowned && invokeBool(g_getIsDowned, health)))) continue;
        NSString* name = invokeString(g_getPlayerName, p);
        if (!name.length) name = [NSString stringWithFormat:@"Player %d", i];
        NSString* state = (g_getIsVisible && invokeBool(g_getIsVisible, p)) ? @"VISIBLE" : @"HIDDEN";
        [rows addObject:[NSString stringWithFormat:@"%@  •  CONNECTED  •  TEAM %d  •  %@", name, team, state]];
    }
    return rows;
}

@end
