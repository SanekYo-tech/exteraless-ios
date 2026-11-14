#ifndef EXTERALESS_PLUGIN_HOOK_GATE_H
#define EXTERALESS_PLUGIN_HOOK_GATE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Zero-initialized process-wide gate; no Swift singleton is touched by a load. */
uint32_t xthooks_subscriber_mask_load(void);
void xthooks_subscriber_mask_store(uint32_t mask);

#ifdef __cplusplus
}
#endif

#endif
