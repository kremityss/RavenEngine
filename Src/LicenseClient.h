#ifndef RAVEN_LICENSE_CLIENT_H
#define RAVEN_LICENSE_CLIENT_H

#import <Foundation/Foundation.h>

namespace RavenLicense {
    typedef void (^ValidationCallback)(BOOL valid, NSString* reason);
    NSString* deviceFingerprint(void);
    void validateAsync(NSString* key, NSString* hwid, ValidationCallback callback);
    void validateStoredAsync(ValidationCallback callback);
    NSTimeInterval expiryTimestamp(void);
}

#endif
