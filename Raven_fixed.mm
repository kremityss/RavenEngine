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

static BOOL g_ravenGateVisible = NO;
static BOOL g_ravenRuntimeStarted = NO;
static const NSInteger kMaxLicenseFailures = 3;
static NSString* const kRavenGetKeyURL = @"https://discord.gg/QMS8cvs446";

static UIViewController* ravenGatePresenter(void) {
    UIViewController* presenter = ravenTopController();
    if (!presenter || !presenter.viewIfLoaded.window) return nil;
    return presenter;
}

static void ravenStartRuntime(void) {
    if (g_ravenRuntimeStarted) return;
    g_ravenRuntimeStarted = YES;
    [[NSUserDefaults standardUserDefaults] setInteger:0 forKey:@"raven.license.failures"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    Updater::fetchAsync(kConfigURL);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        IL2CPP::init();
        [[RavenMenu shared] start];
    });
}

static BOOL ravenTransientLicenseReason(NSString* reason) {
    return [reason isEqualToString:@"network_error"] ||
           [reason isEqualToString:@"invalid_endpoint"] ||
           [reason isEqualToString:@"request_encoding_failed"];
}

static void ravenShowKeyGate(NSString* message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_ravenRuntimeStarted || g_ravenGateVisible) return;
        UIViewController* presenter = ravenGatePresenter();
        if (!presenter) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ravenShowKeyGate(message); });
            return;
        }
        g_ravenGateVisible = YES;
        UIAlertController* gate = [UIAlertController alertControllerWithTitle:@"RAVEN ACCESS REQUIRED"
                                                                        message:message ?: @"Paste a valid device-bound key to continue."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [gate addAction:[UIAlertAction actionWithTitle:@"Paste & Validate" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            (void)action;
            g_ravenGateVisible = NO;
            NSString* key = [[UIPasteboard generalPasteboard].string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;
            if (!key.length) {
                ravenShowKeyGate(@"The clipboard is empty. Copy your key, then tap Paste & Validate.");
                return;
            }
            NSString* hwid = RavenLicense::deviceFingerprint();
            NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
            [defaults setObject:key forKey:@"raven.license.key"];
            [defaults setObject:hwid forKey:@"raven.license.hwid"];
            [defaults synchronize];
            RavenLicense::validateAsync(key, hwid, ^(BOOL valid, NSString* reason) {
                if (valid) {
                    RAVEN_LOG("license: validated from paste gate");
                    ravenStartRuntime();
                    return;
                }
                if (!ravenTransientLicenseReason(reason)) {
                    NSInteger failures = [defaults integerForKey:@"raven.license.failures"] + 1;
                    [defaults setInteger:failures forKey:@"raven.license.failures"];
                    [defaults removeObjectForKey:@"raven.license.key"];
                    [defaults synchronize];
                    RAVEN_LOG("license: invalid attempt=%ld reason=%@", (long)failures, reason ?: @"unknown");
                    if (failures >= kMaxLicenseFailures) {
                        RAVEN_LOG("license: three invalid attempts; terminating");
                        exit(0);
                    }
                }
                NSString* detail = ravenTransientLicenseReason(reason)
                    ? @"Validation is temporarily unavailable. Check your connection and try again."
                    : [NSString stringWithFormat:@"Key rejected (%@). Attempts remaining: %ld.", reason ?: @"invalid", (long)(kMaxLicenseFailures - [defaults integerForKey:@"raven.license.failures"])] ;
                ravenShowKeyGate(detail);
            });
        }]];
        NSURL* discordURL = [NSURL URLWithString:kRavenGetKeyURL];
        [gate addAction:[UIAlertAction actionWithTitle:@"Get Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction* sender) {
            (void)sender;
            g_ravenGateVisible = NO;
            if (discordURL) [[UIApplication sharedApplication] openURL:discordURL options:@{} completionHandler:nil];
            ravenShowKeyGate(@"Get a key from Discord, copy it, then return and tap Paste & Validate.");
        }]];
        [presenter presentViewController:gate animated:NO completion:nil];
    });
}

__attribute__((constructor))
static void raven_entry(void) {
    @autoreleasepool {
        RAVEN_LOG("entry");
        RavenSettings::load();
        RAVEN_LOG("settings: aimEnabled=%d espEnabled=%d", RavenSettings::aimEnabled, RavenSettings::espEnabled);
        RavenLicense::validateStoredAsync(^(BOOL valid, NSString* reason) {
            if (valid) {
                RAVEN_LOG("license: validated for device");
                ravenStartRuntime();
            } else {
                RavenSettings::aimEnabled = false;
                RavenSettings::espEnabled = false;
                RAVEN_LOG("license: access locked reason=%@", reason ?: @"unknown");
                ravenShowKeyGate([reason isEqualToString:@"credentials_missing"]
                                 ? @"Paste a valid device-bound key to unlock Raven."
                                 : @"Your saved key is invalid, expired, or bound to another device.");
            }
        });
    }
}
