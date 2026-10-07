#ifndef IRIS_DISPATCH_GUARD_H
#define IRIS_DISPATCH_GUARD_H
#include <string.h>
#include "platform/tinyml/ops/ops_api.h"
#include "platform/tinyml/accel_settings.h"
extern "C" [[noreturn]] void IrisDispatchStop(const char* reason);
inline void IrisRequireHardware(OP_STATUS_T result, const char* op) {
#if IRIS_STRICT_DISPATCH
  // OP_BYPASS is deliberately rejected; it does not prove a hardware layer.
  const char* mode = layer_mode[0];
  if (result != OP_OK || !mode ||
      (strcmp(mode, "STANDARD") != 0 && strcmp(mode, "LITE") != 0))
    IrisDispatchStop(op);
#else
  (void)result; (void)op;
#endif
}
#endif
