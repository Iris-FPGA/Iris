#ifndef IRIS_DMA_CACHE_H
#define IRIS_DMA_CACHE_H
#include "soc.h"
// Sapphire's official driver ABI: flush/write back and invalidate CPU data
// cache. FENCE alone does not publish dirty cache lines to the AXI DMA.
inline void IrisFlushCpuDataCache() {
  asm volatile("fence rw,rw" ::: "memory");
#if SYSTEM_CORES_0_DCACHE_SIZE
  asm volatile(".word 0x0000500f" ::: "memory");
#endif
}
#endif
