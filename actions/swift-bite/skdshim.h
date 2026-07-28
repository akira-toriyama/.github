// C shim for bitescan.swift — the two sourcekitd entry points whose signatures
// pass a struct by value. A Swift-defined struct is not C-representable in a
// `@convention(c)` type, so the struct and the function-pointer typedefs have to
// come from C. Everything else is dlsym'd against pointer-only signatures
// declared directly in Swift.
#include <stdint.h>

typedef struct {
  uint64_t data[3];
} skd_variant;

typedef skd_variant (*skd_response_get_value_f)(void *);
typedef char *(*skd_variant_json_f)(skd_variant);
