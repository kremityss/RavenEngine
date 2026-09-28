#!/usr/bin/env python3
# RavenEngine write tree — 2026-09-24 (phantom-target + camera-fallback pass)
#
# Changes vs. prior full tree:
#   Src/GameData.h  — comments only; flag offsets marked unverified;
#                     movdump protocol notes extended to 0x100..0x132.
#   Src/ESP.mm      — isLiveCombatPlayer() gate on IsRealPlayer (0x132);
#                     per-match slot[0..23] dump; head/feet height sanity
#                     fallback when the delta leaves [0.6, 2.5].
#   Src/Aimbot.mm   — same gate in findBestTarget; camera-transform
#                     fallback for src when PlayerRoot's get_transform
#                     wrapper is stale; movdump flags line; aim-dbg gains
#                     origin=root|cam; resolveInherited() for inherited
#                     accessors.
#
# 2026-09-25 — override pass:
#   Tail now re-reads Aimbot_fixed.mm from repo root and writes it over
#   Src/Aimbot.mm after every other file is emitted. This prevents the
#   embedded Aimbot.mm string above from clobbering the workflow-applied
#   patch on every regen run. Aimbot_fixed.mm is now the source of truth.
#
# Write path remains disabled. kWriteEnabled = false.

import os

# Generated files are written relative to the caller's working directory, but
# source inputs must be resolved relative to this script.  CI and the tests
# intentionally run the generator from a temporary output directory.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

def w(path, content):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w") as f:
        f.write(content.lstrip("\n"))

# ---------------------------------------------------------------------------
# Makefile — unchanged from the prior correction-pass tree.
# ---------------------------------------------------------------------------
w("Makefile", r"""
TARGET = iphone:clang:latest:14.0
# iPhone 12 and newer use arm64-family hardware. Build both slices so the
# signed IPA can select the compatible slice on arm64 and arm64e devices.
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = Raven
	Raven_FILES = Raven.mm Src/IL2CPP.mm Src/ESP.mm Src/Aimbot.mm Src/Menu.mm Src/Updater.mm Src/Settings.mm Src/LicenseClient.mm
Raven_CFLAGS = -fobjc-arc -I./Src -std=c++17 -Wno-unused-function -Wno-deprecated-declarations
Raven_CCFLAGS = -fobjc-arc -I./Src -std=c++17
Raven_FRAMEWORKS = UIKit Foundation QuartzCore CoreGraphics

include $(THEOS_MAKE_PATH)/tweak.mk
""")

# ---------------------------------------------------------------------------
# Raven.mm — unchanged.
# ---------------------------------------------------------------------------
w("Raven.mm", r"""
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import "Src/Common.h"
#import "Src/IL2CPP.h"
#import "Src/Menu.h"
#import "Src/Updater.h"
#import "Src/Logos.h"
#import "Src/Settings.h"
#import "Src/LicenseClient.h"

static UIViewController* ravenTopController(void) {
    UIWindow* window = nil;
    for (UIScene* scene in [UIApplication sharedApplication].connectedScenes) {
        if (scene.activationState == UISceneActivationStateForegroundActive &&
            [scene isKindOfClass:[UIWindowScene class]]) {
            for (UIWindow* candidate in ((UIWindowScene*)scene).windows) {
                if (candidate.isKeyWindow) { window = candidate; break; }
            }
        }
        if (window) break;
    }
    if (!window) window = [UIApplication sharedApplication].keyWindow;
    UIViewController* controller = window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    if ([controller isKindOfClass:[UINavigationController class]]) controller = [(UINavigationController*)controller visibleViewController];
    if ([controller isKindOfClass:[UITabBarController class]]) controller = [(UITabBarController*)controller selectedViewController];
    return controller;
}

static void ravenShowKeyPrompt(NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController* presenter = ravenTopController();
        if (!presenter) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                ravenShowKeyPrompt(message);
            });
            return;
        }
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Raven License"
                                                                         message:message ?: @"Enter your license key to continue."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
            field.placeholder = @"KREM-COMBAT-MASTER-XXXX";
            field.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Validate" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            NSString* key = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;
            if (!key.length) { ravenShowKeyPrompt(@"A license key is required."); return; }
            NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
            NSString* hwid = RavenLicense::deviceFingerprint();
            [defaults setObject:key forKey:@"raven.license.key"];
            [defaults setObject:hwid forKey:@"raven.license.hwid"];
            [defaults synchronize];
            RavenLicense::validateAsync(key, hwid, ^(BOOL valid, NSString* reason) {
                if (valid) {
                    RAVEN_LOG("license: validated from prompt");
                    return;
                }
                [defaults removeObjectForKey:@"raven.license.key"];
                [defaults synchronize];
                ravenShowKeyPrompt([NSString stringWithFormat:@"License validation failed: %@", reason ?: @"unknown"]);
            });
        }]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

__attribute__((constructor))
static void raven_entry(void) {
    @autoreleasepool {
        RAVEN_LOG("entry");
        RavenSettings::load();
        RAVEN_LOG("settings: aimEnabled=%d espEnabled=%d aimActivation=%d",
                  RavenSettings::aimEnabled,
                  RavenSettings::espEnabled,
                  RavenSettings::aimActivation);
        RavenLicense::validateStoredAsync(^(BOOL valid, NSString* reason) {
            if (!valid) {
                RavenSettings::aimEnabled = false;
                RavenSettings::espEnabled = false;
                RAVEN_LOG("license: rejected reason=%@", reason ?: @"unknown");
                if ([reason isEqualToString:@"credentials_missing"])
                    ravenShowKeyPrompt(@"Enter your Raven license key to activate this device.");
            } else {
                RAVEN_LOG("license: validated");
            }
        });
        Updater::fetchAsync(kConfigURL);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IL2CPP::init();
            [[RavenMenu shared] start];
        });
    }
}
""")

# ---------------------------------------------------------------------------
# Src/Common.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/Common.h", r"""
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
""")

# ---------------------------------------------------------------------------
# Src/GameData.h — MODIFIED (comments only vs. prior tree).
# ---------------------------------------------------------------------------
w("Src/GameData.h", r"""
#ifndef RAVEN_GAMEDATA_H
#define RAVEN_GAMEDATA_H

#include <cstdint>
#include "Updater.h"

// Names + offsets from IL2CPP recon dump of Combat Master.
// Battle gameplay classes live in _CombatMaster.Battle.dll

namespace GameData {

    static const char* kNsPlayer     = "CombatMaster.Battle.Gameplay.Player";
    static const char* kNsCameraCtrl = "CombatMaster.Battle.Gameplay.Player.CameraController";

    static const char* kPlayerRootClass   = "PlayerRoot";
    static const char* kPlayerHealthClass = "PlayerHealth";
    static const char* kPlayerMoveClass   = "PlayerMovement";
    static const char* kPlayerMobClass    = "PlayerMobView";
    static const char* kCameraCtrlClass   = "CameraController";

    static const char* kFldMyPlayer   = "MyPlayer";
    static const char* kFldAllPlayers = "AllPlayers";

    namespace PlayerRoot {
        // -----------------------------------------------------------------
        // CameraController = 0x48 is the only field offset here with
        // direct log support: esp-cam lines show camCtrl and renderCam
        // resolving to non-null pointers on every capture, and the
        // resolved camera produces valid W2S output. Treat 0x48 as
        // verified.
        //
        // PlayerMovement (0xB0) and PlayerHealth (0xB8) are used only
        // as candidate reads. The movdump output in session 1 and
        // session 2 shows the same struct layout, so 0xB0 is
        // consistent across captures, but the two captures differ in
        // what 0x48 contains (garbage in session 1, 0.000 in session
        // 2) — which suggests at least one field boundary in this
        // struct is not what recon reported.
        //
        // The flag offsets below (0x108..0x132) are UNVERIFIED. The
        // live-filter in ESP.mm and Aimbot.mm relies on IsRealPlayer
        // at 0x132. If the filter drops every target or drops no
        // targets, the slot[N] log will show which byte is which; the
        // movdump flags line dumps 0x100..0x132 every 100 ms and can
        // be correlated against known alive/dead transitions.
        // -----------------------------------------------------------------
        constexpr uint32_t CameraController = 0x48;
        constexpr uint32_t BodyHitbox       = 0x50;
        constexpr uint32_t HeadHitbox       = 0x58;
        constexpr uint32_t PlayerMovement   = 0xB0;
        constexpr uint32_t PlayerHealth     = 0xB8;

        // UNVERIFIED — see note above.
        constexpr uint32_t IsOwner          = 0x108;
        constexpr uint32_t HasControl       = 0x109;
        constexpr uint32_t IsVisible        = 0x10A;
        constexpr uint32_t IsRealPlayer     = 0x132;
    }

    namespace PlayerMovement {
        // -----------------------------------------------------------------
        // DEAD OFFSETS — do not write.
        //
        // The 2026-09-24 18:33:39 build wrote pitch to +0x60 and yaw to
        // +0x68 on every tick. Both offsets were wrong. Scribbling
        // arbitrary floats into live IL2CPP struct memory caused Unity to
        // follow a corrupted byte as a pointer and crash inside
        // UnityRepaint with EXC_BAD_ACCESS (KERN_INVALID_ADDRESS).
        //
        // 0x60, 0x68, and 0x78 read 0.000 across every available capture.
        // They are not rotation.
        // -----------------------------------------------------------------
        constexpr uint32_t DEAD_0x60 = 0x60;
        constexpr uint32_t DEAD_0x68 = 0x68;
        constexpr uint32_t DEAD_0x78 = 0x78;

        // -----------------------------------------------------------------
        // CANDIDATE OFFSETS — unverified. Do not write.
        //
        // 0x70 and 0x74 are the two offsets whose float reads in the
        // session-1 capture most resemble a pitch/yaw pair: 0x70 reads
        // -90.000 at exactly the tick the aim-dbg wantPitch sat near
        // -4.4, and 0x74 walks through [202, 344] which is inside a
        // yaw-in-degrees envelope if the game stores yaw unwrapped.
        //
        // The session-2 capture tells a different story. In that
        // capture 0x60 == 0x70 at every sample, 0x50/0x54/0x58 hold a
        // unit-length forward vector, 0x60 holds (0, 1, 0, 0) — an up
        // vector — and 0x74 does NOT track the aim-dbg wantYaw that
        // accompanies it. That is not a stable field layout; it looks
        // like two different code paths resolving the same struct
        // pointer against two different object layouts.
        //
        // Neither capture contains a moving local player during the
        // movdump window: the frozen-src detector fired at 00:27:36
        // and src stayed byte-identical for the remainder of that life.
        // There is therefore no correlation between 0x70/0x74 and a
        // known camera pan on disk.
        //
        // Do not promote these to confirmed. Do not write to them.
        // -----------------------------------------------------------------
        constexpr uint32_t CANDIDATE_VerticalRotation  = 0x70;
        constexpr uint32_t CANDIDATE_HorRotationAngles = 0x74;
    }

    static const char* kMGetHealth        = "get_Health";
    static const char* kMGetMaxHealth     = "get_MaxHealth";
    static const char* kMGetArmor         = "get_Armor";
    static const char* kMGetIsDead        = "get_IsDead";
    static const char* kMGetIsDowned      = "get_IsDowned";

    static const char* kMGetTeamId        = "get_TeamId";
    static const char* kMGetNetworkId     = "get_NetworkId";
    static const char* kMGetActiveMobView = "get_ActiveMobView";
    static const char* kMGetIsVisible     = "get_IsVisible";
    static const char* kMGetMainCamera    = "get_MainCamera";
    static const char* kMGetTransform     = "get_transform";

    static const char* kMGetHeadTransform  = "get_HeadTransform";
    static const char* kMGetNeckTransform  = "get_NeckTransform";
    static const char* kMGetChestTransform = "get_ChestTransform";
    static const char* kMGetSpineTransform = "get_SpineTransform";
    static const char* kMGetPelvisTransform = "get_PelvisTransform";

    static const char* kMGetRenderCamera  = "get_RenderCamera";
    static const char* kMGetPosition      = "get_position";
    static const char* kMWorldToScreen    = "WorldToScreenPoint";

    namespace List {
        constexpr uint32_t Items = 0x10;
        constexpr uint32_t Size  = 0x18;
    }

    namespace Array {
        constexpr uint32_t Data = 0x20;
    }

    namespace Bone {
        constexpr int Head   = 11;
        constexpr int Neck   = 12;
        constexpr int Chest  = 20;
        constexpr int Pelvis = 1;
    }
}

#endif
""")

# ---------------------------------------------------------------------------
# Src/Logos.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/Logos.h", r"""
#ifndef RAVEN_LOGOS_H
#define RAVEN_LOGOS_H

static const char* kWordmarkURL  = "https://i.imgur.com/Cnzjdjh.png";
static const char* kBallLogoURL  = "https://i.imgur.com/MQG4stU.png";
static const char* kEmblemURL    = "https://i.imgur.com/4H9W96B.png";

static const char* kConfigURL = "https://raw.githubusercontent.com/KremCheats/RavenEngine/main/config.json";

#endif
""")

# ---------------------------------------------------------------------------
# Src/LicenseClient.h/.mm — portal validation contract.
# ---------------------------------------------------------------------------
w("Src/LicenseClient.h", r"""
#ifndef RAVEN_LICENSE_CLIENT_H
#define RAVEN_LICENSE_CLIENT_H

#import <Foundation/Foundation.h>

namespace RavenLicense {
    typedef void (^ValidationCallback)(BOOL valid, NSString* reason);
    NSString* deviceFingerprint(void);
    void validateAsync(NSString* key, NSString* hwid, ValidationCallback callback);
    void validateStoredAsync(ValidationCallback callback);
}

#endif
""")

w("Src/LicenseClient.mm", r"""
#import "LicenseClient.h"
#import "Common.h"
#import "Settings.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

#include <dispatch/dispatch.h>
#include <cstring>

namespace RavenLicense {

// Keep this endpoint in one place. Release builds should point it at the
// published portal domain; the sandbox preview URL is intentionally not
// hard-coded into the tweak artifact.
static NSString* const kValidationEndpoint = @"https://ravenkeys-44zgusha.manus.space/api/trpc/license.validate?batch=1";

NSString* deviceFingerprint(void) {
    UIDevice* device = [UIDevice currentDevice];
    NSString* vendorUUID = device.identifierForVendor.UUIDString;
    if (vendorUUID.length) return vendorUUID.lowercaseString;

    // Rare fallback for environments without identifierForVendor. It remains
    // UUID-shaped so the portal contract stays identical.
    NSString* material = [NSString stringWithFormat:@"raven-v1|%@|%@", device.model ?: @"unknown", device.systemVersion ?: @"unknown"];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    CC_SHA256(material.UTF8String, (CC_LONG)strlen(material.UTF8String), digest);
    digest[6] = (digest[6] & 0x0f) | 0x50;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    NSString* result = [NSString stringWithFormat:@"%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                        digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                        digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]];
    return result;
}

void validateAsync(NSString* key, NSString* hwid, ValidationCallback callback) {
    if (!key.length || !hwid.length || !callback) return;
    NSURL* url = [NSURL URLWithString:kValidationEndpoint];
    if (!url) { callback(NO, @"invalid_endpoint"); return; }

    NSDictionary* input = @{ @"0": @{ @"json": @{ @"key": key, @"hwid": hwid } } };
    NSError* jsonError = nil;
    NSData* body = [NSJSONSerialization dataWithJSONObject:input options:0 error:&jsonError];
    if (!body) { callback(NO, @"request_encoding_failed"); return; }

    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"Raven/1" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if (error || !data) { dispatch_async(dispatch_get_main_queue(), ^{ callback(NO, @"network_error"); }); return; }
        NSError* parseError = nil;
        id outer = [NSJSONSerialization JSONObjectWithData:data options:0 error:&parseError];
        NSDictionary* envelope = nil;
        if ([outer isKindOfClass:[NSArray class]]) {
            id first = [(NSArray*)outer firstObject];
            if ([first isKindOfClass:[NSDictionary class]]) envelope = first;
        } else if ([outer isKindOfClass:[NSDictionary class]]) {
            id batch = [(NSDictionary*)outer objectForKeyedSubscript:@"0"];
            if ([batch isKindOfClass:[NSDictionary class]]) envelope = batch;
            else if ([batch isKindOfClass:[NSArray class]]) {
                id first = [(NSArray*)batch firstObject];
                if ([first isKindOfClass:[NSDictionary class]]) envelope = first;
            }
        }
        NSDictionary* result = [envelope[@"result"] isKindOfClass:[NSDictionary class]] ? envelope[@"result"] : nil;
        NSDictionary* dataObject = [result[@"data"] isKindOfClass:[NSDictionary class]] ? result[@"data"] : nil;
        NSDictionary* json = [dataObject[@"json"] isKindOfClass:[NSDictionary class]] ? dataObject[@"json"] : nil;
        BOOL valid = [json[@"valid"] boolValue];
        NSString* reason = [json[@"reason"] isKindOfClass:[NSString class]] ? json[@"reason"] : (parseError || !json ? @"invalid_response" : @"unknown");
        dispatch_async(dispatch_get_main_queue(), ^{ callback(valid, reason); });
    }] resume];
}

void validateStoredAsync(ValidationCallback callback) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* key = [defaults stringForKey:@"raven.license.key"];
    NSString* hwid = [defaults stringForKey:@"raven.license.hwid"];
    if (!key.length) { if (callback) callback(NO, @"credentials_missing"); return; }
    if (!hwid.length) {
        hwid = deviceFingerprint();
        [defaults setObject:hwid forKey:@"raven.license.hwid"];
        [defaults synchronize];
    }
    NSTimeInterval cachedExpiry = [defaults doubleForKey:@"raven.license.expiresAt"];
    if (cachedExpiry > NSDate.date.timeIntervalSince1970) {
        if (callback) callback(YES, @"cached");
        return;
    }
    validateAsync(key, hwid, callback);
}

}
""")

# ---------------------------------------------------------------------------
# Src/Settings.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/Settings.h", r"""
#ifndef RAVEN_SETTINGS_H
#define RAVEN_SETTINGS_H

namespace RavenSettings {
    void load();
    void save();

    extern bool  aimEnabled;
    extern int   aimBone;
    extern int   aimActivation;
    extern float aimFov;
    extern float aimSmooth;
    extern float aimMaxDist;
    extern bool  aimPrediction;
    extern bool  aimVisCheck;
    extern float aimDelay;
    extern float aimSwitchDelay;
    extern bool  aimShowCircle;
    extern float aimCircleRadius;
    extern float aimCircleThickness;
    extern int   aimPriority;
    extern int   aimCurve;

    extern bool  espEnabled;
    extern bool  espBox;
    extern bool  espCorner;
    extern bool  espSkeleton;
    extern bool  espSnaplines;
    extern bool  espName;
    extern bool  espDistance;
    extern bool  espHealth;
    extern bool  espWeapon;
    extern int   espEnemyColor;
    extern int   espVisibleColor;
    extern int   espSkeletonColor;
    extern int   espBoxColor;
    extern int   espBoxStyle;

    extern bool  visCrosshair;
    extern int   visCrosshairStyle;
    extern float visCrosshairSize;
    extern float visCrosshairThickness;
    extern bool  visFovCircle;
    extern float visFovRadius;
    extern float visFovThickness;
    extern bool  visRemoveFog;
    extern bool  visNightMode;
    extern bool  visBrightnessBoost;
    extern float visBrightness;
    extern bool  visNoFlash;
    extern bool  visNoSmoke;
    extern bool  visBetterTextures;

    extern bool  wpnNoRecoil;
    extern bool  wpnNoSpread;
    extern float wpnRecoilStrength;
    extern bool  wpnFastReload;
    extern bool  wpnRapidFire;
    extern float wpnFireRate;
    extern bool  wpnNoFlash;
    extern bool  wpnNoSmoke;
    extern bool  wpnNoShells;

    extern bool  miscBunnyHop;
    extern bool  miscAutoStrafe;
    extern bool  miscNoFallDamage;
    extern bool  miscUnlockAll;
    extern bool  miscNoAds;
    extern bool  miscPanicKey;
    extern bool  miscHideWhenClosed;
    extern float miscMenuOpacity;

    extern float menuScale;
    extern bool  animations;

    extern int   uiAccentColor;
    extern int   uiOpenButton;
    extern int   uiPosition;

    void resetToDefaults();
}

#endif
""")

# ---------------------------------------------------------------------------
# Src/Settings.mm — unchanged.
# ---------------------------------------------------------------------------
w("Src/Settings.mm", r"""
#import "Settings.h"
#import "Common.h"
#import <Foundation/Foundation.h>

namespace RavenSettings {

bool  aimEnabled = false;
int   aimBone = 0;
int   aimActivation = 0;
float aimFov = 120.0f;
float aimSmooth = 5.0f;
float aimMaxDist = 250.0f;
bool  aimPrediction = true;
bool  aimVisCheck = true;
float aimDelay = 0.0f;
float aimSwitchDelay = 120.0f;
bool  aimShowCircle = true;
float aimCircleRadius = 120.0f;
float aimCircleThickness = 2.0f;
int   aimPriority = 0;
int   aimCurve = 1;

bool  espEnabled = true;
bool  espBox = true;
bool  espCorner = false;
bool  espSkeleton = false;
bool  espSnaplines = false;
bool  espName = true;
bool  espDistance = true;
bool  espHealth = true;
bool  espWeapon = false;
int   espEnemyColor = 0;
int   espVisibleColor = 1;
int   espSkeletonColor = 2;
int   espBoxColor = 0;
int   espBoxStyle = 0;

bool  visCrosshair = true;
int   visCrosshairStyle = 0;
float visCrosshairSize = 6.0f;
float visCrosshairThickness = 2.0f;
bool  visFovCircle = false;
float visFovRadius = 120.0f;
float visFovThickness = 2.0f;
bool  visRemoveFog = true;
bool  visNightMode = true;
bool  visBrightnessBoost = true;
float visBrightness = 100.0f;
bool  visNoFlash = true;
bool  visNoSmoke = true;
bool  visBetterTextures = false;

bool  wpnNoRecoil = true;
bool  wpnNoSpread = true;
float wpnRecoilStrength = 0.0f;
bool  wpnFastReload = true;
bool  wpnRapidFire = true;
float wpnFireRate = 3.0f;
bool  wpnNoFlash = true;
bool  wpnNoSmoke = true;
bool  wpnNoShells = false;

bool  miscBunnyHop = true;
bool  miscAutoStrafe = true;
bool  miscNoFallDamage = false;
bool  miscUnlockAll = false;
bool  miscNoAds = false;
bool  miscPanicKey = true;
bool  miscHideWhenClosed = true;
float miscMenuOpacity = 97.0f;

float menuScale = 100.0f;
bool  animations = true;

int   uiAccentColor = 0;
int   uiOpenButton = 0;
int   uiPosition = 0;

static NSString* kKey(NSString* n) { return [@"raven." stringByAppendingString:n]; }

void load() {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    aimEnabled = [d boolForKey:kKey(@"aim.enabled")];
    aimFov = [d floatForKey:kKey(@"aim.fov")];  if (aimFov <= 0) aimFov = 120;
    aimSmooth = [d floatForKey:kKey(@"aim.smooth")]; if (aimSmooth <= 0) aimSmooth = 5;
    espEnabled = [d objectForKey:kKey(@"esp.enabled")] ? [d boolForKey:kKey(@"esp.enabled")] : YES;
    miscMenuOpacity = [d floatForKey:kKey(@"misc.opacity")]; if (miscMenuOpacity <= 0) miscMenuOpacity = 97;
    menuScale = [d floatForKey:kKey(@"ui.scale")]; if (menuScale <= 0) menuScale = 100;

    aimActivation   = (int)[d integerForKey:kKey(@"aim.activation")];
    aimBone         = (int)[d integerForKey:kKey(@"aim.bone")];
    espEnemyColor   = (int)[d integerForKey:kKey(@"esp.enemyColor")];
    espVisibleColor = (int)[d integerForKey:kKey(@"esp.visibleColor")];
    espSkeletonColor= (int)[d integerForKey:kKey(@"esp.skeletonColor")];
    espBoxColor     = (int)[d integerForKey:kKey(@"esp.boxColor")];
    espBoxStyle     = (int)[d integerForKey:kKey(@"esp.boxStyle")];
    visCrosshairStyle = (int)[d integerForKey:kKey(@"vis.crosshairStyle")];
    aimPriority     = (int)[d integerForKey:kKey(@"aim.priority")];
    aimCurve        = [d objectForKey:kKey(@"aim.curve")] ? (int)[d integerForKey:kKey(@"aim.curve")] : aimCurve;
    uiAccentColor   = (int)[d integerForKey:kKey(@"ui.accent")];
    uiOpenButton    = (int)[d integerForKey:kKey(@"ui.openButton")];
    uiPosition      = (int)[d integerForKey:kKey(@"ui.position")];
    animations      = [d objectForKey:kKey(@"ui.animations")] ? [d boolForKey:kKey(@"ui.animations")] : YES;

    aimMaxDist = [d objectForKey:kKey(@"aim.maxDist")] ? [d floatForKey:kKey(@"aim.maxDist")] : aimMaxDist;
    aimPrediction = [d objectForKey:kKey(@"aim.prediction")] ? [d boolForKey:kKey(@"aim.prediction")] : aimPrediction;
    aimVisCheck = [d objectForKey:kKey(@"aim.visCheck")] ? [d boolForKey:kKey(@"aim.visCheck")] : aimVisCheck;
    aimDelay = [d objectForKey:kKey(@"aim.delay")] ? [d floatForKey:kKey(@"aim.delay")] : aimDelay;
    aimSwitchDelay = [d objectForKey:kKey(@"aim.switchDelay")] ? [d floatForKey:kKey(@"aim.switchDelay")] : aimSwitchDelay;
    aimShowCircle = [d objectForKey:kKey(@"aim.showCircle")] ? [d boolForKey:kKey(@"aim.showCircle")] : aimShowCircle;
    aimCircleRadius = [d objectForKey:kKey(@"aim.circleRadius")] ? [d floatForKey:kKey(@"aim.circleRadius")] : aimCircleRadius;
    aimCircleThickness = [d objectForKey:kKey(@"aim.circleThickness")] ? [d floatForKey:kKey(@"aim.circleThickness")] : aimCircleThickness;
    espBox = [d objectForKey:kKey(@"esp.box")] ? [d boolForKey:kKey(@"esp.box")] : espBox;
    espCorner = [d objectForKey:kKey(@"esp.corner")] ? [d boolForKey:kKey(@"esp.corner")] : espCorner;
    espSkeleton = [d objectForKey:kKey(@"esp.skeleton")] ? [d boolForKey:kKey(@"esp.skeleton")] : espSkeleton;
    espSnaplines = [d objectForKey:kKey(@"esp.snaplines")] ? [d boolForKey:kKey(@"esp.snaplines")] : espSnaplines;
    espName = [d objectForKey:kKey(@"esp.name")] ? [d boolForKey:kKey(@"esp.name")] : espName;
    espDistance = [d objectForKey:kKey(@"esp.distance")] ? [d boolForKey:kKey(@"esp.distance")] : espDistance;
    espHealth = [d objectForKey:kKey(@"esp.health")] ? [d boolForKey:kKey(@"esp.health")] : espHealth;
    espWeapon = [d objectForKey:kKey(@"esp.weapon")] ? [d boolForKey:kKey(@"esp.weapon")] : espWeapon;
    visCrosshair = [d objectForKey:kKey(@"vis.crosshair")] ? [d boolForKey:kKey(@"vis.crosshair")] : visCrosshair;
    visCrosshairSize = [d objectForKey:kKey(@"vis.crosshairSize")] ? [d floatForKey:kKey(@"vis.crosshairSize")] : visCrosshairSize;
    visCrosshairThickness = [d objectForKey:kKey(@"vis.crosshairThickness")] ? [d floatForKey:kKey(@"vis.crosshairThickness")] : visCrosshairThickness;
    visFovCircle = [d objectForKey:kKey(@"vis.fovCircle")] ? [d boolForKey:kKey(@"vis.fovCircle")] : visFovCircle;
    visFovRadius = [d objectForKey:kKey(@"vis.fovRadius")] ? [d floatForKey:kKey(@"vis.fovRadius")] : visFovRadius;
    visFovThickness = [d objectForKey:kKey(@"vis.fovThickness")] ? [d floatForKey:kKey(@"vis.fovThickness")] : visFovThickness;
    visRemoveFog = [d objectForKey:kKey(@"vis.removeFog")] ? [d boolForKey:kKey(@"vis.removeFog")] : visRemoveFog;
    visNightMode = [d objectForKey:kKey(@"vis.nightMode")] ? [d boolForKey:kKey(@"vis.nightMode")] : visNightMode;
    visBrightnessBoost = [d objectForKey:kKey(@"vis.brightnessBoost")] ? [d boolForKey:kKey(@"vis.brightnessBoost")] : visBrightnessBoost;
    visBrightness = [d objectForKey:kKey(@"vis.brightness")] ? [d floatForKey:kKey(@"vis.brightness")] : visBrightness;
    visNoFlash = [d objectForKey:kKey(@"vis.noFlash")] ? [d boolForKey:kKey(@"vis.noFlash")] : visNoFlash;
    visNoSmoke = [d objectForKey:kKey(@"vis.noSmoke")] ? [d boolForKey:kKey(@"vis.noSmoke")] : visNoSmoke;
    visBetterTextures = [d objectForKey:kKey(@"vis.betterTextures")] ? [d boolForKey:kKey(@"vis.betterTextures")] : visBetterTextures;
    wpnNoRecoil = [d objectForKey:kKey(@"wpn.noRecoil")] ? [d boolForKey:kKey(@"wpn.noRecoil")] : wpnNoRecoil;
    wpnNoSpread = [d objectForKey:kKey(@"wpn.noSpread")] ? [d boolForKey:kKey(@"wpn.noSpread")] : wpnNoSpread;
    wpnRecoilStrength = [d objectForKey:kKey(@"wpn.recoilStrength")] ? [d floatForKey:kKey(@"wpn.recoilStrength")] : wpnRecoilStrength;
    wpnFastReload = [d objectForKey:kKey(@"wpn.fastReload")] ? [d boolForKey:kKey(@"wpn.fastReload")] : wpnFastReload;
    wpnRapidFire = [d objectForKey:kKey(@"wpn.rapidFire")] ? [d boolForKey:kKey(@"wpn.rapidFire")] : wpnRapidFire;
    wpnFireRate = [d objectForKey:kKey(@"wpn.fireRate")] ? [d floatForKey:kKey(@"wpn.fireRate")] : wpnFireRate;
    wpnNoFlash = [d objectForKey:kKey(@"wpn.noFlash")] ? [d boolForKey:kKey(@"wpn.noFlash")] : wpnNoFlash;
    wpnNoSmoke = [d objectForKey:kKey(@"wpn.noSmoke")] ? [d boolForKey:kKey(@"wpn.noSmoke")] : wpnNoSmoke;
    wpnNoShells = [d objectForKey:kKey(@"wpn.noShells")] ? [d boolForKey:kKey(@"wpn.noShells")] : wpnNoShells;
    miscBunnyHop = [d objectForKey:kKey(@"misc.bunnyHop")] ? [d boolForKey:kKey(@"misc.bunnyHop")] : miscBunnyHop;
    miscAutoStrafe = [d objectForKey:kKey(@"misc.autoStrafe")] ? [d boolForKey:kKey(@"misc.autoStrafe")] : miscAutoStrafe;
    miscNoFallDamage = [d objectForKey:kKey(@"misc.noFallDamage")] ? [d boolForKey:kKey(@"misc.noFallDamage")] : miscNoFallDamage;
    miscUnlockAll = [d objectForKey:kKey(@"misc.unlockAll")] ? [d boolForKey:kKey(@"misc.unlockAll")] : miscUnlockAll;
    miscNoAds = [d objectForKey:kKey(@"misc.noAds")] ? [d boolForKey:kKey(@"misc.noAds")] : miscNoAds;
    miscPanicKey = [d objectForKey:kKey(@"misc.panicKey")] ? [d boolForKey:kKey(@"misc.panicKey")] : miscPanicKey;
    miscHideWhenClosed = [d objectForKey:kKey(@"misc.hideWhenClosed")] ? [d boolForKey:kKey(@"misc.hideWhenClosed")] : miscHideWhenClosed;
}

void save() {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setBool:aimEnabled forKey:kKey(@"aim.enabled")];
    [d setFloat:aimFov forKey:kKey(@"aim.fov")];
    [d setFloat:aimSmooth forKey:kKey(@"aim.smooth")];
    [d setBool:espEnabled forKey:kKey(@"esp.enabled")];
    [d setFloat:miscMenuOpacity forKey:kKey(@"misc.opacity")];
    [d setFloat:menuScale forKey:kKey(@"ui.scale")];

    [d setInteger:aimActivation forKey:kKey(@"aim.activation")];
    [d setInteger:aimBone forKey:kKey(@"aim.bone")];
    [d setInteger:espEnemyColor forKey:kKey(@"esp.enemyColor")];
    [d setInteger:espVisibleColor forKey:kKey(@"esp.visibleColor")];
    [d setInteger:espSkeletonColor forKey:kKey(@"esp.skeletonColor")];
    [d setInteger:espBoxColor forKey:kKey(@"esp.boxColor")];
    [d setInteger:espBoxStyle forKey:kKey(@"esp.boxStyle")];
    [d setInteger:visCrosshairStyle forKey:kKey(@"vis.crosshairStyle")];
    [d setInteger:aimPriority forKey:kKey(@"aim.priority")];
    [d setInteger:aimCurve forKey:kKey(@"aim.curve")];
    [d setInteger:uiAccentColor forKey:kKey(@"ui.accent")];
    [d setInteger:uiOpenButton forKey:kKey(@"ui.openButton")];
    [d setInteger:uiPosition forKey:kKey(@"ui.position")];
    [d setBool:animations forKey:kKey(@"ui.animations")];
    [d setFloat:aimMaxDist forKey:kKey(@"aim.maxDist")];
    [d setBool:aimPrediction forKey:kKey(@"aim.prediction")];
    [d setBool:aimVisCheck forKey:kKey(@"aim.visCheck")];
    [d setFloat:aimDelay forKey:kKey(@"aim.delay")];
    [d setFloat:aimSwitchDelay forKey:kKey(@"aim.switchDelay")];
    [d setBool:aimShowCircle forKey:kKey(@"aim.showCircle")];
    [d setFloat:aimCircleRadius forKey:kKey(@"aim.circleRadius")];
    [d setFloat:aimCircleThickness forKey:kKey(@"aim.circleThickness")];
    [d setBool:espBox forKey:kKey(@"esp.box")];
    [d setBool:espCorner forKey:kKey(@"esp.corner")];
    [d setBool:espSkeleton forKey:kKey(@"esp.skeleton")];
    [d setBool:espSnaplines forKey:kKey(@"esp.snaplines")];
    [d setBool:espName forKey:kKey(@"esp.name")];
    [d setBool:espDistance forKey:kKey(@"esp.distance")];
    [d setBool:espHealth forKey:kKey(@"esp.health")];
    [d setBool:espWeapon forKey:kKey(@"esp.weapon")];
    [d setBool:visCrosshair forKey:kKey(@"vis.crosshair")];
    [d setFloat:visCrosshairSize forKey:kKey(@"vis.crosshairSize")];
    [d setFloat:visCrosshairThickness forKey:kKey(@"vis.crosshairThickness")];
    [d setBool:visFovCircle forKey:kKey(@"vis.fovCircle")];
    [d setFloat:visFovRadius forKey:kKey(@"vis.fovRadius")];
    [d setFloat:visFovThickness forKey:kKey(@"vis.fovThickness")];
    [d setBool:visRemoveFog forKey:kKey(@"vis.removeFog")];
    [d setBool:visNightMode forKey:kKey(@"vis.nightMode")];
    [d setBool:visBrightnessBoost forKey:kKey(@"vis.brightnessBoost")];
    [d setFloat:visBrightness forKey:kKey(@"vis.brightness")];
    [d setBool:visNoFlash forKey:kKey(@"vis.noFlash")];
    [d setBool:visNoSmoke forKey:kKey(@"vis.noSmoke")];
    [d setBool:visBetterTextures forKey:kKey(@"vis.betterTextures")];
    [d setBool:wpnNoRecoil forKey:kKey(@"wpn.noRecoil")];
    [d setBool:wpnNoSpread forKey:kKey(@"wpn.noSpread")];
    [d setFloat:wpnRecoilStrength forKey:kKey(@"wpn.recoilStrength")];
    [d setBool:wpnFastReload forKey:kKey(@"wpn.fastReload")];
    [d setBool:wpnRapidFire forKey:kKey(@"wpn.rapidFire")];
    [d setFloat:wpnFireRate forKey:kKey(@"wpn.fireRate")];
    [d setBool:wpnNoFlash forKey:kKey(@"wpn.noFlash")];
    [d setBool:wpnNoSmoke forKey:kKey(@"wpn.noSmoke")];
    [d setBool:wpnNoShells forKey:kKey(@"wpn.noShells")];
    [d setBool:miscBunnyHop forKey:kKey(@"misc.bunnyHop")];
    [d setBool:miscAutoStrafe forKey:kKey(@"misc.autoStrafe")];
    [d setBool:miscNoFallDamage forKey:kKey(@"misc.noFallDamage")];
    [d setBool:miscUnlockAll forKey:kKey(@"misc.unlockAll")];
    [d setBool:miscNoAds forKey:kKey(@"misc.noAds")];
    [d setBool:miscPanicKey forKey:kKey(@"misc.panicKey")];
    [d setBool:miscHideWhenClosed forKey:kKey(@"misc.hideWhenClosed")];
    [d synchronize];
}

void resetToDefaults() {
    aimEnabled = false;
    aimBone = 0;
    aimActivation = 0;
    aimFov = 120.0f;
    aimSmooth = 5.0f;
    aimMaxDist = 250.0f;
    aimPrediction = true;
    aimVisCheck = true;
    aimDelay = 0.0f;
    aimSwitchDelay = 120.0f;
    aimShowCircle = true;
    aimCircleRadius = 120.0f;
    aimCircleThickness = 2.0f;
    aimPriority = 0;
    aimCurve = 1;

    espEnabled = true;
    espBox = true;
    espCorner = false;
    espSkeleton = false;
    espSnaplines = false;
    espName = true;
    espDistance = true;
    espHealth = true;
    espWeapon = false;
    espEnemyColor = 0;
    espVisibleColor = 1;
    espSkeletonColor = 2;
    espBoxColor = 0;
    espBoxStyle = 0;

    visCrosshair = true;
    visCrosshairStyle = 0;
    visCrosshairSize = 6.0f;
    visCrosshairThickness = 2.0f;
    visFovCircle = false;
    visFovRadius = 120.0f;
    visFovThickness = 2.0f;
    visRemoveFog = true;
    visNightMode = true;
    visBrightnessBoost = true;
    visBrightness = 100.0f;
    visNoFlash = true;
    visNoSmoke = true;
    visBetterTextures = false;

    wpnNoRecoil = true;
    wpnNoSpread = true;
    wpnRecoilStrength = 0.0f;
    wpnFastReload = true;
    wpnRapidFire = true;
    wpnFireRate = 3.0f;
    wpnNoFlash = true;
    wpnNoSmoke = true;
    wpnNoShells = false;

    miscBunnyHop = true;
    miscAutoStrafe = true;
    miscNoFallDamage = false;
    miscUnlockAll = false;
    miscNoAds = false;
    miscPanicKey = true;
    miscHideWhenClosed = true;
    miscMenuOpacity = 97.0f;

    menuScale = 100.0f;
    animations = true;
    uiAccentColor = 0;
    uiOpenButton = 0;
    uiPosition = 0;

    save();
}

}
""")

# ---------------------------------------------------------------------------
# Src/Updater.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/Updater.h", r"""
#ifndef RAVEN_UPDATER_H
#define RAVEN_UPDATER_H

#include <cstdint>
#include <string>
#include <map>

namespace Updater {
    void fetchAsync(const char* url);
    std::string remoteVersion();
    bool hasUpdate();
    std::string updateMessage();
    uint32_t offset(const std::string& key, uint32_t fallback);
    bool feature(const std::string& key, bool fallback);
    std::string asset(const std::string& key, const std::string& fallback);
    const char* status();
}

#endif
""")

# ---------------------------------------------------------------------------
# Src/Updater.mm — unchanged.
# ---------------------------------------------------------------------------
w("Src/Updater.mm", r"""
#import "Updater.h"
#import "Common.h"
#import <Foundation/Foundation.h>

namespace Updater {

static std::map<std::string,uint32_t> g_offsets;
static std::map<std::string,bool>     g_features;
static std::map<std::string,std::string> g_assets;
static std::string g_version    = RAVEN_LOCAL_VERSION;
static std::string g_minDylib   = RAVEN_LOCAL_VERSION;
static std::string g_message;
static bool g_fetched           = false;
static char g_status[160]       = "not fetched";

static uint32_t parseHex(const std::string& s) {
    if (s.empty()) return 0;
    return (uint32_t)strtoul(s.c_str(), nullptr, 16);
}

static std::string toStd(NSString* s) {
    if (!s) return std::string();
    return std::string([s UTF8String] ?: "");
}

static std::string cachePath() {
    NSString* d = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    return toStd(d) + "/raven_config.json";
}

static bool parseConfig(NSData* data) {
    if (!data) return false;
    NSError* err = nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (!root || ![root isKindOfClass:[NSDictionary class]]) return false;
    NSDictionary* d = (NSDictionary*)root;

    if (d[@"version"])           g_version  = toStd(d[@"version"]);
    if (d[@"min_dylib_version"]) g_minDylib = toStd(d[@"min_dylib_version"]);
    if (d[@"message"])           g_message  = toStd(d[@"message"]);

    g_offsets.clear();
    NSDictionary* offs = d[@"offsets"];
    if ([offs isKindOfClass:[NSDictionary class]])
        for (NSString* k in offs) g_offsets[toStd(k)] = parseHex(toStd(offs[k]));

    g_features.clear();
    NSDictionary* feats = d[@"features"];
    if ([feats isKindOfClass:[NSDictionary class]])
        for (NSString* k in feats) g_features[toStd(k)] = [feats[k] boolValue];

    g_assets.clear();
    NSDictionary* assets = d[@"assets"];
    if ([assets isKindOfClass:[NSDictionary class]])
        for (NSString* k in assets) g_assets[toStd(k)] = toStd(assets[k]);

    g_fetched = true;
    snprintf(g_status, sizeof(g_status), "config v%s (%zu offs)",
             g_version.c_str(), g_offsets.size());
    return true;
}

void fetchAsync(const char* url) {
    if (g_fetched) return;
    NSData* cached = [NSData dataWithContentsOfFile:
                      [NSString stringWithUTF8String:cachePath().c_str()]];
    if (cached && parseConfig(cached)) RAVEN_LOG("config loaded from cache");

    NSString* urlStr = [NSString stringWithUTF8String:url];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURL* u = [NSURL URLWithString:urlStr];
        if (!u) return;
        NSData* fresh = [NSData dataWithContentsOfURL:u];
        if (!fresh) { RAVEN_LOG("config fetch failed"); return; }
        if (parseConfig(fresh)) {
            [fresh writeToFile:[NSString stringWithUTF8String:cachePath().c_str()]
                    atomically:YES];
            RAVEN_LOG("config refreshed: %s", g_status);
        }
    });
}

std::string remoteVersion() { return g_version; }
bool hasUpdate() { return g_fetched && g_version != std::string(RAVEN_LOCAL_VERSION); }
std::string updateMessage() { return g_message; }

uint32_t offset(const std::string& key, uint32_t fallback) {
    auto it = g_offsets.find(key);
    return it == g_offsets.end() ? fallback : it->second;
}
bool feature(const std::string& key, bool fallback) {
    auto it = g_features.find(key);
    return it == g_features.end() ? fallback : it->second;
}
std::string asset(const std::string& key, const std::string& fallback) {
    auto it = g_assets.find(key);
    return it == g_assets.end() ? fallback : it->second;
}
const char* status() { return g_status; }

}
""")

# ---------------------------------------------------------------------------
# Src/IL2CPP.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/IL2CPP.h", r"""
#ifndef RAVEN_IL2CPP_H
#define RAVEN_IL2CPP_H

#include <cstdint>
#include <string>
#include <vector>
#include "Common.h"

namespace IL2CPP {
    bool init();
    const char* status();

    void* domain();
    void* image(const char* assembly);
    void* klass(const char* ns, const char* name);
    void* method(void* klass, const char* name, int argc);
    void* field(void* klass, const char* name);

    void* invoke(void* method, void* obj, void** params);
    void* newObject(void* klass);

    template<typename T>
    inline T read(void* obj, uint32_t offset) {
        if (!obj) return T{};
        return *(T*)((uintptr_t)obj + offset);
    }

    template<typename T>
    inline void write(void* obj, uint32_t offset, T value) {
        if (!obj) return;
        *(T*)((uintptr_t)obj + offset) = value;
    }

    void* readListItems(void* obj, uint32_t itemsOffset);
    int   readListCount(void* obj, uint32_t countOffset);

    Matrix4x4 getViewProjection();

    void  readStaticField(void* klass, const char* name, void* out, size_t sz);
    void* readStaticFieldObject(void* klass, const char* name);

    void* objectGetClass(void* obj);
    void* classGetParent(void* klass);
    const char* classGetName(void* klass);
    int methodParamCount(void* method);
    const char* methodParamType(void* method, int index);
    const char* methodReturnType(void* method);

    void* resolveMethod(void* klass, const char* name, int argc);
    void* invokeMethod(void* method, void* obj, void** args);

    uint32_t resolveFieldOffset(void* klass, const char* name);

    void* gameImage();
}
#endif
""")

# ---------------------------------------------------------------------------
# Src/IL2CPP.mm — unchanged.
# ---------------------------------------------------------------------------
w("Src/IL2CPP.mm", r"""
#import "IL2CPP.h"
#import "Common.h"
#import "GameData.h"
#import <dlfcn.h>
#import <cstdio>
#import <cstring>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

namespace IL2CPP {

typedef void*   (*t_domain_get)();
typedef void*   (*t_thread_attach)(void*);
typedef void*   (*t_domain_assembly_open)(void*, const char*);
typedef void*   (*t_assembly_get_image)(void*);
typedef void*   (*t_class_from_name)(void*, const char*, const char*);
typedef void*   (*t_class_get_method_from_name)(void*, const char*, int);
typedef void*   (*t_class_get_field_from_name)(void*, const char*);
typedef void*   (*t_runtime_invoke)(void*, void*, void**, void**);
typedef void*   (*t_object_new)(void*);
typedef uint32_t (*t_field_get_offset)(void*);
typedef void    (*t_field_static_get_value)(void*, void*);
typedef void*   (*t_object_get_class)(void*);
typedef void*   (*t_class_get_parent_fn)(void*);
typedef const char* (*t_class_get_name_fn)(void*);
typedef uint32_t (*t_method_get_param_count_fn)(void*);
typedef void*   (*t_method_get_param_fn)(void*, uint32_t);
typedef const char* (*t_type_get_name_fn)(void*);
typedef void*   (*t_method_get_return_type_fn)(void*);
static t_domain_get p_domain_get = nullptr;
static t_thread_attach p_thread_attach = nullptr;
static t_domain_assembly_open p_domain_assembly_open = nullptr;
static t_assembly_get_image p_assembly_get_image = nullptr;
static t_class_from_name p_class_from_name = nullptr;
static t_class_get_method_from_name p_class_get_method_from_name = nullptr;
static t_class_get_field_from_name p_class_get_field_from_name = nullptr;
static t_runtime_invoke p_runtime_invoke = nullptr;
static t_object_new p_object_new = nullptr;
static t_field_get_offset p_field_get_offset = nullptr;
static t_field_static_get_value p_field_static_get_value = nullptr;
static t_object_get_class p_object_get_class = nullptr;
static t_class_get_parent_fn p_class_get_parent_fn = nullptr;
static t_class_get_name_fn p_class_get_name_fn = nullptr;
static t_method_get_param_count_fn p_method_get_param_count = nullptr;
static t_method_get_param_fn p_method_get_param = nullptr;
static t_type_get_name_fn p_type_get_name = nullptr;
static t_method_get_return_type_fn p_method_get_return_type = nullptr;

static void* g_domain = nullptr;
static void* g_img    = nullptr;
static char  g_status[200] = "not initialized";
static uintptr_t g_base = 0;

static void* rs(const char* n) { return dlsym(RTLD_DEFAULT, n); }

bool init() {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (nm && (strstr(nm, "UnityFramework") || strstr(nm, "GameAssembly"))) {
            g_base = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    if (!g_base && n > 0) g_base = (uintptr_t)_dyld_get_image_header(0);

    p_domain_get = (t_domain_get)rs("il2cpp_domain_get");
    p_thread_attach = (t_thread_attach)rs("il2cpp_thread_attach");
    p_domain_assembly_open = (t_domain_assembly_open)rs("il2cpp_domain_assembly_open");
    p_assembly_get_image = (t_assembly_get_image)rs("il2cpp_assembly_get_image");
    p_class_from_name = (t_class_from_name)rs("il2cpp_class_from_name");
    p_class_get_method_from_name = (t_class_get_method_from_name)rs("il2cpp_class_get_method_from_name");
    p_class_get_field_from_name = (t_class_get_field_from_name)rs("il2cpp_class_get_field_from_name");
    p_runtime_invoke = (t_runtime_invoke)rs("il2cpp_runtime_invoke");
    p_object_new = (t_object_new)rs("il2cpp_object_new");
    p_field_get_offset = (t_field_get_offset)rs("il2cpp_field_get_offset");
    p_method_get_param_count = (t_method_get_param_count_fn)rs("il2cpp_method_get_param_count");
    p_method_get_param = (t_method_get_param_fn)rs("il2cpp_method_get_param");
    p_type_get_name = (t_type_get_name_fn)rs("il2cpp_type_get_name");
    p_method_get_return_type = (t_method_get_return_type_fn)rs("il2cpp_method_get_return_type");

    if (!p_domain_get || !p_class_from_name || !p_assembly_get_image) {
        snprintf(g_status, sizeof(g_status), "il2cpp exports missing");
        return false;
    }
    g_domain = p_domain_get();
    if (!g_domain) { snprintf(g_status, sizeof(g_status), "null domain"); return false; }
    if (p_thread_attach) p_thread_attach(g_domain);
    snprintf(g_status, sizeof(g_status), "il2cpp ok");
    return true;
}

const char* status() { return g_status; }
void* domain() { return g_domain; }

void* image(const char* assembly) {
    if (!g_domain || !p_domain_assembly_open || !p_assembly_get_image) return nullptr;
    void* asm_ = p_domain_assembly_open(g_domain, assembly);
    if (!asm_) return nullptr;
    return p_assembly_get_image(asm_);
}

// ------------------------------------------------------------
// CombatMaster ships its gameplay classes in _CombatMaster.Battle.dll.
// The old hardcoded Assembly-CSharp lookup returned null for every
// gameplay class. This walks every candidate assembly and caches the
// one that worked.
// ------------------------------------------------------------
void* klass(const char* ns, const char* name) {
    if (!p_class_from_name) return nullptr;
    if (g_img) {
        void* k = p_class_from_name(g_img, ns, name);
        if (k) return k;
    }
    static const char* asms[] = {
        "_CombatMaster.Battle.dll",
        "_CombatMaster.Battle",
        "_CombatMaster.View.dll",
        "_CombatMaster.View",
        "Assembly-CSharp.dll",
        "Assembly-CSharp",
        "bolt.user.dll",
        "bolt.user",
        NULL
    };
    for (int i = 0; asms[i]; i++) {
        void* img = image(asms[i]);
        if (!img) continue;
        void* k = p_class_from_name(img, ns, name);
        if (k) { g_img = img; return k; }
    }
    return nullptr;
}

void* method(void* k, const char* name, int argc) {
    if (!k || !p_class_get_method_from_name) return nullptr;
    return p_class_get_method_from_name(k, name, argc);
}

void* field(void* k, const char* name) {
    if (!k || !p_class_get_field_from_name) return nullptr;
    return p_class_get_field_from_name(k, name);
}

void* invoke(void* m, void* obj, void** params) {
    if (!m || !p_runtime_invoke) return nullptr;
    return p_runtime_invoke(m, obj, params, nullptr);
}

void* newObject(void* k) {
    if (!k || !p_object_new) return nullptr;
    return p_object_new(k);
}

void* readListItems(void* obj, uint32_t itemsOffset) {
    if (!obj) return nullptr;
    return *(void**)((uintptr_t)obj + itemsOffset);
}

int readListCount(void* obj, uint32_t countOffset) {
    if (!obj) return 0;
    return *(int*)((uintptr_t)obj + countOffset);
}

void* gameImage() {
    if (!g_img) {
        static const char* asms[] = {
            "_CombatMaster.Battle.dll",
            "_CombatMaster.Battle",
            "_CombatMaster.View.dll",
            "_CombatMaster.View",
            "UnityEngine.CoreModule.dll",
            "UnityEngine.CoreModule",
            "Assembly-CSharp.dll",
            "Assembly-CSharp",
            "bolt.user.dll",
            "bolt.user",
            nullptr
        };
        for (int i = 0; asms[i] && !g_img; i++) {
            g_img = image(asms[i]);
        }
    }
    return g_img;
}

void readStaticField(void* klass, const char* name, void* out, size_t sz) {
    if (!klass || !p_class_get_field_from_name) return;
    void* f = p_class_get_field_from_name(klass, name);
    if (!f) return;
    if (!p_field_static_get_value)
        p_field_static_get_value = (t_field_static_get_value)rs("il2cpp_field_static_get_value");
    if (p_field_static_get_value) p_field_static_get_value(f, out);
}

void* readStaticFieldObject(void* klass, const char* name) {
    void* out = nullptr;
    readStaticField(klass, name, &out, sizeof(void*));
    return out;
}

void* objectGetClass(void* obj) {
    if (!obj) return nullptr;
    if (!p_object_get_class)
        p_object_get_class = (t_object_get_class)rs("il2cpp_object_get_class");
    if (p_object_get_class) return p_object_get_class(obj);
    return *(void**)obj;
}

void* classGetParent(void* klass) {
    if (!klass) return nullptr;
    if (!p_class_get_parent_fn)
        p_class_get_parent_fn = (t_class_get_parent_fn)rs("il2cpp_class_get_parent");
    if (p_class_get_parent_fn) return p_class_get_parent_fn(klass);
    return nullptr;
}

const char* classGetName(void* klass) {
    if (!klass) return "";
    if (!p_class_get_name_fn)
        p_class_get_name_fn = (t_class_get_name_fn)rs("il2cpp_class_get_name");
    if (p_class_get_name_fn) return p_class_get_name_fn(klass);
    return "";
}

int methodParamCount(void* method) {
    return (method && p_method_get_param_count) ? (int)p_method_get_param_count(method) : -1;
}

const char* methodParamType(void* method, int index) {
    if (!method || index < 0 || !p_method_get_param || !p_type_get_name) return "";
    void* type = p_method_get_param(method, (uint32_t)index);
    return type ? p_type_get_name(type) : "";
}

const char* methodReturnType(void* method) {
    if (!method || !p_method_get_return_type || !p_type_get_name) return "";
    void* type = p_method_get_return_type(method);
    return type ? p_type_get_name(type) : "";
}

void* resolveMethod(void* klass, const char* name, int argc) {
    if (!klass || !p_class_get_method_from_name) return nullptr;
    return p_class_get_method_from_name(klass, name, argc);
}

void* invokeMethod(void* method, void* obj, void** args) {
    if (!method || !p_runtime_invoke) return nullptr;
    return p_runtime_invoke(method, obj, args, nullptr);
}

uint32_t resolveFieldOffset(void* klass, const char* name) {
    if (!klass || !p_class_get_field_from_name) return 0;
    void* f = p_class_get_field_from_name(klass, name);
    if (!f) return 0;
    return p_field_get_offset ? (uint32_t)p_field_get_offset(f) : 0;
}

Matrix4x4 getViewProjection() {
    Matrix4x4 out = {0};
    return out;
}

}
""")

# ---------------------------------------------------------------------------
# Src/ESP.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/ESP.h", r"""
#ifndef RAVEN_ESP_H
#define RAVEN_ESP_H
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "Common.h"

@interface RavenESP : NSObject
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) CAShapeLayer *boxes;
@property (nonatomic, strong) CAShapeLayer *lines;
@property (nonatomic, strong) CAShapeLayer *guides;
@property (nonatomic, strong) CATextLayer  *labels;

+ (instancetype)shared;
- (void)attach;
- (void)attachToScene;
- (void)begin;
- (void)end;
- (void)render;
- (NSArray<NSString*>*)snapshotPlayerRows;

- (void)drawBox:(CGRect)r color:(UIColor*)c;
- (void)drawCornerBox:(CGRect)r color:(UIColor*)c;
- (void)drawRoundBox:(CGRect)r color:(UIColor*)c;
- (void)drawHexBox:(CGRect)r color:(UIColor*)c;
- (void)drawGradientBox:(CGRect)r color:(UIColor*)c;
- (void)drawEliteBox:(CGRect)r color:(UIColor*)c;
- (void)drawLine:(CGPoint)a to:(CGPoint)b color:(UIColor*)c;
- (void)drawGuideCircle:(CGPoint)center radius:(CGFloat)radius color:(UIColor*)c;
@end
#endif
""")

# ---------------------------------------------------------------------------
# Src/ESP.mm — MODIFIED (phantom-slot filter, slot dump, bone sanity).
# ---------------------------------------------------------------------------
w("Src/ESP.mm", r"""
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
static void*  g_getPosition = nullptr;
static void*  g_worldToScreen = nullptr;

static void*  g_getHealth = nullptr;
static void*  g_getIsDead = nullptr;
static void*  g_getIsDowned = nullptr;
static void*  g_getPlayerName = nullptr;
static void*  g_getWeaponName = nullptr;

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
        g_getPlayerName   = IL2CPP::resolveMethod(g_playerRootClass, "get_Nickname", 0);
        if (!g_getPlayerName) g_getPlayerName = IL2CPP::resolveMethod(g_playerRootClass, "get_PlayerName", 0);
        if (!g_getPlayerName) g_getPlayerName = IL2CPP::resolveMethod(g_playerRootClass, "get_Name", 0);
        g_getWeaponName   = IL2CPP::resolveMethod(g_playerRootClass, "get_WeaponName", 0);
        if (!g_getWeaponName) g_getWeaponName = IL2CPP::resolveMethod(g_playerRootClass, "get_CurrentWeaponName", 0);
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
static float invokeFloat(void* method, void* obj) {
    if (!method || !obj) return 0;
    void* r = IL2CPP::invokeMethod(method, obj, nullptr);
    return r ? *(float*)((uint8_t*)r + 0x10) : 0;
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
    switch (index) {
        case 1: return [UIColor colorWithRed:0.20 green:0.95 blue:0.35 alpha:0.95];
        case 2: return [UIColor colorWithWhite:0.96 alpha:0.95];
        case 3: return [UIColor colorWithRed:1.00 green:0.82 blue:0.12 alpha:0.95];
        case 4: return [UIColor colorWithRed:0.15 green:0.85 blue:1.00 alpha:0.95];
        default: return [UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:0.95];
    }
}

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
        self.window.windowScene = ws;

        CGRect sceneBounds = ws.coordinateSpace.bounds;
        if (sceneBounds.size.width < 1 || sceneBounds.size.height < 1) {
            sceneBounds = [UIScreen mainScreen].bounds;
        }
        CGRect normalized = (CGRect){ CGPointZero, sceneBounds.size };
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

        self.window.hidden = !RavenSettings::espEnabled;

        static bool logged = false;
        if (!logged) {
            RAVEN_LOG("esp-scene: scene=%.0fx%.0f win=%@ boxes=%@ root=%@",
                      normalized.size.width, normalized.size.height,
                      NSStringFromCGRect(self.window.frame),
                      NSStringFromCGRect(self.boxes.frame),
                      NSStringFromCGRect(root.view.frame));
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
    BOOL guidesEnabled = RavenSettings::aimShowCircle || RavenSettings::visCrosshair || RavenSettings::visFovCircle;
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
    }
    if (RavenSettings::visFovCircle) {
        [self drawGuideCircle:guideCenter radius:RavenSettings::visFovRadius
                         color:[UIColor colorWithRed:0.95 green:0.75 blue:0.20 alpha:0.78]];
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
        if (team != 0 && team == localTeam) continue;

        uint8_t bOwner   = readU8(p, GameData::PlayerRoot::IsOwner);
        uint8_t bCtrl    = readU8(p, GameData::PlayerRoot::HasControl);
        uint8_t bVisible = readU8(p, GameData::PlayerRoot::IsVisible);
        uint8_t bReal    = readU8(p, GameData::PlayerRoot::IsRealPlayer);

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
        float boxW = boxH * 0.42f;

        CGRect boxRect = CGRectMake(headScreen.x - boxW/2.0, headScreen.y, boxW, boxH);
        UIColor* boxColor = espPaletteColor(bVisible ? RavenSettings::espVisibleColor
                                                     : RavenSettings::espEnemyColor);
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

        if (RavenSettings::espSnaplines) {
            [self drawLine:CGPointMake(screen.width / 2.0, screen.height)
                        to:CGPointMake(headScreen.x, feetScreen.y)
                     color:[UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:0.55]];
        }

        NSMutableString* line = [NSMutableString string];
        if (RavenSettings::espName) {
            NSString* name = invokeString(g_getPlayerName, p);
            if (!name.length) name = [NSString stringWithFormat:@"Player %d", i];
            [line appendFormat:@"%@ ", name];
        }
        if (RavenSettings::espWeapon) {
            NSString* weapon = invokeString(g_getWeaponName, p);
            if (weapon.length) [line appendFormat:@"[%@] ", weapon];
        }
        if (RavenSettings::espHealth && ptrOk(healthComp) && g_getHealth) {
            float hp = invokeFloat(g_getHealth, healthComp);
            [line appendFormat:@"%.0f ", hp];
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
        [rows addObject:[NSString stringWithFormat:@"%@  •  %@", name, state]];
    }
    return rows;
}

@end
""")

# ---------------------------------------------------------------------------
# Src/Aimbot.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/Aimbot.h", r"""
#ifndef RAVEN_AIMBOT_H
#define RAVEN_AIMBOT_H
#include "Common.h"

namespace RavenAimbot {
    void setEnabled(bool on);
    void tick();
}
#endif
""")

# ---------------------------------------------------------------------------
# Src/Aimbot.mm — placeholder. The real source is Aimbot_fixed.mm at repo
# root, and the tail of this script overwrites Src/Aimbot.mm with it after
# every run. What's emitted here is only a fallback for the case where
# Aimbot_fixed.mm is missing.
# ---------------------------------------------------------------------------
w("Src/Aimbot.mm", r"""
#import "Aimbot.h"
#import "GameData.h"
#import "IL2CPP.h"
#import "Settings.h"
#import <UIKit/UIKit.h>

namespace RavenAimbot {
void setEnabled(bool on) { RavenSettings::aimEnabled = on; }
void tick() {}
}
""")

# ---------------------------------------------------------------------------
# Src/Menu.h — unchanged.
# ---------------------------------------------------------------------------
w("Src/Menu.h", r"""
#ifndef RAVEN_MENU_H
#define RAVEN_MENU_H
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

@interface RavenWindow : UIWindow
@end

@interface RavenMenu : NSObject
+ (instancetype)shared;
- (void)start;
- (void)setVisible:(BOOL)v;
- (BOOL)isPanelOpen;
@end

@interface RVToggle : UIView
@property (nonatomic, assign) BOOL on;
@property (nonatomic, copy) void (^onChange)(BOOL);
- (void)setOn:(BOOL)on animated:(BOOL)animated;
@end

@interface RVSlider : UIView
@property (nonatomic, assign) float value;
@property (nonatomic, assign) float minValue;
@property (nonatomic, assign) float maxValue;
@property (nonatomic, copy) void (^onChange)(float);
@end

@interface RVSelector : UIView
@property (nonatomic, copy) NSArray<NSString*>* items;
@property (nonatomic, assign) NSInteger selectedIndex;
@property (nonatomic, copy) void (^onChange)(NSInteger);
- (instancetype)initWithItems:(NSArray<NSString*>*)items selected:(NSInteger)selected;
@end

#endif
""")

# ---------------------------------------------------------------------------
# Src/Menu.mm — unchanged from the prior full tree.
# ---------------------------------------------------------------------------
w("Src/Menu.mm", r"""
#import "Menu.h"
#import "Common.h"
#import "Logos.h"
#import "ESP.h"
#import "Aimbot.h"
#import "IL2CPP.h"
#import "Updater.h"
#import "Settings.h"
#import <objc/runtime.h>

#define C_WIN      [UIColor colorWithRed:0.043 green:0.043 blue:0.055 alpha:0.97]
#define C_HEAD     [UIColor colorWithRed:0.051 green:0.051 blue:0.063 alpha:1.0]
#define C_SIDE     [UIColor colorWithRed:0.055 green:0.055 blue:0.071 alpha:1.0]
#define C_CARD     [UIColor colorWithRed:0.078 green:0.078 blue:0.090 alpha:1.0]
#define C_BORDER   [UIColor colorWithRed:0.157 green:0.157 blue:0.165 alpha:1.0]
#define C_RED      [UIColor colorWithRed:0.835 green:0.122 blue:0.157 alpha:1.0]
#define C_CRIMSON  [UIColor colorWithRed:0.290 green:0.067 blue:0.086 alpha:1.0]
#define C_TEXT     [UIColor colorWithRed:0.949 green:0.949 blue:0.957 alpha:1.0]
#define C_SEC      [UIColor colorWithRed:0.573 green:0.573 blue:0.608 alpha:1.0]
#define C_MUTE     [UIColor colorWithRed:0.384 green:0.384 blue:0.420 alpha:1.0]

static const CGFloat kRefW       = 860;
static const CGFloat kRefH       = 500;
static const CGFloat kHeaderH    = 84;
static const CGFloat kFooterH    = 28;
static const CGFloat kSidebarW   = 168;
static const CGFloat kPad        = 18;
static const CGFloat kCardGap    = 12;
static const CGFloat kCardRad    = 8;
static const CGFloat kTabH       = 40;
static const CGFloat kRowH       = 28;
static const CGFloat kRowHBig    = 46;

static NSCache* g_imgCache = nil;
typedef void(^ImgBlock)(UIImage*);

static NSString* diskPathFor(NSString* key) {
    NSString* dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
    NSString* hash = [NSString stringWithFormat:@"%lu", (unsigned long)key.hash];
    return [dir stringByAppendingPathComponent:[hash stringByAppendingString:@".img"]];
}

static UIImage* loadCachedImage(const char* url) {
    if (!url || !*url) return nil;
    if (!g_imgCache) g_imgCache = [[NSCache alloc] init];
    NSString* key = [NSString stringWithUTF8String:url];
    UIImage* c = [g_imgCache objectForKey:key];
    if (c) return c;
    NSData* d = [NSData dataWithContentsOfFile:diskPathFor(key)];
    if (!d) return nil;
    UIImage* img = [UIImage imageWithData:d];
    if (img) [g_imgCache setObject:img forKey:key];
    return img;
}

static void loadLogoURLAsync(const char* url, ImgBlock cb) {
    if (!url || !*url) { if (cb) cb(nil); return; }
    UIImage* cached = loadCachedImage(url);
    if (cached) { if (cb) cb(cached); return; }
    if (cb) cb(nil);

    NSString* key = [NSString stringWithUTF8String:url];
    NSURL* u = [NSURL URLWithString:key];
    if (!u) return;

    NSURLSessionDataTask* task =
        [[NSURLSession sharedSession] dataTaskWithURL:u
                                    completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
        if (!data) return;
        UIImage* img = [UIImage imageWithData:data];
        if (!img) return;
        if (!g_imgCache) g_imgCache = [[NSCache alloc] init];
        [g_imgCache setObject:img forKey:key];
        [data writeToFile:diskPathFor(key) atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cb) cb(img);
        });
    }];
    [task resume];
}

static UIImage* cropNormalized(UIImage* img, CGRect n) {
    if (!img || !img.CGImage) return img;
    size_t w = CGImageGetWidth(img.CGImage);
    size_t h = CGImageGetHeight(img.CGImage);
    CGRect px = CGRectMake(n.origin.x * w,
                           n.origin.y * h,
                           n.size.width * w,
                           n.size.height * h);
    px = CGRectIntersection(px, CGRectMake(0, 0, w, h));
    if (CGRectIsEmpty(px)) return img;
    CGImageRef cg = CGImageCreateWithImageInRect(img.CGImage, px);
    if (!cg) return img;
    UIImage* out = [UIImage imageWithCGImage:cg scale:img.scale orientation:img.imageOrientation];
    CGImageRelease(cg);
    return out;
}

static UILabel* lbl(NSString* t, CGFloat sz, UIColor* c, BOOL bold) {
    UILabel* l = [UILabel new];
    l.text = t;
    l.textColor = c;
    l.font = bold ? [UIFont systemFontOfSize:sz weight:UIFontWeightSemibold]
                  : [UIFont systemFontOfSize:sz weight:UIFontWeightRegular];
    l.numberOfLines = 1;
    l.backgroundColor = [UIColor clearColor];
    return l;
}

static NSUInteger raven_landscape_mask(id self, SEL _cmd) {
    return UIInterfaceOrientationMaskLandscape;
}

static void forceLandscape(void) {
    Method m = class_getInstanceMethod([UIViewController class],
                                       @selector(supportedInterfaceOrientations));
    if (m) {
        method_setImplementation(m, (IMP)raven_landscape_mask);
    }
}

@implementation RavenWindow
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        self.exclusiveTouch = NO;
        self.backgroundColor = [UIColor clearColor];
    }
    return self;
}
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    RavenMenu* m = [RavenMenu shared];
    if (!m) return nil;
    UIView* panel = [m valueForKey:@"panel"];
    UIView* ball  = [m valueForKey:@"ball"];
    if (panel && !panel.hidden && panel.alpha > 0.01) {
        CGPoint p = [panel convertPoint:point fromView:self];
        if ([panel pointInside:p withEvent:event]) {
            return [panel hitTest:p withEvent:event];
        }
    }
    if (ball && !ball.hidden && ball.alpha > 0.01) {
        CGPoint p = [ball convertPoint:point fromView:self];
        if ([ball pointInside:p withEvent:event]) {
            UIView* hit = [ball hitTest:p withEvent:event];
            if (hit) return hit;
        }
    }
    // Never consume gameplay touches outside the menu controls. Returning
    // nil here is required for the underlying game view to receive drag,
    // look, and touch/gyro input normally.
    return nil;
}
@end

@implementation RVToggle { UIView* _track; UIView* _knob; }
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 40, 22)])) {
        self.userInteractionEnabled = YES;
        _track = [[UIView alloc] initWithFrame:CGRectMake(0, 1, 40, 20)];
        _track.layer.cornerRadius = 10;
        _track.layer.borderWidth = 1;
        _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.07].CGColor;
        _track.backgroundColor = [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1.0];
        [self addSubview:_track];
        _knob = [[UIView alloc] initWithFrame:CGRectMake(3, 3, 16, 16)];
        _knob.layer.cornerRadius = 8;
        _knob.backgroundColor = [UIColor colorWithWhite:0.97 alpha:1.0];
        _knob.layer.shadowColor = [UIColor blackColor].CGColor;
        _knob.layer.shadowOpacity = 0.42;
        _knob.layer.shadowRadius = 3;
        _knob.layer.shadowOffset = CGSizeMake(0, 1);
        [self addSubview:_knob];
        UITapGestureRecognizer* t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)];
        t.cancelsTouchesInView = YES;
        [self addGestureRecognizer:t];
    }
    return self;
}
- (void)toggle {
    UIImpactFeedbackGenerator* h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [h impactOccurred];
    self.on = !self.on;
    [self applyStateAnimated:RavenSettings::animations];
    if (self.onChange) self.onChange(self.on);
}
- (void)setOn:(BOOL)on { [self setOn:on animated:NO]; }
- (void)setOn:(BOOL)on animated:(BOOL)animated { _on = on; [self applyStateAnimated:animated]; }
- (void)applyStateAnimated:(BOOL)animated {
    UIColor* track = _on ? C_RED : [UIColor colorWithRed:0.17 green:0.17 blue:0.19 alpha:1.0];
    CGRect knob = _on ? CGRectMake(21, 3, 16, 16) : CGRectMake(3, 3, 16, 16);
    void (^blk)(void) = ^{
        _track.backgroundColor = track;
        _track.layer.borderColor = (_on ? [C_RED colorWithAlphaComponent:0.85] : [UIColor colorWithWhite:1 alpha:0.07]).CGColor;
        _track.layer.shadowColor = C_RED.CGColor;
        _track.layer.shadowOpacity = _on ? 0.28 : 0.0;
        _track.layer.shadowRadius = _on ? 5.0 : 0.0;
        _track.layer.shadowOffset = CGSizeZero;
        _knob.frame = knob;
    };
    if (animated) {
        [UIView animateWithDuration:0.28
                              delay:0
             usingSpringWithDamping:0.72
              initialSpringVelocity:0.45
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:blk completion:nil];
    } else {
        blk();
    }
}
@end

@implementation RVSlider { UIView* _track; UIView* _fill; UIView* _thumb; float _t; }
- (instancetype)init {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 200, 20)])) {
        self.userInteractionEnabled = YES;
        _minValue = 0; _maxValue = 100; _value = 0; _t = 0;
        _track = [UIView new];
        _track.backgroundColor = [UIColor colorWithRed:0.19 green:0.19 blue:0.22 alpha:1.0];
        _track.layer.cornerRadius = 2.0;
        _track.layer.borderWidth = 0.5;
        _track.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.035].CGColor;
        [self addSubview:_track];
        _fill = [UIView new];
        _fill.backgroundColor = C_RED;
        _fill.layer.cornerRadius = 2.0;
        _fill.layer.shadowColor = C_RED.CGColor;
        _fill.layer.shadowOpacity = 0.24;
        _fill.layer.shadowRadius = 4;
        _fill.layer.shadowOffset = CGSizeZero;
        [self addSubview:_fill];
        _thumb = [UIView new];
        _thumb.backgroundColor = [UIColor colorWithWhite:0.985 alpha:1.0];
        _thumb.layer.cornerRadius = 6;
        _thumb.layer.borderWidth = 1.5;
        _thumb.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.72].CGColor;
        _thumb.layer.shadowColor = C_RED.CGColor;
        _thumb.layer.shadowOpacity = 0.36;
        _thumb.layer.shadowRadius = 4;
        _thumb.layer.shadowOffset = CGSizeZero;
        [self addSubview:_thumb];
        UIPanGestureRecognizer* p = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onDrag:)];
        p.cancelsTouchesInView = YES;
        [self addGestureRecognizer:p];
        UITapGestureRecognizer* t = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onTap:)];
        t.cancelsTouchesInView = YES;
        [self addGestureRecognizer:t];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat th = 4.0;
    CGFloat ty = (h - th) / 2.0;
    CGFloat padL = 8.0;
    CGFloat padR = 8.0;
    CGFloat usable = w - padL - padR;
    _track.frame = CGRectMake(padL, ty, usable, th);
    _fill.frame  = CGRectMake(padL, ty, usable * _t, th);
    CGFloat thumbX = padL + usable * _t - 6.0;
    _thumb.frame = CGRectMake(thumbX, (h - 12.0) / 2.0, 12.0, 12.0);
}
- (void)setValue:(float)value {
    float v = MAX(_minValue, MIN(_maxValue, value));
    _value = v;
    _t = (_maxValue == _minValue) ? 0 : (v - _minValue) / (_maxValue - _minValue);
    [self setNeedsLayout];
}
- (void)onDrag:(UIPanGestureRecognizer*)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        UIImpactFeedbackGenerator* h = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [h impactOccurred];
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.14 animations:^{ self->_thumb.transform = CGAffineTransformMakeScale(1.24, 1.24); }];
        }
    }
    CGPoint p = [g locationInView:self];
    CGFloat w = self.bounds.size.width;
    CGFloat padL = 8.0, padR = 8.0;
    CGFloat frac = MAX(0, MIN(1, (p.x - padL) / (w - padL - padR)));
    float v = _minValue + frac * (_maxValue - _minValue);
    self.value = v;
    if (self.onChange) self.onChange(v);
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.18 animations:^{ self->_thumb.transform = CGAffineTransformIdentity; }];
        } else {
            _thumb.transform = CGAffineTransformIdentity;
        }
    }
}
- (void)onTap:(UITapGestureRecognizer*)g {
    CGPoint p = [g locationInView:self];
    CGFloat w = self.bounds.size.width;
    CGFloat padL = 8.0, padR = 8.0;
    CGFloat frac = MAX(0, MIN(1, (p.x - padL) / (w - padL - padR)));
    float v = _minValue + frac * (_maxValue - _minValue);
    self.value = v;
    UISelectionFeedbackGenerator* h = [UISelectionFeedbackGenerator new];
    [h selectionChanged];
    if (self.onChange) self.onChange(v);
    if (RavenSettings::animations) {
        _thumb.transform = CGAffineTransformMakeScale(1.18, 1.18);
        [UIView animateWithDuration:0.16 animations:^{ self->_thumb.transform = CGAffineTransformIdentity; }];
    }
}
@end

@implementation RVSelector { UIButton* _button; UILabel* _valueLabel; UIImageView* _chevron; }

- (instancetype)initWithItems:(NSArray<NSString*>*)items selected:(NSInteger)selected {
    if ((self = [super initWithFrame:CGRectMake(0, 0, 112, 24)])) {
        self.userInteractionEnabled = YES;
        self.layer.cornerRadius = 6;
        self.layer.borderWidth = 1;
        self.layer.borderColor = C_BORDER.CGColor;
        self.backgroundColor = [UIColor colorWithRed:0.092 green:0.092 blue:0.105 alpha:1.0];
        _valueLabel = lbl(@"", 11, C_TEXT, NO);
        _valueLabel.frame = CGRectMake(10, 0, 76, 24);
        [self addSubview:_valueLabel];
        UIImage* chevronImage = [UIImage systemImageNamed:@"chevron.down"];
        _chevron = [[UIImageView alloc] initWithImage:chevronImage];
        _chevron.tintColor = C_SEC;
        _chevron.contentMode = UIViewContentModeScaleAspectFit;
        _chevron.frame = CGRectMake(92, 7, 10, 10);
        [self addSubview:_chevron];
        _button = [UIButton buttonWithType:UIButtonTypeCustom];
        _button.frame = self.bounds;
        _button.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_button addTarget:self action:@selector(cycleSelection) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_button];
        _items = [items copy] ?: @[];
        _selectedIndex = MAX(0, MIN((NSInteger)_items.count - 1, selected));
        [self rebuildMenu];
    }
    return self;
}
- (void)cycleSelection {
    if (_items.count == 0) return;
    NSInteger next = (_selectedIndex + 1) % (NSInteger)_items.count;
    self.selectedIndex = next;
    UISelectionFeedbackGenerator* h = [UISelectionFeedbackGenerator new];
    [h selectionChanged];
    if (self.onChange) self.onChange(next);
}
- (void)setItems:(NSArray<NSString*>*)items {
    _items = [items copy] ?: @[];
    if (_selectedIndex >= (NSInteger)_items.count) _selectedIndex = MAX(0, (NSInteger)_items.count - 1);
    [self rebuildMenu];
}
- (void)setSelectedIndex:(NSInteger)selectedIndex {
    if (_items.count == 0) {
        _selectedIndex = 0;
        _valueLabel.text = @"-";
        return;
    }
    _selectedIndex = MAX(0, MIN((NSInteger)_items.count - 1, selectedIndex));
    _valueLabel.text = _items[_selectedIndex];
    [self rebuildMenu];
}
- (void)rebuildMenu {
    if (!_button) return;
    if (_items.count == 0) {
        _valueLabel.text = @"-";
        _button.menu = nil;
        return;
    }
    NSMutableArray<UIMenuElement*>* actions = [NSMutableArray array];
    __weak RVSelector* weakSelf = self;
    for (NSInteger i = 0; i < (NSInteger)_items.count; i++) {
        NSString* title = _items[i];
        UIAction* a = [UIAction actionWithTitle:title
                                          image:nil
                                     identifier:nil
                                        handler:^(__kindof UIAction* action) {
            (void)action;
            RVSelector* selfRef = weakSelf;
            if (!selfRef) return;
            selfRef->_selectedIndex = i;
            selfRef->_valueLabel.text = title;
            UISelectionFeedbackGenerator* h = [UISelectionFeedbackGenerator new];
            [h selectionChanged];
            if (RavenSettings::animations) {
                selfRef.transform = CGAffineTransformMakeScale(0.97, 0.97);
                [UIView animateWithDuration:0.18 animations:^{
                    selfRef.transform = CGAffineTransformIdentity;
                }];
            }
            if (selfRef.onChange) selfRef.onChange(i);
            [selfRef rebuildMenu];
        }];
        if (i == _selectedIndex) a.state = UIMenuElementStateOn;
        [actions addObject:a];
    }
    _button.menu = [UIMenu menuWithTitle:@"" children:actions];
    _valueLabel.text = _items[_selectedIndex];
}
@end

@interface RavenMenu ()
@property (nonatomic, strong) RavenWindow* window;
@property (nonatomic, strong, readwrite) UIView* panel;
@property (nonatomic, strong, readwrite) UIView* ball;
@property (nonatomic, strong) UIView*   panelInner;
@property (nonatomic, strong) UIView*   headerView;
@property (nonatomic, strong) UIView*   sidebarView;
@property (nonatomic, strong) UIView*   contentView;
@property (nonatomic, strong) UIView*   footerView;
@property (nonatomic, strong) NSMutableArray* tabButtons;
@property (nonatomic, strong) NSMutableDictionary* tabViews;
@property (nonatomic, assign) NSInteger activeTab;
@property (nonatomic, strong) NSTimer* tickTimer;
@property (nonatomic, assign) BOOL panelOpen;
@property (nonatomic, assign) BOOL runtimeActive;
@property (nonatomic, assign) CGFloat uiScale;
@property (nonatomic, assign) CGSize  lastBounds;
@property (nonatomic, assign) CGRect  dragStartFrame;
@property (nonatomic, assign) BOOL    hasPanelPosition;
@property (nonatomic, strong) UIView* toastView;
@property (nonatomic, strong) NSTimer* toastTimer;
@end

@implementation RavenMenu

+ (instancetype)shared {
    static RavenMenu* s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [RavenMenu new]; });
    return s;
}

- (BOOL)isPanelOpen { return self.panelOpen; }

- (void)start {
    if (self.window) return;
    [[RavenESP shared] attach];

    self.tabButtons    = [NSMutableArray array];
    self.tabViews      = [NSMutableDictionary dictionary];
    self.activeTab     = 0;
    self.uiScale       = 1.0;
    self.lastBounds    = CGSizeZero;
    self.hasPanelPosition = NO;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        loadCachedImage(kWordmarkURL);
        loadCachedImage(kBallLogoURL);
        loadCachedImage(kEmblemURL);
        loadLogoURLAsync(kWordmarkURL, ^(UIImage* i){ (void)i; });
        loadLogoURLAsync(kBallLogoURL,   ^(UIImage* i){ (void)i; });
        loadLogoURLAsync(kEmblemURL,     ^(UIImage* i){ (void)i; });
    });

    self.window = [[RavenWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.windowLevel = UIWindowLevelNormal + 1.0;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController.view.userInteractionEnabled = YES;
    [self attachToScene];
    self.window.hidden = NO;

    [self buildPanel];
    [self buildBall];
    [self relayout];

    self.panel.hidden = YES;
    self.ball.hidden  = (RavenSettings::uiOpenButton == 2);
    self.runtimeActive = true;

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGeometryChanged)
                                                 name:UIDeviceOrientationDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGeometryChanged)
                                                 name:@"UIWindowSceneDidUpdateCoordinateSpaceNotification"
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onGeometryChanged)
                                                 name:UISceneDidActivateNotification
                                               object:nil];

    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0
                                                      target:self
                                                    selector:@selector(onTick)
                                                    userInfo:nil
                                                     repeats:YES];
    RAVEN_LOG("menu started");
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (void)attachToScene {
    for (UIScene* s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) {
            if (s.activationState == UISceneActivationStateForegroundActive ||
                s.activationState == UISceneActivationStateForegroundInactive) {
                self.window.windowScene = (UIWindowScene*)s;
                return;
            }
        }
    }
}

- (void)setVisible:(BOOL)v { self.window.hidden = !v; }

- (void)onGeometryChanged {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self attachToScene];
        self.window.hidden = NO;
        [self relayout];
        [self clampPanel];
    });
}

- (void)relayout {
    if (!self.window) return;
    CGRect screen = self.window.bounds;
    if (screen.size.width < 1 || screen.size.height < 1) return;

    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGFloat usableW = screen.size.width - safe.left - safe.right;
    CGFloat usableH = screen.size.height - safe.top - safe.bottom;

    CGFloat requestedScale = MAX(0.50, MIN(1.50, RavenSettings::menuScale / 100.0));
    CGFloat safeFit = MIN(usableW / kRefW, usableH / kRefH);
    CGFloat fit = MIN(requestedScale, safeFit);
    self.uiScale = fit;

    CGFloat panelW = kRefW * fit;
    CGFloat panelH = kRefH * fit;

    CGPoint oldCenter = self.panel ? self.panel.center
                                   : CGPointMake(safe.left + usableW / 2.0,
                                                 safe.top + usableH / 2.0);
    CGFloat panelX = safe.left + (usableW - panelW) / 2.0;
    CGFloat panelY = safe.top  + (usableH - panelH) / 2.0;
    if (self.hasPanelPosition && self.panel) {
        panelX = oldCenter.x - panelW / 2.0;
        panelY = oldCenter.y - panelH / 2.0;
    }

    self.panel.transform = CGAffineTransformIdentity;
    self.panel.frame = CGRectMake(panelX, panelY, panelW, panelH);

    CGFloat sx = panelW / kRefW;
    CGFloat sy = panelH / kRefH;
    self.panelInner.bounds = CGRectMake(0, 0, kRefW, kRefH);
    self.panelInner.transform = CGAffineTransformIdentity;
    self.panelInner.transform = CGAffineTransformMakeScale(sx, sy);
    self.panelInner.center = CGPointMake(panelW / 2.0, panelH / 2.0);

    CGFloat bsize = 46;
    self.panel.alpha = MAX(0.20, MIN(1.0, RavenSettings::miscMenuOpacity / 100.0));
    if (!self.ball.hidden && RavenSettings::uiOpenButton != 2) {
        CGFloat bx = screen.size.width - safe.right - bsize - 16;
        if (RavenSettings::uiPosition == 1) bx = safe.left + 16;
        if (RavenSettings::uiPosition == 2) bx = (screen.size.width - bsize) / 2.0;
        CGFloat by = safe.top + 24;
        bx = MAX(safe.left + 4, MIN(screen.size.width - safe.right - bsize - 4, bx));
        by = MAX(safe.top + 4,  MIN(screen.size.height - safe.bottom - bsize - 4, by));
        self.ball.frame = CGRectMake(bx, by, bsize, bsize);
    }
}

- (void)clampPanel {
    if (!self.window || self.panel.hidden) return;
    CGRect screen = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGRect f = self.panel.frame;
    CGFloat maxW = screen.size.width - safe.left - safe.right;
    CGFloat maxH = screen.size.height - safe.top - safe.bottom;
    if (f.size.width  > maxW) f.size.width  = maxW;
    if (f.size.height > maxH) f.size.height = maxH;
    CGFloat minX = safe.left;
    CGFloat maxX = screen.size.width - safe.right - f.size.width;
    CGFloat minY = safe.top;
    CGFloat maxY = screen.size.height - safe.bottom - f.size.height;
    if (maxX < minX) maxX = minX;
    if (maxY < minY) maxY = minY;
    f.origin.x = MAX(minX, MIN(maxX, f.origin.x));
    f.origin.y = MAX(minY, MIN(maxY, f.origin.y));
    self.panel.frame = f;
}

- (void)centerPanel {
    if (!self.window) return;
    CGRect screen = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGFloat usableW = screen.size.width - safe.left - safe.right;
    CGFloat usableH = screen.size.height - safe.top - safe.bottom;
    CGRect f = self.panel.frame;
    f.origin.x = safe.left + (usableW - f.size.width) / 2;
    f.origin.y = safe.top  + (usableH - f.size.height) / 2;
    self.panel.frame = f;
}

- (void)buildBall {
    CGFloat size = 46;
    self.ball = [[UIView alloc] initWithFrame:CGRectMake(0, 0, size, size)];
    self.ball.backgroundColor = C_WIN;
    self.ball.layer.cornerRadius = size / 2.0;
    self.ball.layer.borderWidth = 1.5;
    self.ball.layer.borderColor = C_RED.CGColor;
    self.ball.layer.shadowColor = C_RED.CGColor;
    self.ball.layer.shadowOpacity = 0.6;
    self.ball.layer.shadowRadius = 10;
    self.ball.layer.shadowOffset = CGSizeZero;
    self.ball.userInteractionEnabled = YES;
    self.ball.multipleTouchEnabled = NO;

    UILabel* placeholder = [[UILabel alloc] initWithFrame:self.ball.bounds];
    placeholder.text = @"R";
    placeholder.textAlignment = NSTextAlignmentCenter;
    placeholder.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    placeholder.textColor = C_RED;
    placeholder.tag = 700;
    [self.ball addSubview:placeholder];

    UIImageView* iv = [[UIImageView alloc] initWithFrame:CGRectInset(self.ball.bounds, 3, 3)];
    iv.contentMode = UIViewContentModeScaleAspectFill;
    iv.layer.cornerRadius = (size - 6) / 2.0;
    iv.clipsToBounds = YES;
    iv.userInteractionEnabled = NO;
    iv.hidden = YES;
    iv.tag = 701;
    [self.ball addSubview:iv];

    __weak UIImageView* weakIV = iv;
    __weak UILabel* weakPH = placeholder;
    loadLogoURLAsync(kBallLogoURL, ^(UIImage* img) {
        if (!img) return;
        weakIV.image = img;
        weakIV.hidden = NO;
        weakPH.hidden = YES;
    });

    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(togglePanel)];
    tap.cancelsTouchesInView = YES;
    [self.ball addGestureRecognizer:tap];

    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragBall:)];
    pan.cancelsTouchesInView = YES;
    pan.maximumNumberOfTouches = 1;
    [self.ball addGestureRecognizer:pan];

    [self.window addSubview:self.ball];
}

- (void)togglePanel {
    self.panelOpen = !self.panelOpen;
    if (self.panelOpen) {
        [self relayout];
        if (!self.hasPanelPosition) [self centerPanel];
        [self clampPanel];
        self.panel.hidden = NO;
        self.ball.hidden = YES;
        [self.window bringSubviewToFront:self.panel];
        if (RavenSettings::animations) {
            self.panel.alpha = 0.0;
            self.panel.transform = CGAffineTransformMakeScale(0.965, 0.965);
            [UIView animateWithDuration:0.24
                                  delay:0
                 usingSpringWithDamping:0.84
                  initialSpringVelocity:0.35
                                options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                             animations:^{
                self.panel.alpha = 1.0;
                self.panel.transform = CGAffineTransformIdentity;
            } completion:nil];
        } else {
            self.panel.alpha = 1.0;
            self.panel.transform = CGAffineTransformIdentity;
        }
    } else {
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.16 animations:^{
                self.panel.alpha = 0.0;
                self.panel.transform = CGAffineTransformMakeScale(0.975, 0.975);
            } completion:^(BOOL finished) {
                self.panel.hidden = YES;
                self.panel.alpha = 1.0;
                self.panel.transform = CGAffineTransformIdentity;
                self.ball.hidden = NO;
                self.ball.alpha = 0.0;
                self.ball.transform = CGAffineTransformMakeScale(0.82, 0.82);
                [self.window bringSubviewToFront:self.ball];
                [UIView animateWithDuration:0.18 animations:^{
                    self.ball.alpha = 1.0;
                    self.ball.transform = CGAffineTransformIdentity;
                }];
            }];
        } else {
            self.panel.hidden = YES;
            self.ball.hidden = NO;
            [self.window bringSubviewToFront:self.ball];
        }
    }
}

- (void)dragBall:(UIPanGestureRecognizer*)g {
    if (!self.window) return;
    CGRect screen = self.window.bounds;
    UIEdgeInsets safe = self.window.safeAreaInsets;
    CGPoint t = [g translationInView:self.window];
    CGPoint c = self.ball.center;
    c.x += t.x; c.y += t.y;
    CGFloat hs = self.ball.bounds.size.width / 2.0;
    c.x = MAX(safe.left + hs, MIN(screen.size.width - safe.right - hs, c.x));
    c.y = MAX(safe.top + hs,  MIN(screen.size.height - safe.bottom - hs, c.y));
    self.ball.center = c;
    [g setTranslation:CGPointZero inView:self.window];
}

- (void)buildPanel {
    self.panel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kRefW, kRefH)];
    self.panel.backgroundColor = C_WIN;
    self.panel.layer.cornerRadius = 12;
    self.panel.layer.borderWidth = 1;
    self.panel.layer.borderColor = C_CRIMSON.CGColor;
    self.panel.layer.shadowColor = [UIColor blackColor].CGColor;
    self.panel.layer.shadowOpacity = 0.7;
    self.panel.layer.shadowRadius = 24;
    self.panel.layer.shadowOffset = CGSizeMake(0, 8);
    self.panel.clipsToBounds = YES;
    self.panel.userInteractionEnabled = YES;

    self.panelInner = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kRefW, kRefH)];
    self.panelInner.backgroundColor = [UIColor clearColor];
    [self.panel addSubview:self.panelInner];

    [self buildHeader:CGRectMake(0, 0, kRefW, kHeaderH)];
    [self buildSidebar:CGRectMake(0, kHeaderH, kSidebarW, kRefH - kHeaderH - kFooterH)];
    [self buildContent:CGRectMake(kSidebarW, kHeaderH, kRefW - kSidebarW, kRefH - kHeaderH - kFooterH)];
    [self buildFooter:CGRectMake(0, kRefH - kFooterH, kRefW, kFooterH)];

    [self.window addSubview:self.panel];
    [self selectTab:0];
}

- (void)buildHeader:(CGRect)r {
    self.headerView = [[UIView alloc] initWithFrame:r];
    self.headerView.backgroundColor = C_HEAD;
    self.headerView.clipsToBounds = YES;
    self.headerView.userInteractionEnabled = YES;

    UIView* line = [[UIView alloc] initWithFrame:CGRectMake(0, r.size.height - 1, r.size.width, 1)];
    line.backgroundColor = [C_RED colorWithAlphaComponent:0.35];
    [self.headerView addSubview:line];

    UIImageView* wm = [[UIImageView alloc] initWithFrame:self.headerView.bounds];
    wm.contentMode = UIViewContentModeScaleAspectFill;
    wm.clipsToBounds = YES;
    wm.userInteractionEnabled = NO;
    wm.hidden = YES;
    wm.tag = 801;
    [self.headerView addSubview:wm];

    UILabel* fallback = lbl(@"RAVEN", 22, C_TEXT, YES);
    fallback.frame = CGRectMake(20, 0, 200, r.size.height);
    fallback.tag = 800;
    [self.headerView addSubview:fallback];

    __weak UIImageView* weakWM = wm;
    __weak UILabel* weakFB = fallback;
    loadLogoURLAsync(kWordmarkURL, ^(UIImage* img) {
        if (!img) return;
        weakWM.image = cropNormalized(img, CGRectMake(0.0, 0.286, 1.0, 0.364));
        weakWM.hidden = NO;
        weakFB.hidden = YES;
    });

    UIButton* close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(r.size.width - 44, (r.size.height - 30)/2, 30, 30);
    [close setTitle:@"X" forState:UIControlStateNormal];
    [close setTitleColor:C_RED forState:UIControlStateNormal];
    close.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    [close addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:close];

    UIButton* min = [UIButton buttonWithType:UIButtonTypeSystem];
    min.frame = CGRectMake(r.size.width - 82, (r.size.height - 30)/2, 30, 30);
    [min setTitle:@"-" forState:UIControlStateNormal];
    [min setTitleColor:C_SEC forState:UIControlStateNormal];
    min.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [min addTarget:self action:@selector(togglePanel) forControlEvents:UIControlEventTouchUpInside];
    [self.headerView addSubview:min];

    UIPanGestureRecognizer* pg = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onHeaderDrag:)];
    pg.cancelsTouchesInView = NO;
    pg.maximumNumberOfTouches = 1;
    [self.headerView addGestureRecognizer:pg];

    [self.panelInner addSubview:self.headerView];
}

- (void)onHeaderDrag:(UIPanGestureRecognizer*)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        self.dragStartFrame = self.panel.frame;
        self.hasPanelPosition = YES;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:self.window];
        CGRect f = self.dragStartFrame;
        f.origin.x += t.x;
        f.origin.y += t.y;
        self.panel.frame = f;
        [self clampPanel];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        [self clampPanel];
    }
}

- (NSArray*)tabDefs {
    return @[
        @{@"title":@"AIMBOT",   @"key":@"aimbot"},
        @{@"title":@"ESP",      @"key":@"esp"},
        @{@"title":@"VISUALS",  @"key":@"visuals"},
        @{@"title":@"WEAPON",   @"key":@"weapon"},
        @{@"title":@"MISC",     @"key":@"misc"},
        @{@"title":@"PLAYERS",  @"key":@"players"},
        @{@"title":@"INFO",     @"key":@"info"},
        @{@"title":@"SETTINGS", @"key":@"settings"},
    ];
}

- (void)buildSidebar:(CGRect)r {
    self.sidebarView = [[UIView alloc] initWithFrame:r];
    self.sidebarView.backgroundColor = C_SIDE;
    self.sidebarView.clipsToBounds = YES;

    UIImageView* bg = [[UIImageView alloc] initWithFrame:self.sidebarView.bounds];
    bg.contentMode = UIViewContentModeScaleAspectFill;
    bg.clipsToBounds = YES;
    bg.userInteractionEnabled = NO;
    bg.tag = 900;
    [self.sidebarView addSubview:bg];

    __weak UIImageView* weakBG = bg;
    loadLogoURLAsync(kEmblemURL, ^(UIImage* img) {
        if (img) weakBG.image = img;
    });

    UIView* tint = [[UIView alloc] initWithFrame:self.sidebarView.bounds];
    tint.backgroundColor = [UIColor colorWithRed:0.02 green:0.02 blue:0.04 alpha:0.14];
    tint.userInteractionEnabled = NO;
    [self.sidebarView addSubview:tint];

    UIView* sep = [[UIView alloc] initWithFrame:CGRectMake(r.size.width - 1, 0, 1, r.size.height)];
    sep.backgroundColor = C_BORDER;
    [self.sidebarView addSubview:sep];

    NSArray* defs = [self tabDefs];
    CGFloat y = 14;
    for (NSInteger i = 0; i < defs.count; i++) {
        NSDictionary* d = defs[i];
        std::string k = std::string([d[@"key"] UTF8String]);
        if (!Updater::feature(k, true)) continue;

        UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
        btn.frame = CGRectMake(0, y, r.size.width - 1, kTabH);
        btn.tag = i;
        btn.backgroundColor = [UIColor clearColor];
        [btn addTarget:self action:@selector(onTabTap:) forControlEvents:UIControlEventTouchUpInside];

        UIView* accent = [[UIView alloc] initWithFrame:CGRectMake(0, 8, 2, kTabH - 16)];
        accent.backgroundColor = [UIColor clearColor];
        accent.layer.cornerRadius = 1;
        accent.tag = 990;
        [btn addSubview:accent];

        UILabel* label = lbl(d[@"title"], 13, C_SEC, NO);
        label.frame = CGRectMake(20, 0, btn.frame.size.width - 28, kTabH);
        label.tag = 991;
        [btn addSubview:label];

        [self.sidebarView addSubview:btn];
        [self.tabButtons addObject:btn];
        y += kTabH + 4;
    }

    [self.panelInner addSubview:self.sidebarView];
}

- (void)onTabTap:(UIButton*)b { [self selectTab:b.tag]; }

- (void)reloadActiveTab {
    [self.tabViews removeAllObjects];
    for (UIView* v in self.contentView.subviews) [v removeFromSuperview];
    NSArray* defs = [self tabDefs];
    if (self.activeTab < 0 || self.activeTab >= (NSInteger)defs.count) return;
    [self selectTab:self.activeTab];
}

- (void)selectTab:(NSInteger)idx {
    self.activeTab = idx;
    for (UIButton* b in self.tabButtons) {
        BOOL active = (b.tag == idx);
        UIView*  accent = [b viewWithTag:990];
        UILabel* label  = [b viewWithTag:991];
        accent.backgroundColor = active ? C_RED : [UIColor clearColor];
        label.textColor = active ? C_TEXT : C_SEC;
        label.font = active
            ? [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]
            : [UIFont systemFontOfSize:13 weight:UIFontWeightRegular];
        b.backgroundColor = active ? [C_CRIMSON colorWithAlphaComponent:0.55] : [UIColor clearColor];
    }
    for (UIView* v in self.contentView.subviews) [v removeFromSuperview];

    NSArray* defs = [self tabDefs];
    if (idx < 0 || idx >= (NSInteger)defs.count) return;
    NSString* key = defs[idx][@"title"];
    UIView* content = self.tabViews[key];
    if (!content) {
        content = [self buildTabContent:key];
        self.tabViews[key] = content;
    }
    content.frame = self.contentView.bounds;
    [self.contentView addSubview:content];

    if (RavenSettings::animations) {
        content.alpha = 0.0;
        content.transform = CGAffineTransformMakeTranslation(10.0, 0.0);
        [UIView animateWithDuration:0.18 animations:^{
            content.alpha = 1.0;
            content.transform = CGAffineTransformIdentity;
        }];
    } else {
        content.alpha = 1.0;
        content.transform = CGAffineTransformIdentity;
    }
}

- (void)buildContent:(CGRect)r {
    self.contentView = [[UIView alloc] initWithFrame:r];
    self.contentView.backgroundColor = [UIColor clearColor];
    self.contentView.clipsToBounds = YES;
    [self.panelInner addSubview:self.contentView];
}

- (UIView*)buildTabContent:(NSString*)tab {
    UIScrollView* sv = [[UIScrollView alloc] initWithFrame:self.contentView.bounds];
    sv.backgroundColor = [UIColor clearColor];
    sv.showsVerticalScrollIndicator = NO;
    sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    CGFloat W = sv.bounds.size.width;

    UILabel* title = lbl(tab, 18, C_TEXT, YES);
    title.frame = CGRectMake(kPad, 14, W - kPad*2, 22);
    [sv addSubview:title];

    UILabel* sub = lbl([self subtitleForTab:tab], 11, C_SEC, NO);
    sub.frame = CGRectMake(kPad, 38, W - kPad*2, 15);
    [sv addSubview:sub];

    CGFloat startY = 68;
    CGFloat availW = W - kPad*2;
    BOOL twoCols = (availW >= 500);
    CGFloat colW = twoCols ? (availW - kCardGap) / 2.0 : availW;

    NSArray* cards = [self cardsForTab:tab width:colW];
    CGFloat leftY = startY;
    CGFloat rightY = startY;

    for (NSInteger i = 0; i < (NSInteger)cards.count; i++) {
        UIView* c = cards[i];
        CGFloat h = c.frame.size.height;
        if (twoCols && (i % 2) == 0) {
            c.frame = CGRectMake(kPad, leftY, colW, h);
            leftY += h + kCardGap;
        } else if (twoCols) {
            c.frame = CGRectMake(kPad + colW + kCardGap, rightY, colW, h);
            rightY += h + kCardGap;
        } else {
            c.frame = CGRectMake(kPad, leftY, colW, h);
            leftY += h + kCardGap;
        }
        [sv addSubview:c];
    }
    CGFloat contentH = MAX(leftY, rightY) + kPad;
    sv.contentSize = CGSizeMake(W, contentH);
    return sv;
}

- (NSString*)subtitleForTab:(NSString*)tab {
    if ([tab isEqualToString:@"AIMBOT"])   return @"Configure targeting and aim behavior";
    if ([tab isEqualToString:@"ESP"])      return @"Player visibility and overlay options";
    if ([tab isEqualToString:@"VISUALS"])  return @"Screen and rendering adjustments";
    if ([tab isEqualToString:@"WEAPON"])   return @"Weapon behavior modifications";
    if ([tab isEqualToString:@"MISC"])     return @"Movement, utility and interface tweaks";
    if ([tab isEqualToString:@"PLAYERS"])  return @"Nearby player list";
    if ([tab isEqualToString:@"INFO"])     return @"Raven account, device and runtime information";
    if ([tab isEqualToString:@"SETTINGS"]) return @"Menu configuration and about";
    return @"";
}

- (UIView*)card:(NSString*)title width:(CGFloat)w rows:(NSArray*)rows {
    UIView* card = [UIView new];
    card.backgroundColor = C_CARD;
    card.layer.cornerRadius = kCardRad;
    card.layer.borderWidth = 1;
    card.layer.borderColor = C_BORDER.CGColor;

    UILabel* t = lbl(title, 11, C_RED, YES);
    t.frame = CGRectMake(14, 11, w - 28, 14);
    [card addSubview:t];

    UIView* line = [[UIView alloc] initWithFrame:CGRectMake(14, 28, w - 28, 1)];
    line.backgroundColor = [C_RED colorWithAlphaComponent:0.12];
    [card addSubview:line];

    CGFloat y = 36;
    for (UIView* r in rows) {
        CGFloat rh = r.frame.size.height;
        r.frame = CGRectMake(0, y, w, rh);
        for (UIView* sub in r.subviews) {
            if ([sub isKindOfClass:[RVToggle class]]) {
                sub.frame = CGRectMake(w - 52, (kRowH - 20) / 2.0, 38, 20);
            } else if ([sub isKindOfClass:[RVSlider class]]) {
                sub.frame = CGRectMake(14, 26, MAX(40, w - 28), 18);
            } else if ([sub isKindOfClass:[RVSelector class]]) {
                sub.frame = CGRectMake(MAX(14, w - 126), 2, 112, 24);
            } else if ([sub isKindOfClass:[UIButton class]]) {
                sub.frame = CGRectMake(12, 2, MAX(40, w - 24), 32);
            } else if (sub.tag == 610) {
                sub.frame = CGRectMake(w - 68, 4, 54, 18);
            } else if (sub.tag == 611) {
                sub.frame = CGRectMake(w - 160, 0, 146, kRowH);
            }
        }
        [card addSubview:r];
        y += rh;
    }
    y += 8;
    card.frame = CGRectMake(0, 0, w, y);
    return card;
}

- (UIView*)rowToggle:(NSString*)title on:(BOOL)on cb:(void(^)(BOOL))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 160, kRowH);
    [row addSubview:l];
    RVToggle* t = [[RVToggle alloc] init];
    t.on = on;
    t.onChange = ^(BOOL value) {
        if (cb) cb(value);
        RavenSettings::save();
    };
    t.frame = CGRectMake(row.frame.size.width - 52, (kRowH - 20) / 2.0, 38, 20);
    t.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:t];
    return row;
}

- (UIView*)rowSlider:(NSString*)title min:(float)mn max:(float)mx val:(float)v cb:(void(^)(float))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowHBig)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 4, 170, 18);
    [row addSubview:l];

    UILabel* val = lbl([NSString stringWithFormat:@"%.0f", v], 12, C_RED, YES);
    val.tag = 610;
    val.textAlignment = NSTextAlignmentRight;
    val.frame = CGRectMake(row.frame.size.width - 68, 4, 54, 18);
    val.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:val];

    RVSlider* s = [[RVSlider alloc] init];
    s.minValue = mn; s.maxValue = mx; s.value = v;
    s.frame = CGRectMake(14, 26, row.frame.size.width - 28, 18);
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    s.onChange = ^(float nv) {
        val.text = [NSString stringWithFormat:@"%.0f", nv];
        if (cb) cb(nv);
        RavenSettings::save();
    };
    [row addSubview:s];
    return row;
}

- (UIView*)rowDropdown:(NSString*)title value:(NSString*)val {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 140, kRowH);
    [row addSubview:l];
    UIView* pill = [[UIView alloc] initWithFrame:CGRectMake(row.frame.size.width - 112, 2, 98, 24)];
    pill.backgroundColor = [UIColor colorWithRed:0.092 green:0.092 blue:0.105 alpha:1.0];
    pill.layer.cornerRadius = 6;
    pill.layer.borderWidth = 1;
    pill.layer.borderColor = C_BORDER.CGColor;
    pill.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:pill];
    UILabel* v = lbl(val, 11, C_TEXT, NO);
    v.frame = CGRectMake(10, 0, 70, 24);
    [pill addSubview:v];
    UIImageView* chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.down"]];
    chevron.tintColor = C_MUTE;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    chevron.frame = CGRectMake(82, 7, 9, 9);
    [pill addSubview:chevron];
    return row;
}

- (UIView*)rowSelector:(NSString*)title
                 items:(NSArray<NSString*>*)items
              selected:(NSInteger)selected
                    cb:(void(^)(NSInteger))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 140, kRowH);
    [row addSubview:l];
    RVSelector* s = [[RVSelector alloc] initWithItems:items selected:selected];
    s.frame = CGRectMake(row.frame.size.width - 126, 2, 112, 24);
    s.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    s.onChange = ^(NSInteger value) {
        if (cb) cb(value);
        RavenSettings::save();
    };
    [row addSubview:s];
    return row;
}

- (UIView*)rowInfo:(NSString*)title value:(NSString*)val {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, kRowH)];
    UILabel* l = lbl(title, 13, C_TEXT, NO);
    l.frame = CGRectMake(14, 0, 140, kRowH);
    [row addSubview:l];
    UILabel* v = lbl(val, 12, C_RED, YES);
    v.tag = 611;
    v.textAlignment = NSTextAlignmentRight;
    v.frame = CGRectMake(row.frame.size.width - 160, 0, 146, kRowH);
    v.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [row addSubview:v];
    return row;
}

- (UIView*)rowButton:(NSString*)title tap:(void(^)(void))cb {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 36)];
    UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = CGRectMake(12, 2, row.frame.size.width - 24, 32);
    b.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:C_TEXT forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    b.backgroundColor = [UIColor colorWithWhite:0.11 alpha:1.0];
    b.layer.cornerRadius = 6;
    b.layer.borderWidth = 1;
    b.layer.borderColor = C_BORDER.CGColor;
    b.tag = (NSInteger)CFBridgingRetain([cb copy]);
    [b addTarget:self action:@selector(onGenericButton:) forControlEvents:UIControlEventTouchUpInside];
    [row addSubview:b];
    return row;
}

- (void)onGenericButton:(UIButton*)b {
    void (^cb)(void) = (__bridge void (^)(void))(void*)b.tag;
    if (cb) cb();
    if (RavenSettings::animations) {
        b.transform = CGAffineTransformMakeScale(0.98, 0.98);
        [UIView animateWithDuration:0.14 animations:^{ b.transform = CGAffineTransformIdentity; }];
    }
}

- (void)showToast:(NSString*)title detail:(NSString*)detail {
    [self.toastTimer invalidate];
    [self.toastView removeFromSuperview];

    UIView* toast = [[UIView alloc] initWithFrame:CGRectMake(kRefW - 286, kHeaderH + 12, 266, 48)];
    toast.backgroundColor = [UIColor colorWithRed:0.055 green:0.055 blue:0.066 alpha:0.97];
    toast.layer.cornerRadius = 8;
    toast.layer.borderWidth = 1;
    toast.layer.borderColor = [C_RED colorWithAlphaComponent:0.42].CGColor;
    toast.layer.shadowColor = [UIColor blackColor].CGColor;
    toast.layer.shadowOpacity = 0.45;
    toast.layer.shadowRadius = 10;
    toast.layer.shadowOffset = CGSizeMake(0, 4);

    UIView* bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 3, 48)];
    bar.backgroundColor = C_RED;
    bar.layer.cornerRadius = 1.5;
    [toast addSubview:bar];

    UILabel* t = lbl(title ?: @"RAVEN", 12, C_TEXT, YES);
    t.frame = CGRectMake(14, 7, 238, 16);
    [toast addSubview:t];

    UILabel* d = lbl(detail ?: @"", 10, C_SEC, NO);
    d.frame = CGRectMake(14, 25, 238, 14);
    [toast addSubview:d];

    self.toastView = toast;
    [self.panelInner addSubview:toast];
    [self.panelInner bringSubviewToFront:toast];

    if (RavenSettings::animations) {
        toast.alpha = 0.0;
        toast.transform = CGAffineTransformMakeTranslation(14, -4);
        [UIView animateWithDuration:0.22 animations:^{
            toast.alpha = 1.0;
            toast.transform = CGAffineTransformIdentity;
        }];
    }

    __weak RavenMenu* weakSelf = self;
    self.toastTimer = [NSTimer scheduledTimerWithTimeInterval:2.2 repeats:NO block:^(NSTimer* timer) {
        RavenMenu* selfRef = weakSelf;
        if (!selfRef || selfRef.toastView != toast) return;
        void (^removeToast)(void) = ^{
            [toast removeFromSuperview];
            if (selfRef.toastView == toast) selfRef.toastView = nil;
        };
        if (RavenSettings::animations) {
            [UIView animateWithDuration:0.18 animations:^{
                toast.alpha = 0.0;
                toast.transform = CGAffineTransformMakeTranslation(10, -4);
            } completion:^(BOOL finished) { removeToast(); }];
        } else {
            removeToast();
        }
    }];
}

- (NSArray*)cardsForTab:(NSString*)tab width:(CGFloat)w {
    if ([tab isEqualToString:@"AIMBOT"]) {
        UIView* general = [self card:@"GENERAL" width:w rows:@[
            [self rowToggle:@"Enable Aimbot" on:RavenSettings::aimEnabled cb:^(BOOL v){
                RavenAimbot::setEnabled(v);
                RAVEN_LOG("aim-toggle: enabled=%d esp=%d",
                          RavenSettings::aimEnabled, RavenSettings::espEnabled);
                RavenSettings::save();
            }],
            [self rowSelector:@"Aim Activation"
                         items:@[@"Hold", @"Toggle", @"Always"]
                      selected:RavenSettings::aimActivation
                            cb:^(NSInteger v){ RavenSettings::aimActivation = (int)v; RavenSettings::save(); }],
            [self rowSlider:@"Aim FOV" min:0 max:360 val:RavenSettings::aimFov cb:^(float v){ RavenSettings::aimFov = v; }],
            [self rowSlider:@"Smoothness" min:1 max:30 val:RavenSettings::aimSmooth cb:^(float v){ RavenSettings::aimSmooth = v; }],
            [self rowSelector:@"Smoothing Curve"
                         items:@[@"Linear", @"Exponential", @"Ease Out", @"Instant"]
                      selected:RavenSettings::aimCurve
                            cb:^(NSInteger v){ RavenSettings::aimCurve = (int)v; RavenSettings::save(); }],
        ]];
        UIView* advanced = [self card:@"ADVANCED" width:w rows:@[
            [self rowToggle:@"Prediction" on:RavenSettings::aimPrediction cb:^(BOOL v){ RavenSettings::aimPrediction = v; }],
            [self rowSlider:@"Aim Delay" min:0 max:300 val:RavenSettings::aimDelay cb:^(float v){ RavenSettings::aimDelay = v; }],
            [self rowSlider:@"Target Switch Delay" min:0 max:500 val:RavenSettings::aimSwitchDelay cb:^(float v){ RavenSettings::aimSwitchDelay = v; }],
        ]];
        UIView* targeting = [self card:@"TARGETING" width:w rows:@[
            [self rowSelector:@"Target Bone"
                         items:@[@"Head", @"Neck", @"Chest", @"Pelvis"]
                      selected:RavenSettings::aimBone
                            cb:^(NSInteger v){ RavenSettings::aimBone = (int)v; RavenSettings::save(); }],
            [self rowSelector:@"Target Priority"
                         items:@[@"Crosshair", @"Distance", @"Auto", @"Close to Me"]
                      selected:RavenSettings::aimPriority
                            cb:^(NSInteger v){ RavenSettings::aimPriority = (int)v; RavenSettings::save(); }],
            [self rowToggle:@"Visible Check" on:RavenSettings::aimVisCheck cb:^(BOOL v){ RavenSettings::aimVisCheck = v; }],
            [self rowSlider:@"Max Distance" min:50 max:500 val:RavenSettings::aimMaxDist cb:^(float v){ RavenSettings::aimMaxDist = v; }],
        ]];
        UIView* fovCard = [self card:@"FOV" width:w rows:@[
            [self rowToggle:@"Show FOV Circle" on:RavenSettings::aimShowCircle cb:^(BOOL v){ RavenSettings::aimShowCircle = v; }],
            [self rowSlider:@"FOV Radius" min:20 max:400 val:RavenSettings::aimCircleRadius cb:^(float v){ RavenSettings::aimCircleRadius = v; }],
            [self rowSlider:@"Circle Thickness" min:1 max:6 val:RavenSettings::aimCircleThickness cb:^(float v){ RavenSettings::aimCircleThickness = v; }],
        ]];
        return @[general, targeting, advanced, fovCard];
    }

    if ([tab isEqualToString:@"ESP"]) {
        UIView* player = [self card:@"PLAYER ESP" width:w rows:@[
            [self rowToggle:@"Enable ESP" on:RavenSettings::espEnabled cb:^(BOOL v){ RavenSettings::espEnabled = v; RavenSettings::save(); }],
            [self rowToggle:@"Box" on:RavenSettings::espBox cb:^(BOOL v){ RavenSettings::espBox = v; }],
            [self rowToggle:@"Corner Box" on:RavenSettings::espCorner cb:^(BOOL v){ RavenSettings::espCorner = v; }],
            [self rowSelector:@"Box Style"
                         items:@[@"Raven Pro", @"Raven Hex", @"Raven Round", @"Raven Gradient", @"Raven Elite"]
                      selected:RavenSettings::espBoxStyle
                            cb:^(NSInteger v){ RavenSettings::espBoxStyle = (int)v; RavenSettings::save(); }],
            [self rowToggle:@"Skeleton" on:RavenSettings::espSkeleton cb:^(BOOL v){ RavenSettings::espSkeleton = v; }],
            [self rowToggle:@"Snaplines" on:RavenSettings::espSnaplines cb:^(BOOL v){ RavenSettings::espSnaplines = v; }],
        ]];
        UIView* info = [self card:@"INFORMATION" width:w rows:@[
            [self rowToggle:@"Name" on:RavenSettings::espName cb:^(BOOL v){ RavenSettings::espName = v; }],
            [self rowToggle:@"Distance" on:RavenSettings::espDistance cb:^(BOOL v){ RavenSettings::espDistance = v; }],
            [self rowToggle:@"Health" on:RavenSettings::espHealth cb:^(BOOL v){ RavenSettings::espHealth = v; }],
        ]];
        UIView* colors = [self card:@"COLORS" width:w rows:@[
            [self rowSelector:@"Enemy Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espEnemyColor
                            cb:^(NSInteger v){ RavenSettings::espEnemyColor = (int)v; RavenSettings::save(); }],
            [self rowSelector:@"Visible Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espVisibleColor
                            cb:^(NSInteger v){ RavenSettings::espVisibleColor = (int)v; RavenSettings::save(); }],
            [self rowSelector:@"Skeleton Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espSkeletonColor
                            cb:^(NSInteger v){ RavenSettings::espSkeletonColor = (int)v; RavenSettings::save(); }],
            [self rowSelector:@"Box Color"
                         items:@[@"Red", @"Green", @"White", @"Yellow", @"Cyan"]
                      selected:RavenSettings::espBoxColor
                            cb:^(NSInteger v){ RavenSettings::espBoxColor = (int)v; RavenSettings::save(); }],
        ]];
        return @[player, info, colors];
    }

    if ([tab isEqualToString:@"VISUALS"]) {
        UIView* cross = [self card:@"CROSSHAIR" width:w rows:@[
            [self rowToggle:@"Enable Crosshair" on:RavenSettings::visCrosshair cb:^(BOOL v){ RavenSettings::visCrosshair = v; }],
            [self rowSelector:@"Style"
                         items:@[@"Dot", @"Cross", @"Circle", @"T-Shape"]
                      selected:RavenSettings::visCrosshairStyle
                            cb:^(NSInteger v){ RavenSettings::visCrosshairStyle = (int)v; RavenSettings::save(); }],
            [self rowSlider:@"Size" min:1 max:30 val:RavenSettings::visCrosshairSize cb:^(float v){ RavenSettings::visCrosshairSize = v; }],
            [self rowSlider:@"Thickness" min:1 max:6 val:RavenSettings::visCrosshairThickness cb:^(float v){ RavenSettings::visCrosshairThickness = v; }],
        ]];
        return @[cross];
    }

    if ([tab isEqualToString:@"WEAPON"]) return @[];

    if ([tab isEqualToString:@"MISC"]) {
        UIView* utility = [self card:@"UTILITY" width:w rows:[NSArray arrayWithObject:
            [self rowToggle:@"Panic Key" on:RavenSettings::miscPanicKey cb:^(BOOL v){ RavenSettings::miscPanicKey = v; }]
        ]];
        UIView* iface = [self card:@"INTERFACE" width:w rows:@[
            [self rowToggle:@"Hide Menu When Closed" on:RavenSettings::miscHideWhenClosed cb:^(BOOL v){ RavenSettings::miscHideWhenClosed = v; }],
            [self rowSlider:@"Menu Opacity" min:20 max:100 val:RavenSettings::miscMenuOpacity cb:^(float v){ RavenSettings::miscMenuOpacity = v; }],
        ]];
        return @[utility, iface];
    }

    if ([tab isEqualToString:@"PLAYERS"]) {
        NSArray<NSString*>* playerRows = [[RavenESP shared] snapshotPlayerRows];
        NSMutableArray* rows = [NSMutableArray array];
        if (playerRows.count == 0) {
            UILabel* empty = lbl(@"No live enemy players detected", 12, C_SEC, NO);
            empty.textAlignment = NSTextAlignmentCenter;
            empty.frame = CGRectMake(0, 0, w - 28, 34);
            UIView* emptyRow = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 34)];
            [emptyRow addSubview:empty];
            [rows addObject:emptyRow];
        } else {
            for (NSInteger i = 0; i < (NSInteger)playerRows.count; i++)
                [rows addObject:[self rowInfo:[NSString stringWithFormat:@"PLAYER %ld", (long)i + 1]
                                      value:playerRows[i]]];
        }
        UIView* list = [self card:@"PLAYER LIST" width:w rows:rows];
        return @[list];
    }

    if ([tab isEqualToString:@"INFO"]) {
        UIDevice* device = [UIDevice currentDevice];
        NSString* key = [[NSUserDefaults standardUserDefaults] stringForKey:@"raven.license.maskedKey"];
        if (!key.length) key = @"Not linked";
        UIView* account = [self card:@"ACCOUNT & KEY" width:w rows:@[
            [self rowInfo:@"Account" value:@"Raven user"],
            [self rowInfo:@"License" value:key],
            [self rowInfo:@"HWID" value:@"Server-bound"],
        ]];
        UIView* deviceCard = [self card:@"DEVICE" width:w rows:@[
            [self rowInfo:@"Model" value:device.model ?: @"Unknown"],
            [self rowInfo:@"System" value:device.systemVersion ?: @"Unknown"],
            [self rowInfo:@"Screen" value:[NSString stringWithFormat:@"%.0f × %.0f", UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height]],
        ]];
        UIView* runtime = [self card:@"RUNTIME" width:w rows:@[
            [self rowInfo:@"IL2CPP" value:@"Runtime hook layer"],
            [self rowInfo:@"IsRealPlayer" value:@"Diagnostic only / unverified"],
            [self rowInfo:@"Build" value:@"Raven Pro 1.0"],
        ]];
        return @[account, deviceCard, runtime];
    }

    if ([tab isEqualToString:@"SETTINGS"]) {
        std::string rv = Updater::remoteVersion();
        NSString* rvStr = [NSString stringWithUTF8String:rv.c_str()];

        UIView* iface = [self card:@"INTERFACE" width:w rows:@[
            [self rowSlider:@"Menu Scale" min:50 max:150 val:RavenSettings::menuScale cb:^(float v){
                RavenSettings::menuScale = v;
                [self relayout];
                [self clampPanel];
            }],
            [self rowSelector:@"Accent Color"
                         items:@[@"Crimson", @"Red", @"Blue", @"Green", @"Purple"]
                      selected:RavenSettings::uiAccentColor
                            cb:^(NSInteger v){ RavenSettings::uiAccentColor = (int)v; RavenSettings::save(); }],
            [self rowToggle:@"Animations" on:RavenSettings::animations cb:^(BOOL v){
                RavenSettings::animations = v;
                RavenSettings::save();
                [self showToast:@"Animations" detail:(v ? @"Smooth UI motion enabled" : @"UI motion disabled")];
            }],
        ]];
        UIView* config = [self card:@"CONFIG" width:w rows:@[
            [self rowButton:@"Save Config" tap:^{
                RavenSettings::save();
                [self showToast:@"Config Saved" detail:@"RAVEN settings stored"];
            }],
            [self rowButton:@"Load Config" tap:^{
                RavenSettings::load();
                [self reloadActiveTab];
                [self relayout];
                [self showToast:@"Config Loaded" detail:@"Saved settings restored"];
            }],
            [self rowButton:@"Reset to Defaults" tap:^{
                RavenSettings::resetToDefaults();
                [self reloadActiveTab];
                [self relayout];
                [self showToast:@"Reset Complete" detail:@"All settings restored"];
            }],
        ]];
        UIView* menu = [self card:@"MENU" width:w rows:@[
            [self rowSelector:@"Open/Close Button"
                         items:@[@"Floating", @"Corner", @"Hidden"]
                      selected:RavenSettings::uiOpenButton
                            cb:^(NSInteger v){
                                RavenSettings::uiOpenButton = (int)v;
                                self.ball.hidden = (v == 2);
                                [self relayout];
                            }],
            [self rowSelector:@"Position"
                         items:@[@"Right", @"Left", @"Center"]
                      selected:RavenSettings::uiPosition
                            cb:^(NSInteger v){
                                RavenSettings::uiPosition = (int)v;
                                [self relayout];
                            }],
            [self rowSlider:@"Opacity" min:20 max:100 val:RavenSettings::miscMenuOpacity cb:^(float v){ RavenSettings::miscMenuOpacity = v; }],
        ]];
        UIView* about = [self card:@"ABOUT" width:w rows:@[
            [self rowInfo:@"Version" value:rvStr],
            [self rowInfo:@"Brand" value:@"@KremCheats"],
            [self rowInfo:@"Developer" value:@"@Kremityss"],
            [self rowInfo:@"Status" value:[NSString stringWithUTF8String:Updater::status()]],
        ]];
        return @[iface, config, menu, about];
    }

    return @[];
}

- (void)buildFooter:(CGRect)r {
    self.footerView = [[UIView alloc] initWithFrame:r];
    self.footerView.backgroundColor = C_HEAD;

    UIView* top = [[UIView alloc] initWithFrame:CGRectMake(0, 0, r.size.width, 1)];
    top.backgroundColor = C_BORDER;
    [self.footerView addSubview:top];

    UIView* dot = [[UIView alloc] initWithFrame:CGRectMake(14, (r.size.height - 7)/2, 7, 7)];
    dot.backgroundColor = [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1.0];
    dot.layer.cornerRadius = 3.5;
    [self.footerView addSubview:dot];

    UILabel* l = lbl(@"Connected", 10, C_SEC, NO);
    l.frame = CGRectMake(26, 0, 140, r.size.height);
    [self.footerView addSubview:l];

    UILabel* r2 = lbl(@"RAVEN  •  KREMCHEATS  •  v1.0", 10, C_RED, YES);
    r2.textAlignment = NSTextAlignmentRight;
    r2.frame = CGRectMake(r.size.width - 230, 0, 216, r.size.height);
    [self.footerView addSubview:r2];

    [self.panelInner addSubview:self.footerView];
}

- (void)onTick {
    if (!self.window) return;
    CGSize b = self.window.bounds.size;
    if (!CGSizeEqualToSize(b, self.lastBounds)) {
        self.lastBounds = b;
        [self relayout];
        [self clampPanel];
    }
    if (!self.runtimeActive) return;
    static double playerRefreshAt = 0.0;
    double tickNow = CACurrentMediaTime();
    if (self.panelOpen && self.activeTab == 5 && tickNow - playerRefreshAt >= 0.50) {
        playerRefreshAt = tickNow;
        [self reloadActiveTab];
    }
    // Apply camera assistance before doing any overlay work. ESP performs
    // multiple IL2CPP calls and rebuilds several Core Animation paths; it
    // must never delay the input correction or make aim appear inactive.
    if (RavenSettings::aimEnabled) RavenAimbot::tick();
    // Keep aim at the menu tick rate, but cap ESP geometry work to 15 Hz.
    // Re-render immediately when a guide/ESP state changes so switches still
    // take effect without making the overlay compete with camera input.
    BOOL overlayEnabled = RavenSettings::espEnabled || RavenSettings::aimShowCircle ||
                          RavenSettings::visFovCircle || RavenSettings::visCrosshair;
    static double espRenderAt = 0.0;
    static BOOL lastOverlayEnabled = NO;
    double espNow = CACurrentMediaTime();
    BOOL stateChanged = (overlayEnabled != lastOverlayEnabled);
    if (stateChanged || (espNow - espRenderAt) >= (1.0 / 15.0)) {
        espRenderAt = espNow;
        lastOverlayEnabled = overlayEnabled;
        [[RavenESP shared] render];
    }
}

@end
""")

# ---------------------------------------------------------------------------
# OVERRIDE PASS
#
# write_tree.py above emits a placeholder Src/Aimbot.mm so the Theos
# build has a file to compile even in a bare-repo scenario. The real
# aimbot is maintained at repo root as Aimbot_fixed.mm and is the single
# source of truth. This block runs after every other file has been
# written and copies Aimbot_fixed.mm over Src/Aimbot.mm, so the tree that
# ends up in git (and the tree the Theos build compiles) always carries
# the fixed aimbot regardless of which workflow step ran last.
# ---------------------------------------------------------------------------
_aimbot_candidates = (
    os.path.join(SCRIPT_DIR, "aimbot_fixed.mm"),
    os.path.join(SCRIPT_DIR, "Aimbot_fixed.mm"),
)
_aimbot_source = next((p for p in _aimbot_candidates if os.path.isfile(p)), None)
if _aimbot_source:
    with open(_aimbot_source, "r") as _af:
        _aimbot_override = _af.read()
    with open("Src/Aimbot.mm", "w") as _af:
        _af.write(_aimbot_override)
    print("[write_tree] overrode Src/Aimbot.mm from Aimbot_fixed.mm")
else:
    print("[write_tree] WARNING: aimbot_fixed.mm missing beside write_tree.py — using generated Aimbot.mm")

_esp_candidates = (
    os.path.join(SCRIPT_DIR, "ESP_fixed.mm"),
    os.path.join(SCRIPT_DIR, "esp_fixed.mm"),
)
_esp_source = next((p for p in _esp_candidates if os.path.isfile(p)), None)
if _esp_source:
    with open(_esp_source, "r") as _ef:
        _esp_override = _ef.read()
    with open("Src/ESP.mm", "w") as _ef:
        _ef.write(_esp_override)
    print("[write_tree] overrode Src/ESP.mm from ESP_fixed.mm")
else:
    print("[write_tree] WARNING: ESP_fixed.mm missing beside write_tree.py — using generated ESP.mm")
# Keep settings and menu source-of-truth files in the generated tree.
for _name in ("Settings.h", "Settings.mm", "Menu.mm", "LicenseClient.h", "LicenseClient.mm"):
    _src = os.path.join(SCRIPT_DIR, _name.replace(".", "_fixed.", 1))
    if os.path.isfile(_src):
        with open(_src, "r") as _sf, open(os.path.join("Src", _name), "w") as _df:
            _df.write(_sf.read())
        print("[write_tree] overrode Src/%s from %s" % (_name, os.path.basename(_src)))
_raven_source = os.path.join(SCRIPT_DIR, "Raven_fixed.mm")
if os.path.isfile(_raven_source):
    with open(_raven_source, "r") as _rf, open(os.path.join(SCRIPT_DIR, "Raven.mm"), "w") as _df:
        _df.write(_rf.read())
    print("[write_tree] overrode Raven.mm from Raven_fixed.mm")

print("done — full tree, 2026-09-24 phantom-target + camera-fallback pass + 2026-09-25 override")
print()
print("Files written (17):")
print("  Makefile")
print("  Raven.mm")
print("  Src/Common.h")
print("  Src/GameData.h    [CHANGED]")
print("  Src/Logos.h")
print("  Src/Settings.h")
print("  Src/Settings.mm")
print("  Src/Updater.h")
print("  Src/Updater.mm")
print("  Src/IL2CPP.h")
print("  Src/IL2CPP.mm")
print("  Src/ESP.h")
print("  Src/ESP.mm        [CHANGED]")
print("  Src/Aimbot.h")
print("  Src/Aimbot.mm     [OVERRIDDEN FROM Aimbot_fixed.mm]")
print("  Src/Menu.h")
print("  Src/Menu.mm")
print()
print("Write path: still disabled in the placeholder. kWriteEnabled lives in Aimbot_fixed.mm.")
