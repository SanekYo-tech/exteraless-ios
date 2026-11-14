#include "include/PluginHookGate.h"

#include <stdatomic.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "PluginHooks needs lock-free 32-bit loads");

static _Atomic(uint32_t) subscriber_mask = 0;

uint32_t xthooks_subscriber_mask_load(void) {
    return atomic_load_explicit(&subscriber_mask, memory_order_acquire);
}

void xthooks_subscriber_mask_store(uint32_t mask) {
    atomic_store_explicit(&subscriber_mask, mask, memory_order_release);
}
