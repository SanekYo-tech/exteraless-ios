#include "include/ph_atomic.h"

#include <stdatomic.h>

_Static_assert(sizeof(_Atomic int32_t) == sizeof(int32_t),
               "Swift AtomicInt32 allocates MemoryLayout<Int32>; _Atomic int32_t must match");
_Static_assert(_Alignof(_Atomic int32_t) <= _Alignof(int32_t),
               "_Atomic int32_t alignment exceeds Int32; Swift storage would be misaligned");

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
