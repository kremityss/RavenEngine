#import "LicenseClient.h"
#import "Common.h"
#import "Settings.h"
#import <UIKit/UIKit.h>
#import <CommonCrypto/CommonDigest.h>

#include <dispatch/dispatch.h>
#include <cstring>

namespace RavenLicense {

static NSTimeInterval parseExpiry(id value) {
    if ([value respondsToSelector:@selector(doubleValue)]) {
        NSTimeInterval t = [value doubleValue];
        if (t > 1000000000.0) return t;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSDateFormatter* formatter = [NSDateFormatter new];
        formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssXXXXX";
        NSDate* date = [formatter dateFromString:value];
        if (!date) {
            formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX";
            date = [formatter dateFromString:value];
        }
        if (date) return date.timeIntervalSince1970;
    }
    return 0.0;
}

NSTimeInterval expiryTimestamp(void) {
    return [[NSUserDefaults standardUserDefaults] doubleForKey:@"raven.license.expiresAt"];
}

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
        if (valid && json) {
            id expiryValue = json[@"expiresAt"] ?: json[@"expires_at"] ?: json[@"expiry"];
            NSTimeInterval expiry = parseExpiry(expiryValue);
            if (expiry <= 0.0) {
                id durationValue = json[@"durationSeconds"] ?: json[@"duration_seconds"] ?: json[@"duration"];
                NSTimeInterval duration = [durationValue respondsToSelector:@selector(doubleValue)] ? [durationValue doubleValue] : 0.0;
                if (duration > 0.0) expiry = NSDate.date.timeIntervalSince1970 + duration;
            }
            if (expiry > 0.0) [[NSUserDefaults standardUserDefaults] setDouble:expiry forKey:@"raven.license.expiresAt"];
            NSString* masked = key.length > 8 ? [NSString stringWithFormat:@"%@…%@", [key substringToIndex:4], [key substringFromIndex:key.length - 4]] : @"••••";
            [[NSUserDefaults standardUserDefaults] setObject:masked forKey:@"raven.license.maskedKey"];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ callback(valid, reason); });
    }] resume];
}

void validateStoredAsync(ValidationCallback callback) {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    NSString* key = [defaults stringForKey:@"raven.license.key"];
    NSString* savedHwid = [defaults stringForKey:@"raven.license.hwid"];
    NSString* currentHwid = deviceFingerprint();
    if (!key.length) { if (callback) callback(NO, @"credentials_missing"); return; }
    if (savedHwid.length && ![savedHwid.lowercaseString isEqualToString:currentHwid.lowercaseString]) {
        if (callback) callback(NO, @"device_mismatch");
        return;
    }
    [defaults setObject:currentHwid forKey:@"raven.license.hwid"];
    [defaults synchronize];
    // A previously validated key remains usable offline until its server-issued
    // expiry, but the device binding is still checked above.
    NSTimeInterval cachedExpiry = [defaults doubleForKey:@"raven.license.expiresAt"];
    if (cachedExpiry > NSDate.date.timeIntervalSince1970) {
        if (callback) callback(YES, @"cached");
        return;
    }
    validateAsync(key, currentHwid, callback);
}

}
