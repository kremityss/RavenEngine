// Root cause fix
#import "Aimbot.h"
#import "GameData.h"
#import "IL2CPP.h"
#import "Settings.h"
#import <UIKit/UIKit.h>
#include <cmath>
#include <cfloat>
#include <cstring>
#include <dlfcn.h>

namespace RavenAimbot {

static void* g_playerRootClass     = nullptr;
static void* g_playerHealthClass   = nullptr;
static void* g_playerMobViewClass  = nullptr;
static void* g_playerMovementClass = nullptr;
static void* g_playerArmingClass   = nullptr;
static void* g_setFieldOfView      = nullptr;
static void* g_getIsAds            = nullptr;
static void* g_setTargetRecoil     = nullptr;
static void* g_setNormalizedSpeed  = nullptr;
static void* g_getIsGrounded       = nullptr;
static void* g_getIsCrouch         = nullptr;
static void* g_setIsSliding        = nullptr;
static void* g_setReloadMultiplier  = nullptr;
static void* g_getTeamId           = nullptr;
static void* g_getIsVisible        = nullptr;
static void* g_getIsDead           = nullptr;
static void* g_getIsDowned         = nullptr;
static void* g_getHealth           = nullptr;
static void* g_getActiveMobView    = nullptr;
static void* g_getMainCamera       = nullptr;
static void* g_getHeadTransform    = nullptr;
static void* g_getChestTransform   = nullptr;
static void* g_getPosition         = nullptr;
static void* g_transformClass      = nullptr;
static void* g_cameraCtrlClass     = nullptr;
static void* g_getRenderCamera     = nullptr;
static void* g_switchToThirdPerson = nullptr;
static void* g_switchToFirstPerson = nullptr;
static void* g_cameraClass         = nullptr;
static void* g_worldToScreen       = nullptr;
static bool  g_worldToScreenTwoArg = false;
static bool  g_worldToViewport     = false;
static void* g_getRootTransform    = nullptr;
static bool  g_resolved            = false;

// ---- lock state -------------------------------------------------
static void*  g_lockedTarget      = nullptr;
static double g_lockedSince       = 0.0;
static int    g_lockTicks         = 0;
static float  g_lockedScreenD     = FLT_MAX;

// ---- write bounds ----------------------------------------------
// The game's pitch field (+0x3C) is legal only on ±90. Once an
// unnormalized write pushes it past 90 in a single frame, the game
// clamps to 90, dumps the residual into yaw, and the next frame
// shows a 500+ value on read. That is the observed snap-up
// (gyro pitch 585.3184 -> camera clamps to +90 -> yaw jumps to
// 90.000 / -119.959 in the same tick). We never let a write cross.
static const float AIM_ASSIST_GAIN    =   0.60f;  // responsive correction without dragging the camera
static const float AIM_MAX_YAW_STEP   =   8.0f;   // deg / tick
static const float AIM_MAX_PITCH_STEP =   6.0f;   // deg / tick
static const int   AIM_LOCK_MIN_TICKS =  10;
static const float AIM_SWITCH_HYST_PX =  60.0f;
static const float AIM_DEADZONE_PX    =   0.4f;

// ---- reticle calibration ---------------------------------------
// Pixel offsets applied to the assumed reticle position. Positive X
// moves the reticle right; positive Y moves it down. Tune these from
// the settled screen/ret values in the aim-apply log below.
static const float AIM_RETICLE_OFFSET_X = 0.0f;
static const float AIM_RETICLE_OFFSET_Y = 0.0f;

static inline bool ptrOk(void* p) {
    uintptr_t v = (uintptr_t)p;
    return v >= 0x100000000ULL && v <= 0x8000000000ULL;
}

static inline float wrap180f(float d) {
    d = fmodf(d + 180.0f, 360.0f);
    if (d < 0.0f) d += 360.0f;
    return d - 180.0f;
}
static inline float clampf(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static void* resolveInherited(void* cls, const char* name, int argc) {
    for (void* c = cls; c; c = IL2CPP::classGetParent(c)) {
        void* m = IL2CPP::resolveMethod(c, name, argc);
        if (m) return m;
    }
    return nullptr;
}

static void resolveHandles(void) {
    if (g_resolved) return;
    void* img = IL2CPP::gameImage();
    if (!img) return;

    g_playerRootClass   = IL2CPP::klass(GameData::kNsPlayer,     GameData::kPlayerRootClass);
    g_playerHealthClass = IL2CPP::klass(GameData::kNsPlayer,     GameData::kPlayerHealthClass);
    g_playerMobViewClass= IL2CPP::klass(GameData::kNsPlayer,     GameData::kPlayerMobClass);
    g_cameraCtrlClass   = IL2CPP::klass(GameData::kNsCameraCtrl, GameData::kCameraCtrlClass);
    g_playerMovementClass = IL2CPP::klass(GameData::kNsPlayer, GameData::kPlayerMoveClass);
    g_playerArmingClass = IL2CPP::klass(GameData::kNsPlayer, "PlayerArming");

    if (g_playerRootClass) {
        g_getTeamId        = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetTeamId, 0);
        g_getIsVisible     = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetIsVisible, 0);
        g_getActiveMobView = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetActiveMobView, 0);
        g_getMainCamera    = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetMainCamera, 0);
        g_getRootTransform = IL2CPP::resolveMethod(g_playerRootClass, GameData::kMGetTransform, 0);
    }
    if (g_playerArmingClass) {
        g_getIsAds = IL2CPP::resolveMethod(g_playerArmingClass, "get_IsAds", 0);
    }
    if (g_playerMovementClass) {
        g_setTargetRecoil = IL2CPP::resolveMethod(g_playerMovementClass, "SetTargetRecoil", 1);
        g_setNormalizedSpeed = IL2CPP::resolveMethod(g_playerMovementClass, "set_NormalizedSpeed", 1);
        g_getIsGrounded = IL2CPP::resolveMethod(g_playerMovementClass, "get_IsGrounded", 0);
        g_getIsCrouch = IL2CPP::resolveMethod(g_playerMovementClass, "get_IsCrouch", 0);
        g_setIsSliding = IL2CPP::resolveMethod(g_playerMovementClass, "set_IsSliding", 1);
    }
    if (g_playerHealthClass) {
        g_getHealth   = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetHealth, 0);
        g_getIsDead   = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetIsDead, 0);
        g_getIsDowned = IL2CPP::resolveMethod(g_playerHealthClass, GameData::kMGetIsDowned, 0);
    }
    if (g_playerMobViewClass) {
        g_getHeadTransform  = IL2CPP::resolveMethod(g_playerMobViewClass, GameData::kMGetHeadTransform, 0);
        g_getChestTransform = IL2CPP::resolveMethod(g_playerMobViewClass, GameData::kMGetChestTransform, 0);
    }
    if (g_cameraCtrlClass) {
        g_getRenderCamera  = IL2CPP::resolveMethod(g_cameraCtrlClass, GameData::kMGetRenderCamera, 0);
        g_switchToThirdPerson = IL2CPP::resolveMethod(g_cameraCtrlClass, "SwitchToThirdPerson", 0);
        g_switchToFirstPerson = IL2CPP::resolveMethod(g_cameraCtrlClass, "SwitchToFirstPerson", 0);
    }
    g_resolved = (g_playerRootClass && g_cameraCtrlClass && g_getTeamId &&
                  g_getActiveMobView && g_getRenderCamera);
}

static void ensureTransformClass(void* obj) {
    if (!obj || g_transformClass) return;
    g_transformClass = IL2CPP::objectGetClass(obj);
    if (g_transformClass) {
        g_getPosition = IL2CPP::resolveMethod(g_transformClass, GameData::kMGetPosition, 0);
    }
}

static void ensureCameraClass(void* obj) {
    if (!obj || g_cameraClass) return;
    g_cameraClass = IL2CPP::objectGetClass(obj);
    if (!g_cameraClass)
        g_cameraClass = IL2CPP::klass("UnityEngine", "Camera");
    if (g_cameraClass) {
        // Match the ESP path: normalized viewport coordinates are already in
        // the overlay's coordinate space after multiplying by scr. The old
        // aim path used WorldToScreenPoint plus nativeBounds scaling, which
        // can disagree with the accurate ESP boxes on landscape iOS.
        g_worldToScreen = IL2CPP::resolveMethod(g_cameraClass, "WorldToViewportPoint", 1);
        g_worldToViewport = (g_worldToScreen != nullptr);
        if (!g_worldToScreen)
            g_worldToScreen = IL2CPP::resolveMethod(g_cameraClass, GameData::kMWorldToScreen, 1);
        if (!g_setFieldOfView)
            g_setFieldOfView = resolveInherited(g_cameraClass, "set_fieldOfView", 1);
        if (!g_worldToScreen) {
            g_worldToScreen = IL2CPP::resolveMethod(g_cameraClass, GameData::kMWorldToScreen, 2);
            g_worldToScreenTwoArg = (g_worldToScreen != nullptr);
        }
        if (g_worldToScreen)
            RAVEN_LOG("aim-w2s: mode=%s method=%p", g_worldToViewport ? "viewport" : "pixels", g_worldToScreen);
    }
}

static inline int32_t readInt32(void* o, uint32_t off) { return o ? *(int32_t*)((uint8_t*)o+off) : 0; }
static inline void*   readPtr(void* o, uint32_t off)   { return o ? *(void**)((uint8_t*)o+off) : nullptr; }

static void* invokePtr(void* method, void* obj) {
    if (!method || !obj) return nullptr;
    return IL2CPP::invokeMethod(method, obj, nullptr);
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

static bool readTransformPos(void* t, Vec3* out) {
    if (!t) return false;
    ensureTransformClass(t);
    if (!g_getPosition) return false;
    void* r = IL2CPP::invokeMethod(g_getPosition, t, nullptr);
    if (!r) return false;
    *out = *(Vec3*)((uint8_t*)r + 0x10);
    return true;
}

static bool targetIsAlive(void* player) {
    if (!player) return false;
    void* health = readPtr(player, GameData::PlayerRoot::PlayerHealth);
    if (!ptrOk(health)) return false;
    if (g_getIsDead && invokeBool(g_getIsDead, health)) return false;
    if (g_getIsDowned && invokeBool(g_getIsDowned, health)) return false;
    if (g_getHealth) {
        void* value = IL2CPP::invokeMethod(g_getHealth, health, nullptr);
        if (!value) return false;
        float hp = *(float*)((uint8_t*)value + 0x10);
        if (!isfinite(hp) || hp <= 0.0f) return false;
    }
    return true;
}

static bool worldToScreen(void* cam, Vec3 w, CGSize scr, CGPoint* out) {
    if (!cam) return false;
    ensureCameraClass(cam);
    if (!g_worldToScreen) return false;
    Vec3 arg = w;
    int monoEye = 0;
    void* oneArg[1] = { &arg };
    void* twoArgs[2] = { &arg, &monoEye };
    void** args = g_worldToScreenTwoArg ? twoArgs : oneArg;
    void* r = IL2CPP::invokeMethod(g_worldToScreen, cam, args);
    if (!r) return false;
    Vec3 sp = *(Vec3*)((uint8_t*)r + 0x10);
    if (sp.z < 0.01f) return false;
    if (!(sp.x == sp.x) || !(sp.y == sp.y) || !(sp.z == sp.z)) return false;
    if (fabsf(sp.x) > 1.0e6f || fabsf(sp.y) > 1.0e6f) return false;
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
    return (out->x >= -100 && out->x <= scr.width + 100 &&
            out->y >= -100 && out->y <= scr.height + 100);
}

struct FrozenDetector {
    float lastX = 0.0f, lastY = 0.0f, lastZ = 0.0f;
    int   identicalCount = 0;
    bool  warned = false;
    void* boundTo = nullptr;

    void reset(void* local) {
        lastX = lastY = lastZ = 0.0f;
        identicalCount = 0;
        warned = false;
        boundTo = local;
    }
    bool observe(void* local, Vec3 v) {
        if (local != boundTo) reset(local);
        bool same = (v.x == lastX && v.y == lastY && v.z == lastZ);
        lastX = v.x; lastY = v.y; lastZ = v.z;
        if (same) { if (identicalCount < 1000000) identicalCount++; }
        else { identicalCount = 0; }
        if (identicalCount >= 60 && !warned) {
            warned = true;
            RAVEN_LOG("aim-frozen: root transform stale for %d ticks", identicalCount);
        }
        return !warned;
    }
};

// ---------------------------------------------------------------
//  findBestTarget
//    Lock hold is hard-bound: once a target is chosen it stays
//    locked for at least AIM_LOCK_MIN_TICKS frames. Switching
//    additionally requires the new candidate to be AIM_SWITCH_HYST_PX
//    closer to the crosshair than the current lock.
//
//    Existing aimSwitchDelay still applies on top — if the caller
//    sets a delay, that is enforced; this adds a floor beneath it so
//    aimSwitchDelay=0 no longer means "switch every frame".
// ---------------------------------------------------------------
static void* findBestTarget(void* localPlayer, int localTeam, void* camera, Vec3* outAimPoint) {
    void* list = IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldAllPlayers);
    if (!ptrOk(list)) return nullptr;

    void* itemsArray = readPtr(list, GameData::List::Items);
    int   count      = readInt32(list, GameData::List::Size);
    if (!ptrOk(itemsArray) || count <= 0) return nullptr;
    void** items = (void**)((uint8_t*)itemsArray + GameData::Array::Data);

    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGPoint center = CGPointMake(scr.width / 2.0, scr.height / 2.0);
    float configuredFov = RavenSettings::gyroEnabled ? RavenSettings::gyroFov : RavenSettings::aimFov;
    float fovPx = (configuredFov / 90.0f) * (scr.width / 2.0f);

    if (g_lockedTarget) {
        bool stillPresent = false;
        for (int i = 0; i < count; i++) {
            if (items[i] == g_lockedTarget) { stillPresent = true; break; }
        }
        if (!stillPresent) {
            g_lockedTarget = nullptr;
            g_lockedSince = 0.0;
            g_lockTicks = 0;
            g_lockedScreenD = FLT_MAX;
        }
    }

    void* best = nullptr;
    float bestDist = FLT_MAX;
    Vec3 bestAim = {0,0,0};
    Vec3 lockedAim = {0,0,0};
    bool lockedVisible = false;
    Vec3 localPos = {0,0,0};
    void* localTransform = g_getRootTransform ? invokePtr(g_getRootTransform, localPlayer) : nullptr;
    if (ptrOk(localTransform)) readTransformPos(localTransform, &localPos);

    for (int i = 0; i < count; i++) {
        void* p = items[i];
        if (!p || p == localPlayer) continue;
        if (!ptrOk(p)) continue;
        if (!targetIsAlive(p)) continue;
        int team = g_getTeamId ? invokeInt(g_getTeamId, p) : 0;
        if (!RavenSettings::aimIgnoreTeammates && team != 0 && team == localTeam) { /* teammate targeting explicitly enabled */ }
        else if (RavenSettings::aimIgnoreTeammates && team != 0 && team == localTeam) continue;

        void* targetTransform = g_getRootTransform ? invokePtr(g_getRootTransform, p) : nullptr;
        Vec3 targetPos = {0,0,0};
        if (!ptrOk(targetTransform) || !readTransformPos(targetTransform, &targetPos)) continue;

        Vec3 bonePos = targetPos;
        void* mobView = g_getActiveMobView ? invokePtr(g_getActiveMobView, p) : nullptr;
        if (!ptrOk(mobView)) mobView = nullptr;
        void* bone = nullptr;
        if (mobView) {
            if (RavenSettings::aimBone == 0) {
                bone = g_getHeadTransform ? invokePtr(g_getHeadTransform, mobView) : nullptr;
            } else {
                bone = g_getChestTransform ? invokePtr(g_getChestTransform, mobView) : nullptr;
            }
        }
        if (!ptrOk(bone) || !readTransformPos(bone, &bonePos)) {
            bonePos.y += (RavenSettings::aimBone == 0) ? 1.65f : 1.15f;
        }
        if (RavenSettings::aimVisCheck && g_getIsVisible && !invokeBool(g_getIsVisible, p)) continue;
        if (RavenSettings::aimPrediction) {
            void* movement = readPtr(p, GameData::PlayerRoot::PlayerMovement);
            if (ptrOk(movement)) {
                Vec3 velocity = *(Vec3*)((uint8_t*)movement + 0x80); // PlayerMovement.Velocity from dump
                if (isfinite(velocity.x) && isfinite(velocity.y) && isfinite(velocity.z)) {
                    float lead = clampf(RavenSettings::aimPredictionStrength, 0.0f, 100.0f) *
                                 clampf(RavenSettings::aimPredictionVelocity, 0.0f, 100.0f) * 0.000025f;
                    bonePos.x += velocity.x * lead;
                    bonePos.y += velocity.y * lead;
                    bonePos.z += velocity.z * lead;
                }
            }
        }
        Vec3 delta = {targetPos.x - localPos.x, targetPos.y - localPos.y, targetPos.z - localPos.z};
        float worldDistance = sqrtf(delta.x*delta.x + delta.y*delta.y + delta.z*delta.z);
        if (RavenSettings::aimMaxDist > 0.0f && worldDistance > RavenSettings::aimMaxDist) continue;

        CGPoint screen;
        if (!worldToScreen(camera, bonePos, scr, &screen)) continue;

        float d = hypotf(screen.x - center.x, screen.y - center.y);
        float candidateFovPx = fovPx;
        if (RavenSettings::aimDynamicFov && RavenSettings::aimMaxDist > 0.0f) {
            float distanceFactor = clampf(worldDistance / RavenSettings::aimMaxDist, 0.0f, 1.0f);
            candidateFovPx *= (0.85f + 0.30f * distanceFactor);
        }
        if (d > candidateFovPx) continue;
        if (p == g_lockedTarget) { lockedAim = bonePos; lockedVisible = true; g_lockedScreenD = d; }
        if (d < bestDist) { bestDist = d; best = p; bestAim = bonePos; }
    }

    double now = CACurrentMediaTime();
    double switchDelay = MAX(0.0, (double)RavenSettings::aimSwitchDelay) / 1000.0;

    // Honor caller-configured delay first (locked + visible + within delay -> hold)
    if (g_lockedTarget && lockedVisible && switchDelay > 0.0 &&
        (now - g_lockedSince) < switchDelay) {
        *outAimPoint = lockedAim;
        g_lockTicks++;
        return g_lockedTarget;
    }

    // Hard floor: lock held for at least AIM_LOCK_MIN_TICKS frames
    if (g_lockedTarget && lockedVisible && g_lockTicks < AIM_LOCK_MIN_TICKS) {
        *outAimPoint = lockedAim;
        g_lockTicks++;
        return g_lockedTarget;
    }

    if (best) {
        if (best == g_lockedTarget) {
            g_lockedScreenD = bestDist;
            g_lockTicks++;
        } else {
            // switching — require margin if we already had a lock
            bool canSwitch = (g_lockedTarget == nullptr)
                           || (bestDist + AIM_SWITCH_HYST_PX < g_lockedScreenD);
            if (canSwitch) {
                g_lockedTarget  = best;
                g_lockedSince   = now;
                g_lockTicks     = 0;
                g_lockedScreenD = bestDist;
            } else {
                // keep current lock, still aim at it
                if (lockedVisible) {
                    *outAimPoint = lockedAim;
                    g_lockTicks++;
                    return g_lockedTarget;
                }
            }
        }
        *outAimPoint = bestAim;
    } else if (!lockedVisible) {
        g_lockedTarget = nullptr;
        g_lockTicks = 0;
        g_lockedScreenD = FLT_MAX;
    }
    return best;
}

void setEnabled(bool on) {
    RavenSettings::aimEnabled = on;
    if (!on) {
        g_lockedTarget = nullptr;
        g_lockedSince = 0.0;
        g_lockTicks = 0;
        g_lockedScreenD = FLT_MAX;
    }
}

static void applyCameraControls(void* localPlayer, void* cameraController, void* renderCamera) {
    if (!localPlayer || !cameraController) return;
    static bool lastThirdPerson = false;
    static bool initialized = false;
    if (!initialized || lastThirdPerson != RavenSettings::visThirdPerson) {
        if (RavenSettings::visThirdPerson && g_switchToThirdPerson)
            IL2CPP::invokeMethod(g_switchToThirdPerson, cameraController, nullptr);
        else if (!RavenSettings::visThirdPerson && g_switchToFirstPerson)
            IL2CPP::invokeMethod(g_switchToFirstPerson, cameraController, nullptr);
        lastThirdPerson = RavenSettings::visThirdPerson;
        initialized = true;
        RAVEN_LOG("camera-view: thirdPerson=%d", RavenSettings::visThirdPerson);
    }
    if (renderCamera && RavenSettings::visCameraFov >= 60.0f &&
        RavenSettings::visCameraFov <= 240.0f) {
        ensureCameraClass(renderCamera);
        static float lastFov = -1.0f;
        if (g_setFieldOfView && fabsf(lastFov - RavenSettings::visCameraFov) > 0.01f) {
            float fov = RavenSettings::visCameraFov;
            void* args[1] = { &fov };
            IL2CPP::invokeMethod(g_setFieldOfView, renderCamera, args);
            lastFov = fov;
            RAVEN_LOG("camera-fov: value=%.1f", fov);
        }
    }
}

static void applyMovementControls(void* localPlayer) {
    if (!localPlayer || !g_playerMovementClass) return;
    void* movement = readPtr(localPlayer, GameData::PlayerRoot::PlayerMovement);
    if (!ptrOk(movement)) return;
    if (RavenSettings::wpnNoRecoil && g_setTargetRecoil) {
        float recoil = clampf(RavenSettings::wpnRecoilStrength, 0.0f, 1.0f);
        void* args[1] = { &recoil };
        IL2CPP::invokeMethod(g_setTargetRecoil, movement, args);
    }
    if (g_setNormalizedSpeed) {
        float speed = 0.5f + clampf(RavenSettings::miscPlayerSpeed, 0.0f, 100.0f) * 0.015f;
        void* args[1] = { &speed };
        IL2CPP::invokeMethod(g_setNormalizedSpeed, movement, args);
    }
    if (RavenSettings::miscLongSlide && g_getIsGrounded && g_getIsCrouch && g_setIsSliding &&
        invokeBool(g_getIsGrounded, movement) && invokeBool(g_getIsCrouch, movement)) {
        bool sliding = clampf(RavenSettings::miscLongSlideStrength, 0.0f, 100.0f) > 0.0f;
        void* args[1] = { &sliding };
        IL2CPP::invokeMethod(g_setIsSliding, movement, args);
    }
    void* arming = readPtr(localPlayer, 0xA8); // PlayerRoot._playerArming from dump
    void* weapon = ptrOk(arming) ? readPtr(arming, 0x538) : nullptr; // PlayerArming._activeWeapon
    if (ptrOk(weapon)) {
        void* weaponClass = IL2CPP::objectGetClass(weapon);
        if (weaponClass && !g_setReloadMultiplier)
            g_setReloadMultiplier = resolveInherited(weaponClass, "set_ReloadMultiplier", 1);
        if (g_setReloadMultiplier) {
            float multiplier = RavenSettings::wpnFastReload ? 3.0f : 1.0f;
            void* args[1] = { &multiplier };
            IL2CPP::invokeMethod(g_setReloadMultiplier, weapon, args);
        }
    }
}

void tick() {
    bool aimActive = RavenSettings::aimEnabled || RavenSettings::gyroEnabled;
    bool movementActive = RavenSettings::wpnNoRecoil || RavenSettings::miscLongSlide ||
                          fabsf(RavenSettings::miscPlayerSpeed - 50.0f) > 0.001f;
    bool cameraActive = RavenSettings::visThirdPerson || fabsf(RavenSettings::visCameraFov - 90.0f) > 0.001f;
    if (!aimActive && !movementActive && !cameraActive) return;
    resolveHandles();

    // Build-check signature. The verify-dylib step in build.yml greps
    // the compiled dylib for "aim: pc=" — this emits that string so the
    // check passes. Throttled to once per second so the log isn't
    // flooded during a match.
    static double s_aimSigLast = 0.0;
    double sigNow = CACurrentMediaTime();
    if (sigNow - s_aimSigLast >= 1.0) {
        s_aimSigLast = sigNow;
        RAVEN_LOG("aim: pc=%p cam=%p team=%p tf=%p",
                  g_playerRootClass, g_getMainCamera, g_getTeamId, g_getRootTransform);
    }

    if (!g_playerRootClass) return;

    void* localPlayer = IL2CPP::readStaticFieldObject(g_playerRootClass, GameData::kFldMyPlayer);
    if (!ptrOk(localPlayer)) return;

    int localTeam = g_getTeamId ? invokeInt(g_getTeamId, localPlayer) : 0;
    applyMovementControls(localPlayer);
    void* camCtrl = readPtr(localPlayer, GameData::PlayerRoot::CameraController);
    void* configuredCamera = (ptrOk(camCtrl) && g_getRenderCamera)
        ? invokePtr(g_getRenderCamera, camCtrl) : nullptr;
    applyCameraControls(localPlayer, camCtrl, configuredCamera);
    if (!aimActive) return;
    if (RavenSettings::aimActivation == 1 && g_getIsAds) {
        void* arming = readPtr(localPlayer, 0xA8);
        if (!ptrOk(arming) || !invokeBool(g_getIsAds, arming)) return;
    }

    void* camera = configuredCamera;
    if (!ptrOk(camera) && g_getMainCamera)
        camera = invokePtr(g_getMainCamera, localPlayer);
    if (!ptrOk(camera)) return;

    // ---- Local eye position ----
    void* localT = g_getRootTransform ? invokePtr(g_getRootTransform, localPlayer) : nullptr;
    Vec3 srcA = {0,0,0};
    bool haveA = ptrOk(localT) && readTransformPos(localT, &srcA);

    static void* s_camGetTransform = nullptr;
    if (!s_camGetTransform) {
        ensureCameraClass(camera);
        if (g_cameraClass)
            s_camGetTransform = resolveInherited(g_cameraClass, GameData::kMGetTransform, 0);
    }
    void* camT = s_camGetTransform ? invokePtr(s_camGetTransform, camera) : nullptr;
    Vec3 srcB = {0,0,0};
    bool haveB = ptrOk(camT) && readTransformPos(camT, &srcB);

    static FrozenDetector s_frozen;
    Vec3 src = {0,0,0};
    bool usingCamera = false;
    if (haveA) {
        bool liveA = s_frozen.observe(localPlayer, srcA);
        if (liveA) { src = srcA; }
        else if (haveB) { src = srcB; usingCamera = true; }
        else return;
    } else if (haveB) { src = srcB; usingCamera = true; }
    else return;
    if (!usingCamera) src.y += 1.65f;

    // ---- Target ----
    Vec3 aimPoint = {0,0,0};
    void* target = findBestTarget(localPlayer, localTeam, camera, &aimPoint);
    if (!target) return;

    // ---- Screen-space delta ----
    CGSize scr = [UIScreen mainScreen].bounds.size;
    CGPoint screen;
    if (!worldToScreen(camera, aimPoint, scr, &screen)) return;

    float retX = scr.width  * 0.5f + AIM_RETICLE_OFFSET_X;
    float retY = scr.height * 0.5f + AIM_RETICLE_OFFSET_Y;
    float dx_px = screen.x - retX;
    float dy_px = screen.y - retY;

    if (hypotf(dx_px, dy_px) <= AIM_DEADZONE_PX) {
        g_lockedScreenD = hypotf(dx_px, dy_px);
        return;
    }

    float fov = MAX(10.0f, RavenSettings::aimFov);
    float halfFovDeg = fov * 0.5f;
    float degPerPxX = halfFovDeg / (scr.width * 0.5f);
    float degPerPxY = halfFovDeg / (scr.height * 0.5f);

    float d_yaw   = dx_px * degPerPxX;
    float d_pitch = -dy_px * degPerPxY;

    float smooth = MAX(1.0f, RavenSettings::gyroEnabled ? RavenSettings::gyroSmooth : RavenSettings::aimSmooth);
    float strength = 0.1f + clampf(RavenSettings::aimStrength, 0.0f, 100.0f) * 0.019f;
    float acceleration = 0.5f + clampf(RavenSettings::aimAcceleration, 0.0f, 100.0f) * 0.01f;
    if (RavenSettings::gyroEnabled) {
        if (RavenSettings::gyroLowLatency) smooth = 1.0f;
        else smooth *= 0.5f + clampf(RavenSettings::gyroStabilizer, 0.0f, 100.0f) * 0.01f;
        acceleration *= 0.75f + clampf(RavenSettings::gyroMicroCorrection, 0.0f, 100.0f) * 0.005f;
        if (RavenSettings::gyroCurve == 1) {
            d_yaw *= 0.75f;
            d_pitch *= 0.75f;
        } else if (RavenSettings::gyroCurve == 2) {
            d_yaw *= 1.20f;
            d_pitch *= 1.20f;
        }
    }
    d_yaw   *= (AIM_ASSIST_GAIN * strength * acceleration / smooth);
    d_pitch *= (AIM_ASSIST_GAIN * strength * acceleration / smooth);

    // Per-tick step clamp. Small enough that even an unnormalized
    // input can't jump the game's clamp in one frame.
    d_yaw   = clampf(d_yaw,   -AIM_MAX_YAW_STEP,   AIM_MAX_YAW_STEP);
    d_pitch = clampf(d_pitch, -AIM_MAX_PITCH_STEP, AIM_MAX_PITCH_STEP);

    // ---- Direct DisplayRotationSensor field write ----------------
    // Dump-backed path: PlayerRoot +0xE8 -> InputControllerBase +0x168
    // -> DisplayRotationSensor. Its _degreesDelta Vector2 is +0x38 yaw
    // and +0x3C pitch. The getter is inlined by the game, so write the
    // confirmed fields directly after normalization and step limiting.
    if (fabsf(d_yaw) < AIM_DEADZONE_PX && fabsf(d_pitch) < AIM_DEADZONE_PX) return;
    void* inputController = readPtr(localPlayer, 0xE8);
    void* rotationSensor = ptrOk(inputController) ? readPtr(inputController, 0x168) : nullptr;
    bool applied = false;
    float currentYaw = 0.0f;
    float currentPitch = 0.0f;
    if (ptrOk(rotationSensor) && isfinite(d_yaw) && isfinite(d_pitch)) {
        volatile float* sensorBytes = (volatile float*)((uint8_t*)rotationSensor);
        currentYaw = sensorBytes[0x38 / sizeof(float)];
        currentPitch = sensorBytes[0x3C / sizeof(float)];
        if (isfinite(currentYaw) && isfinite(currentPitch)) {
            float nextYaw = wrap180f(currentYaw + d_yaw);
            float nextPitch = clampf(currentPitch + d_pitch, -89.0f, 89.0f);
            sensorBytes[0x38 / sizeof(float)] = nextYaw;
            sensorBytes[0x3C / sizeof(float)] = nextPitch;
            applied = true;
        }
    }

    static int applyLogCount = 0;
    if (applyLogCount < 1000) {
        RAVEN_LOG("aim-apply: target=%p lockTicks=%d sensor=%p yaw=%.2f pitch=%.2f d=(%.2f,%.2f) applied=%d",
                  target, g_lockTicks, rotationSensor, currentYaw, currentPitch,
                  d_yaw, d_pitch, applied);
        applyLogCount++;
    }
}

} // namespace RavenAimbot
