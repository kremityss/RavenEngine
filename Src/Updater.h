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
