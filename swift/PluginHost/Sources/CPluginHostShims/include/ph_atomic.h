#ifndef PH_ATOMIC_H
#define PH_ATOMIC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Type-erased C11 atomics для Swift-стороны.
 *
 * Хранилище выделяет Swift (UnsafeMutableRawPointer), указатель на него не
 * двигается, поэтому можно передавать void*. Это единственный способ получить
 * честные lock-free счётчики (проверка «есть ли подписчики» за наносекунды)
 * без внешних зависимостей (swift-atomics).
 */

void    ph_atomic_init_i32(void *storage, int32_t value);
int32_t ph_atomic_load_i32(const void *storage);
int32_t ph_atomic_fetch_add_i32(void *storage, int32_t delta);
int32_t ph_atomic_exchange_i32(void *storage, int32_t value);
void    ph_atomic_store_i32(void *storage, int32_t value);

#ifdef __cplusplus
}
#endif

#endif /* PH_ATOMIC_H */
