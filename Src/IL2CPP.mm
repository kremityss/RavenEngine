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
