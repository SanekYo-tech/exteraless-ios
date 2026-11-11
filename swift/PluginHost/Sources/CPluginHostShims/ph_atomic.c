#include "include/ph_atomic.h"

#include <stdatomic.h>

void ph_atomic_init_i32(void *storage, int32_t value)
{
    atomic_init((_Atomic int32_t *)storage, value);
}

int32_t ph_atomic_load_i32(const void *storage)
{
    return atomic_load((const _Atomic int32_t *)storage);
}

int32_t ph_atomic_fetch_add_i32(void *storage, int32_t delta)
{
    return atomic_fetch_add((_Atomic int32_t *)storage, delta);
}

int32_t ph_atomic_exchange_i32(void *storage, int32_t value)
{
    return atomic_exchange((_Atomic int32_t *)storage, value);
}

void ph_atomic_store_i32(void *storage, int32_t value)
{
    atomic_store((_Atomic int32_t *)storage, value);
}
