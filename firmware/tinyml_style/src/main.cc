#include <stdint.h>
#include "bsp.h"
#include "clint.h"
#include "riscv.h"
#include "intc.h"
#include "model_contract.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"
#include "tensorflow/lite/micro/micro_interpreter.h"
#include "tensorflow/lite/micro/micro_mutable_op_resolver.h"
#include "platform/tinyml/accel_settings.h"
#include "platform/tinyml/profiler.h"

#if IRIS_STRICT_DISPATCH
#error "Dispatch-only blocked: hardware resize and fail-closed Conv/Add dispatch are not implemented"
#endif

namespace {
alignas(64) uint8_t tensor_arena[IRIS_ARENA_BYTES]
    __attribute__((section(".tinyml_arena")));

[[noreturn]] void Stop(const char* reason) {
  MicroPrintf("IRIS STOP: %s\n\r", reason);
  while (true) {}
}
}

extern "C" int main() {
  // The official Ti60 platform settings arrays have exactly one entry.
  if (csr_read(mhartid) != 0) while (true) {}
  MicroPrintf("Iris style static bring-up; NOT DISPATCH-ONLY\n\r");
  MicroPrintf("ResizeNearestNeighbor: VENDOR SOFTWARE (2 nodes)\n\r");
  MicroPrintf("Conv2D/Add: vendor dispatch permits CPU fallback; inspect every profile row\n\r");
  if (!IrisModelContract()) Stop("model contract/schema mismatch");

  // Requires a connected custom-instruction responder, even for discovery.
  init_accel(0);
  print_accel(0);
  if (accel_count < 1 || !hw_accel_setting[0].accel_active ||
      hw_accel_setting[0].conv_depthw_mode == 0 || hw_accel_setting[0].add_mode == 0)
    Stop("required Conv/Add accelerator configuration absent");
  IntcInitialize();

  static tflite::MicroErrorReporter reporter;
  static tflite::MicroMutableOpResolver<3> resolver(&reporter);
  if (resolver.AddConv2D() != kTfLiteOk || resolver.AddAdd() != kTfLiteOk ||
      resolver.AddResizeNearestNeighbor() != kTfLiteOk) Stop("op registration failed");
  static FullProfiler profiler;
  static tflite::MicroInterpreter interpreter(
      tflite::GetModel(one_last_kiss_0_int8_model_data), resolver,
      tensor_arena, sizeof(tensor_arena), &reporter, &profiler);
  profiler.setInterpreter(&interpreter);
  profiler.setDump(false);
  if (interpreter.AllocateTensors() != kTfLiteOk) Stop("AllocateTensors failed");
  MicroPrintf("DDR arena: base=0x%x capacity=%u used=%u\n\r",
              static_cast<unsigned>(reinterpret_cast<uintptr_t>(tensor_arena)),
              static_cast<unsigned>(sizeof(tensor_arena)),
              static_cast<unsigned>(interpreter.arena_used_bytes()));
  auto* input = interpreter.input(0);
  if (input->bytes != 128 * 128 * 3 || input->type != kTfLiteInt8)
    Stop("unexpected input tensor");
  // Deterministic RGB fixture, already quantized with scale=1, zero_point=-128.
  for (int y = 0; y < 128; ++y) {
    for (int x = 0; x < 128; ++x) {
      const int i = (y * 128 + x) * 3;
      input->data.int8[i] = static_cast<int8_t>(2 * x - 128);
      input->data.int8[i + 1] = static_cast<int8_t>(2 * y - 128);
      input->data.int8[i + 2] = static_cast<int8_t>((((x / 16) ^ (y / 16)) & 1) ? 127 : -128);
    }
  }
  MicroPrintf("profile: node; op; vendor execution mode; milliseconds\n\r");
  const uint64_t start = clint_getTime(BSP_CLINT);
  if (interpreter.Invoke() != kTfLiteOk) Stop("Invoke failed");
  const uint64_t ticks = clint_getTime(BSP_CLINT) - start;
  const auto* output = interpreter.output(0);
  uint32_t hash = 2166136261u;
  for (size_t i = 0; i < output->bytes; ++i)
    hash = (hash ^ output->data.uint8[i]) * 16777619u;
  MicroPrintf("output bytes=%u FNV1a=0x%x (diagnostic, no golden parity claim)\n\r",
              static_cast<unsigned>(output->bytes), hash);
  MicroPrintf("CLINT ticks hi=0x%x lo=0x%x Hz=%u (includes profile UART overhead)\n\r",
              static_cast<unsigned>(ticks >> 32), static_cast<unsigned>(ticks), SYSTEM_CLINT_HZ);
  ops_unload();
  Stop("bring-up complete; hardware parity and dispatch-only remain unproven");
}
