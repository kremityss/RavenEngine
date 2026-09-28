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
