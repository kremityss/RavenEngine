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
