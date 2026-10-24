#include "bsp.h"
#include "clint.h"
// Failed timing hypothesis experiment; not linked into production firmware.
// Diagnostic guard after the vendor cache-reset command. Its public API has no
// cache-ready poll. The guard tests a reset/configuration timing hypothesis;
// it does not establish the IP's undocumented internal reset duration. A zero
// guard preserves the original behavior for controlled comparisons. No tensor
// data or completion flag is changed by this wrapper.
extern "C" void __real__Z11cache_resetv();
extern "C" void __wrap__Z11cache_resetv() {
  __real__Z11cache_resetv();
#if IRIS_PROBE_CACHE_RESET_GUARD_TICKS > 0
  const uint64_t begin=clint_getTime(BSP_CLINT);
  while(clint_getTime(BSP_CLINT)-begin<IRIS_PROBE_CACHE_RESET_GUARD_TICKS) {}
#endif
}

