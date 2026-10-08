#ifndef IRIS_PROFILER_H
#define IRIS_PROFILER_H
#include <string.h>
#include "bsp.h"
#include "clint.h"
#include "platform/tinyml/accel_settings.h"
#include "platform/tinyml/ops/cache.h"
#include "tensorflow/lite/micro/micro_profiler.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
extern "C" [[noreturn]] void IrisDispatchStop(const char*);

// Record only while Invoke is running; UART transmission follows measurement.
class IrisProfiler : public tflite::MicroProfiler {
 public:
  static void operator delete(void*) {}
  void Reset() { count_ = 0; }
  uint64_t BeginEvent(const char* tag) override {
    tag_ = tag; layer_mode[0] = "SOFTWARE";
    begin_ = clint_getTime(BSP_CLINT); return 0;
  }
  void EndEvent(uint64_t) override {
    const uint64_t ticks = clint_getTime(BSP_CLINT) - begin_;
    if (count_ == 24) IrisDispatchStop("profiler capacity exceeded");
#if IRIS_STRICT_DISPATCH
    const char* mode = layer_mode[0];
    if (strcmp(mode,"STANDARD") && strcmp(mode,"LITE") && strcmp(mode,"IRIS_RESIZE_HW"))
      IrisDispatchStop("operation completed without a hardware mode");
#endif
    const bool vendor = strcmp(layer_mode[0],"IRIS_RESIZE_HW") != 0 && hw_accel_setting[0].cache_en;
    const uint32_t hits = vendor ? static_cast<uint32_t>(get_cache_hit_cntr()) : 0;
    const uint32_t misses = vendor ? static_cast<uint32_t>(get_cache_miss_cntr()) : 0;
    events_[count_++] = {tag_,layer_mode[0],ticks,hits,misses};
  }
  void Print() const {
    for (unsigned i=0;i<count_;++i)
      MicroPrintf("%u; %s; %s; ticks=%u cache_hit_raw=%u cache_miss_raw=%u\n\r",i,events_[i].tag,events_[i].mode,
                  static_cast<unsigned>(events_[i].ticks),events_[i].hits,events_[i].misses);
  }
 private:
  struct Event { const char* tag; const char* mode; uint64_t ticks; uint32_t hits,misses; };
  Event events_[24];
  unsigned count_ = 0;
  const char* tag_ = nullptr;
  uint64_t begin_ = 0;
};
#endif
