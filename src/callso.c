#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dlfcn.h>
#include <stdint.h>
#include <ctype.h>
#include <ffi.h>
#include <time.h>

// Bash headers
#include "config.h"
#include "builtins.h"
#include "shell.h"
#include "bashgetopt.h"
#include "common.h"

#define MAX_ARGS 16

typedef enum {
    TYPE_VOID,
    TYPE_INT,   // i32, u32, i64, u64, int
    TYPE_PTR,   // ptr, str
    TYPE_FLOAT, // f32
    TYPE_DOUBLE,// f64
    TYPE_STRUCT,// {t1,t2...}
    TYPE_UNKNOWN
} ArgType;

typedef struct {
    ArgType type;
    ffi_type *ffi_type_ptr;
} TypeInfo;

// Simple persistent cache for dlopen handles and symbols to avoid repeated dlopen/dlsym
#define CACHE_MAX 128
static char *cached_lib_paths[CACHE_MAX];
static void *cached_lib_handles[CACHE_MAX];
static int cached_lib_count = 0;

static char *cached_symbol_lib[CACHE_MAX];
static char *cached_symbol_name[CACHE_MAX];
static void *cached_symbol_ptr[CACHE_MAX];
static int cached_symbol_count = 0;

// Cache prepared ffi_cif for signatures
static char *cached_sig_str[CACHE_MAX];
static ffi_cif cached_cif[CACHE_MAX];
static ffi_type **cached_arg_types[CACHE_MAX];
static ffi_type *cached_ret_type[CACHE_MAX];
static int cached_arg_count[CACHE_MAX];
static ArgType cached_arg_argtypes[CACHE_MAX][MAX_ARGS];
static ArgType cached_ret_argtype[CACHE_MAX];
static int cached_sig_count = 0;

// Memory tracking for struct types
void *allocations[256];
int alloc_count = 0;

void *track_malloc(size_t size) {
    void *p = malloc(size);
    if (alloc_count < 256) allocations[alloc_count++] = p;
    return p;
}

void free_allocations() {
    // NOTE: Disabled freeing of tracked allocations to keep cached ffi_type
    // structures valid for the lifetime of the process. This avoids dangling
    // pointers when signature caching is used. Potential memory growth is
    // acceptable for the lifetime of an interactive session.
    return;
}

// Forward declaration
TypeInfo parse_type_info(char *s);

ffi_type *create_struct_type(char *content) {
    // content is modified in place
    int count = 1;
    int depth = 0;
    for (char *p = content; *p; p++) {
        if (*p == '{') depth++;
        else if (*p == '}') depth--;
        else if (*p == ',' && depth == 0) count++;
    }
    
    ffi_type **elements = track_malloc(sizeof(ffi_type*) * (count + 1));
    
    char *p = content;
    int i = 0;
    while (*p) {
        char *start = p;
        depth = 0;
        while (*p) {
            if (*p == '{') depth++;
            else if (*p == '}') depth--;
            else if (*p == ',' && depth == 0) break;
            p++;
        }
        
        if (*p == ',') {
            *p = '\0';
            p++;
        }
        
        TypeInfo ti = parse_type_info(start);
        elements[i++] = ti.ffi_type_ptr;
    }
    elements[i] = NULL;
    
    ffi_type *st = track_malloc(sizeof(ffi_type));
    st->size = 0;
    st->alignment = 0;
    st->type = FFI_TYPE_STRUCT;
    st->elements = elements;
    
    return st;
}

TypeInfo parse_type_info(char *s) {
    TypeInfo ti;
    ti.type = TYPE_UNKNOWN;
    ti.ffi_type_ptr = &ffi_type_void;
    
    if (!s) return ti;
    
    if (s[0] == '{') {
        size_t len = strlen(s);
        if (s[len-1] == '}') {
            char *copy = strdup(s);
            size_t len_copy = strlen(copy);
            copy[len_copy-1] = '\0';
            ti.type = TYPE_STRUCT;
            ti.ffi_type_ptr = create_struct_type(copy + 1);
            free(copy); 
            return ti;
        }
    }
    
    if (strcmp(s, "void") == 0) { ti.type = TYPE_VOID; ti.ffi_type_ptr = &ffi_type_void; }
    else if (strcmp(s, "i32") == 0) { ti.type = TYPE_INT; ti.ffi_type_ptr = &ffi_type_sint32; }
    else if (strcmp(s, "u32") == 0) { ti.type = TYPE_INT; ti.ffi_type_ptr = &ffi_type_uint32; }
    else if (strcmp(s, "i64") == 0) { ti.type = TYPE_INT; ti.ffi_type_ptr = &ffi_type_sint64; }
    else if (strcmp(s, "u64") == 0) { ti.type = TYPE_INT; ti.ffi_type_ptr = &ffi_type_uint64; }
    else if (strcmp(s, "int") == 0) { ti.type = TYPE_INT; ti.ffi_type_ptr = &ffi_type_sint32; }
    else if (strcmp(s, "bool") == 0) { ti.type = TYPE_INT; ti.ffi_type_ptr = &ffi_type_uint8; } 
    else if (strcmp(s, "str") == 0) { ti.type = TYPE_PTR; ti.ffi_type_ptr = &ffi_type_pointer; }
    else if (strcmp(s, "ptr") == 0) { ti.type = TYPE_PTR; ti.ffi_type_ptr = &ffi_type_pointer; }
    else if (strcmp(s, "f32") == 0) { ti.type = TYPE_FLOAT; ti.ffi_type_ptr = &ffi_type_float; }
    else if (strcmp(s, "f64") == 0) { ti.type = TYPE_DOUBLE; ti.ffi_type_ptr = &ffi_type_double; }
    
    return ti;
}

int callso_builtin(WORD_LIST *list) {
    // Usage: callso [-v var] <libpath> <signature> <funcname> [args...]
    if (!list) return EX_USAGE;

    char *output_var = NULL;
    if (strcmp(list->word->word, "-v") == 0) {
        list = list->next;
        if (!list) return EX_USAGE;
        output_var = list->word->word;
        list = list->next;
    }

    if (!list || !list->next || !list->next->next) {
        fprintf(stderr, "Usage: callso [-v var] <libpath> <signature> <funcname> [args...]\n");
        return EX_USAGE;
    }
    
    // alloc_count = 0; // Reset allocation tracker - DISABLED for caching
    
    char *lib_path = list->word->word;
    list = list->next;
    
    char *sig = list->word->word;
    list = list->next;
    
    char *func_name = list->word->word;
    list = list->next;
    
    // Load library (use persistent cache)
    void *lib_handle = NULL;
    for (int i = 0; i < cached_lib_count; i++) {
        if (strcmp(cached_lib_paths[i], lib_path) == 0) { lib_handle = cached_lib_handles[i]; break; }
    }
    if (!lib_handle) {
        lib_handle = dlopen(lib_path, RTLD_LAZY | RTLD_GLOBAL);

        if (!lib_handle) {
            fprintf(stderr, "callso: Failed to load library '%s': %s\n", lib_path, dlerror());
            return EXECUTION_FAILURE;
        }
        if (cached_lib_count < CACHE_MAX) {
            cached_lib_paths[cached_lib_count] = strdup(lib_path);
            cached_lib_handles[cached_lib_count] = lib_handle;
            cached_lib_count++;
        }
    }

    // Lookup function (use symbol cache)
    void *func_ptr = NULL;
    for (int i = 0; i < cached_symbol_count; i++) {
        if (strcmp(cached_symbol_lib[i], lib_path) == 0 && strcmp(cached_symbol_name[i], func_name) == 0) {
            func_ptr = cached_symbol_ptr[i];
            break;
        }
    }
    if (!func_ptr) {
        func_ptr = dlsym(lib_handle, func_name);

        if (!func_ptr) {
            fprintf(stderr, "callso: Symbol '%s' not found in '%s'\n", func_name, lib_path);
            return EXECUTION_FAILURE;
        }
        if (cached_symbol_count < CACHE_MAX) {
            cached_symbol_lib[cached_symbol_count] = strdup(lib_path);
            cached_symbol_name[cached_symbol_count] = strdup(func_name);
            cached_symbol_ptr[cached_symbol_count] = func_ptr;
            cached_symbol_count++;
        }
    }
    
    // Check Signature Cache
    int cache_idx = -1;
    for (int i = 0; i < cached_sig_count; i++) {
        if (strcmp(cached_sig_str[i], sig) == 0) {
            cache_idx = i;
            break;
        }
    }

    ffi_cif *cif_ptr;
    ffi_type **arg_types;
    ArgType *arg_argtypes;
    ArgType ret_argtype;
    ffi_type *ret_type_ptr;
    int arg_count;

    if (cache_idx != -1) {
        // Cache Hit
        cif_ptr = &cached_cif[cache_idx];
        arg_types = cached_arg_types[cache_idx];
        arg_argtypes = cached_arg_argtypes[cache_idx];
        ret_argtype = cached_ret_argtype[cache_idx];
        ret_type_ptr = cached_ret_type[cache_idx];
        arg_count = cached_arg_count[cache_idx];
    } else {
        // Cache Miss - Parse and Prepare
        if (cached_sig_count >= CACHE_MAX) {
            fprintf(stderr, "callso: Signature cache full!\n");
            return EXECUTION_FAILURE;
        }
        
        char sig_buf[1024];
        strncpy(sig_buf, sig, 1023);
        sig_buf[1023] = '\0';
        
        char *ret_type_str = strtok(sig_buf, " ");
        TypeInfo ret_ti = parse_type_info(ret_type_str);
        
        arg_types = track_malloc(sizeof(ffi_type*) * MAX_ARGS);
        arg_argtypes = cached_arg_argtypes[cached_sig_count];
        
        arg_count = 0;
        char *arg_type_str;
        while ((arg_type_str = strtok(NULL, " ")) != NULL) {
            if (arg_count >= MAX_ARGS) break;
            TypeInfo ti = parse_type_info(arg_type_str);
            arg_types[arg_count] = ti.ffi_type_ptr;
            arg_argtypes[arg_count] = ti.type;
            arg_count++;
        }
        
        if (ffi_prep_cif(&cached_cif[cached_sig_count], FFI_DEFAULT_ABI, arg_count, ret_ti.ffi_type_ptr, arg_types) != FFI_OK) {
            fprintf(stderr, "callso: ffi_prep_cif failed\n");
            return EXECUTION_FAILURE;
        }

        // Store in cache
        cached_sig_str[cached_sig_count] = strdup(sig);
        cached_arg_types[cached_sig_count] = arg_types;
        cached_ret_type[cached_sig_count] = ret_ti.ffi_type_ptr;
        cached_ret_argtype[cached_sig_count] = ret_ti.type;
        cached_arg_count[cached_sig_count] = arg_count;
        
        cif_ptr = &cached_cif[cached_sig_count];
        ret_type_ptr = ret_ti.ffi_type_ptr;
        ret_argtype = ret_ti.type;
        
        cached_sig_count++;
    }

    // Prepare Arguments
    void *arg_values[MAX_ARGS];
    long storage_longs[MAX_ARGS];
    double storage_doubles[MAX_ARGS];
    float storage_floats[MAX_ARGS];
    void *storage_ptrs[MAX_ARGS];

    for (int i = 0; i < arg_count; i++) {
        if (!list) {
            fprintf(stderr, "callso: Not enough arguments for '%s'\n", func_name);
            return EXECUTION_FAILURE;
        }
        char *valstr = list->word->word;
        list = list->next;

        switch (arg_argtypes[i]) {
            case TYPE_INT:
                storage_longs[i] = strtol(valstr, NULL, 0);
                arg_values[i] = &storage_longs[i];
                break;
            case TYPE_PTR:
                if (strcmp(valstr, "NULL") == 0) {
                    storage_ptrs[i] = NULL;
                } else {
                    char *end;
                    long long addr = strtoll(valstr, &end, 0);
                    if (end != valstr && *end == '\0') {
                        storage_ptrs[i] = (void *)(uintptr_t)addr;
                    } else {
                        storage_ptrs[i] = valstr;
                    }
                }
                arg_values[i] = &storage_ptrs[i];
                break;
            case TYPE_FLOAT:
                storage_floats[i] = (float)strtod(valstr, NULL);
                arg_values[i] = &storage_floats[i];
                break;
            case TYPE_DOUBLE:
                storage_doubles[i] = strtod(valstr, NULL);
                arg_values[i] = &storage_doubles[i];
                break;
            case TYPE_STRUCT: {
                if (strcmp(valstr, "NULL") == 0) {
                    fprintf(stderr, "callso: Error: Argument %d for '%s' is a struct but received NULL.\n", i, func_name);
                    return EXECUTION_FAILURE;
                }
                char *end;
                long long addr = strtoll(valstr, &end, 0);
                if (end == valstr || *end != '\0') {
                    fprintf(stderr, "callso: Error: Argument %d for '%s' expected struct pointer/address.\n", i, func_name);
                    return EXECUTION_FAILURE;
                }
                // Use the original struct memory directly
                storage_ptrs[i] = (void *)(uintptr_t)addr;
                arg_values[i] = storage_ptrs[i];
                break;
            }
            default:
                storage_ptrs[i] = NULL;
                arg_values[i] = &storage_ptrs[i];
                break;
        }
    }

    // Call
    char out_buf[256];
    out_buf[0] = '\0';

    if (ret_argtype == TYPE_STRUCT) {
        void *ret_mem = malloc(ret_type_ptr->size);
        ffi_call(cif_ptr, FFI_FN(func_ptr), ret_mem, arg_values);
        snprintf(out_buf, sizeof(out_buf), "%lld", (long long)(uintptr_t)ret_mem);
    } else {
        ffi_arg result = 0;
        ffi_call(cif_ptr, FFI_FN(func_ptr), &result, arg_values);
        
        if (ret_argtype != TYPE_VOID) {
            if (ret_argtype == TYPE_INT) {
                snprintf(out_buf, sizeof(out_buf), "%lld", (long long)result);
            } else if (ret_argtype == TYPE_PTR) {
                snprintf(out_buf, sizeof(out_buf), "%lld", (long long)(uintptr_t)result); 
            } else if (ret_argtype == TYPE_FLOAT) {
                float f;
                memcpy(&f, &result, sizeof(float));
                snprintf(out_buf, sizeof(out_buf), "%f", (double)f);
            } else if (ret_argtype == TYPE_DOUBLE) {
                double d;
                memcpy(&d, &result, sizeof(double));
                snprintf(out_buf, sizeof(out_buf), "%f", d);
            }
        }
    }

    if (output_var) {
        if (out_buf[0]) bind_variable(output_var, out_buf, 0);
    } else {
        if (out_buf[0]) printf("%s\n", out_buf);
    }
    
    free_allocations();
    return EXECUTION_SUCCESS;
}

char *callso_doc[] = {
    "Call arbitrary shared library functions.",
    "Usage: callso <libpath> <signature> <funcname> [args...]",
    (char *)NULL
};

struct builtin callso_struct = {
    "callso",
    callso_builtin,
    BUILTIN_ENABLED,
    callso_doc,
    "callso <libpath> <signature> <funcname> [args...]",
    0
};
