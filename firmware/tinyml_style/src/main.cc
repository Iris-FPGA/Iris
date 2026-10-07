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
#include "iris_profiler.h"
#include "iris_resize.h"
#include "iris_dma_cache.h"
extern "C" volatile uint32_t iris_result[8];

namespace {
alignas(64) uint8_t tensor_arena[IRIS_ARENA_BYTES]
    __attribute__((section(".tinyml_arena")));

[[noreturn]] void Stop(const char* reason) {
  if (iris_result[0] != 2) iris_result[0] = 3;
  MicroPrintf("IRIS STOP: %s\n\r", reason);
  while (true) {}
}
}

extern "C" [[noreturn]] void IrisDispatchStop(const char* reason) { Stop(reason); }

// Debugger-readable evidence; status 1=running, 2=output ready, 3=stopped.
extern "C" {
volatile uint32_t iris_result[8];
// Live mode: status, sequence, input, output, bytes, ticks low/high,
// displayed pairs, captures, underflows, DMA read errors, rejected commands.
volatile uint32_t iris_live_result[12] __attribute__((section(".tinyml_control")));
}

extern "C" uint32_t __iris_driver_bss_start[], __iris_driver_bss_end[];
extern "C" uint32_t __iris_driver_data_start[], __iris_driver_data_end[], __iris_driver_data_lma[];
extern "C" int main() {
  for(auto* p=__iris_driver_data_start;p<__iris_driver_data_end;++p)*p=__iris_driver_data_lma[p-__iris_driver_data_start];
  for(auto* p=__iris_driver_bss_start;p<__iris_driver_bss_end;++p)*p=0;
  // The official Ti60 platform settings arrays have exactly one entry.
  if (csr_read(mhartid) != 0) while (true) {}
  bsp_init();
  iris_result[0] = 1;
  iris_result[1] = 0;
  for(unsigned i=0;i<12;++i)iris_live_result[i]=0;
#if IRIS_STRICT_DISPATCH
  MicroPrintf("Iris style static bring-up; STRICT HARDWARE DISPATCH\n\r");
  MicroPrintf("Resize: IRIS hardware; Conv/Add: reject fallback and OP_BYPASS\n\r");
#else
  MicroPrintf("Iris style static bring-up; NOT DISPATCH-ONLY\n\r");
  MicroPrintf("ResizeNearestNeighbor: VENDOR SOFTWARE (2 nodes)\n\r");
  MicroPrintf("Conv2D/Add: vendor dispatch permits CPU fallback; inspect every profile row\n\r");
#endif
  // DDR consistency probe (shared-path validation): pattern write/read in a
  // region far from video [0,0x5f4000) and from this image ([0x800000,...)).
  // Runs while the video frame buffer is streaming DDR traffic.
  {
    const uintptr_t base = 0x00700000u;
    const uint32_t words = 16384;  // 64 KiB
    uint32_t fails = 0, last_bad_addr = 0, last_bad_val = 0, last_bad_exp = 0;
    for (uint32_t i = 0; i < words; ++i)
      *reinterpret_cast<volatile uint32_t*>(base + i * 4) = 0xA5000000u + i;
    for (uint32_t i = 0; i < words; ++i) {
      uint32_t v = *reinterpret_cast<volatile uint32_t*>(base + i * 4);
      uint32_t e = 0xA5000000u + i;
      if (v != e) {
        fails++;
        last_bad_addr = base + i * 4;
        last_bad_val = v;
        last_bad_exp = e;
        if (fails <= 3) {
          volatile uint32_t* bk = reinterpret_cast<volatile uint32_t*>(0xF8110000u);
          MicroPrintf("coher fail i=%u @0x%x r1=0x%x exp=0x%x cpuAR=0x%x arlen=%u arsize=%u arburst=%u\n\r",
                      i, base + i * 4, v, e, bk[11], bk[2] & 255, (bk[3] >> 2) & 7, bk[3] & 3);
        }
      }
    }
    MicroPrintf("DDR coher: fails=%u bad@0x%x got=0x%x exp=0x%x\n\r",
                fails, last_bad_addr, last_bad_val, last_bad_exp);
    // second pass: reverse pattern (catches both lost writes and wrong reads)
    uint32_t fails2 = 0;
    for (uint32_t i = 0; i < words; ++i)
      *reinterpret_cast<volatile uint32_t*>(base + i * 4) = 0x5A000000u + (i * 2654435761u);
    for (uint32_t i = 0; i < words; ++i)
      if (*reinterpret_cast<volatile uint32_t*>(base + i * 4) != 0x5A000000u + (i * 2654435761u)) fails2++;
    MicroPrintf("DDR coher pass2: fails=%u\n\r", fails2);
    if (fails || fails2) Stop("DDR consistency failed; inference must not run");
    volatile uint32_t* bank = reinterpret_cast<volatile uint32_t*>(0xF8110000u);
    MicroPrintf("arb state=0x%x cpuAR=0x%x fbAR=0x%x\n\r",
                bank[0], bank[11], bank[12]);
    MicroPrintf("arb cpuAW=0x%x fbAW=0x%x rdCnt cpu/fb=%u/%u rresp=%u\n\r",
                bank[13], bank[14], bank[15] & 0xffff, bank[15] >> 16, bank[9]);
    MicroPrintf("arb ARhand=%u rdDone=%u AWhand=%u wrDone=%u\n\r",
                bank[17], bank[6], bank[18], bank[7]);
    MicroPrintf("lastAR addr=0x%x len=%u size=%u burst=%u | lastAW addr=0x%x len=%u\n\r",
                bank[1], bank[2] & 255, (bank[3] >> 2) & 7, bank[3] & 3,
                bank[4], bank[5] & 255);
  }

  if (!IrisModelContract()) Stop("model contract/schema mismatch");
  iris_result[1] = 1;


  // Requires a connected custom-instruction responder, even for discovery.
  init_accel(0);
  print_accel(0);
  if (accel_count < 1 || !hw_accel_setting[0].accel_active ||
      hw_accel_setting[0].conv_depthw_mode == 0 || hw_accel_setting[0].add_mode == 0)
    Stop("required Conv/Add accelerator configuration absent");
  IntcInitialize();
  iris_result[1] = 2;

  static tflite::MicroErrorReporter reporter;
  static tflite::MicroMutableOpResolver<3> resolver(&reporter);
  if (resolver.AddConv2D() != kTfLiteOk || resolver.AddAdd() != kTfLiteOk)
    Stop("op registration failed");
  if (resolver.AddResizeNearestNeighbor() != kTfLiteOk) Stop("resize registration failed");
  static IrisProfiler profiler __attribute__((section(".tinyml_control")));
  static tflite::MicroInterpreter interpreter __attribute__((section(".tinyml_control")))(
      tflite::GetModel(IrisModelData), resolver,
      tensor_arena, sizeof(tensor_arena), &reporter, &profiler);
  if (interpreter.AllocateTensors() != kTfLiteOk) Stop("AllocateTensors failed");
  iris_result[1] = 3;
  MicroPrintf("DDR arena: base=0x%x capacity=%u used=%u\n\r",
              static_cast<unsigned>(reinterpret_cast<uintptr_t>(tensor_arena)),
              static_cast<unsigned>(sizeof(tensor_arena)),
              static_cast<unsigned>(interpreter.arena_used_bytes()));
  auto* input = interpreter.input(0);
  if (input->bytes != kIrisHeight * kIrisWidth * kIrisChannels || input->type != kTfLiteInt8)
    Stop("unexpected input tensor");
#if IRIS_LIVE_DEMO
#if !IRIS_MODEL_RGBA || !IRIS_STRICT_DISPATCH
#error Live demo requires RGBA640 and strict hardware dispatch
#endif
  volatile uint32_t* demo = reinterpret_cast<volatile uint32_t*>(0xf8100000u);
  if ((demo[0] >> 16) != 0x4953 || demo[9] != 0x000a0001)
    Stop("live camera/display hardware ABI absent");
  const auto* graph = tflite::GetModel(IrisModelData)->subgraphs()->Get(0);
  auto* output = interpreter.output(0);
  if (!output || output->bytes != input->bytes)
    Stop("live tensor binding failed");
  MicroPrintf("IRIS LIVE: 640x480 paired camera/style; no CPU image processing; SRAM only\n\r");
  for (uint32_t sequence=1;;++sequence) {
    // Wait for VS ownership acknowledgement before choosing the free pair.
    uint64_t deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
    while (demo[0] & 32u)
      if(clint_getTime(BSP_CLINT)>deadline)Stop("display pair acknowledgement timeout");
    const uint32_t status=demo[0];
    const uint32_t pair=(status & 8u) ? ((status >> 4) & 1u)^1u : 0u;
    demo[1]=pair;
    const uintptr_t input_address=demo[2],output_address=demo[3];
    if(input_address!=(pair ? 0x03200000u : 0x03000000u) ||
       output_address!=(pair ? 0x03600000u : 0x03400000u))Stop("live bank address mismatch");
    iris_live_result[0]=1;
    IrisFlushCpuDataCache();
    if(sequence==1)MicroPrintf("IRIS LIVE before capture: input_view=0x%x output_view=0x%x eval23=0x%x\n\r",
      reinterpret_cast<uintptr_t>(input),reinterpret_cast<uintptr_t>(output),
      reinterpret_cast<uintptr_t>(interpreter.context_.GetEvalTensor(&interpreter.context_,23)->data.raw));
    const uint32_t rejects=demo[8];
    demo[0]=1u;
    deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
    while (!(demo[0] & 1u))
      if(demo[8]!=rejects || clint_getTime(BSP_CLINT)>deadline)Stop("camera capture start failed");
    deadline=clint_getTime(BSP_CLINT)+2ull*SYSTEM_CLINT_HZ;
    while (demo[0] & 1u)
      if(clint_getTime(BSP_CLINT)>deadline)Stop("camera frame capture timeout");
    if(!(demo[0]&2u) || (demo[0]&4u)) {
      MicroPrintf("IRIS LIVE: dropped incomplete camera frame, retry\n\r");
      continue;
    }
    if(sequence==1)MicroPrintf("IRIS LIVE after capture: input_data=0x%x output_data=0x%x eval23=0x%x\n\r",
      reinterpret_cast<uintptr_t>(input->data.raw),reinterpret_cast<uintptr_t>(output->data.raw),
      reinterpret_cast<uintptr_t>(interpreter.context_.GetEvalTensor(&interpreter.context_,23)->data.raw));
    if(sequence==1)MicroPrintf("IRIS CTRL before input copy: intr=%x/%x ops=%x\n\r",global_intr_id[0],global_intr_id[1],reinterpret_cast<uintptr_t>(ops_list));
    if(!IrisCopyTensorDma(input_address,reinterpret_cast<uintptr_t>(input->data.int8),
                          kIrisHeight,kIrisWidth,kIrisChannels))Stop("camera input DMA transport failed");
    if(sequence==1)MicroPrintf("IRIS CTRL after input copy: intr=%x/%x ops=%x\n\r",global_intr_id[0],global_intr_id[1],reinterpret_cast<uintptr_t>(ops_list));
    // Relocating graph I/O must never redirect intermediate DMA writes into
    // the ELF, heap metadata or read-only model. Check before issuing Conv.
    for(unsigned node_index=0;node_index<graph->operators()->size();++node_index) {
      const auto* node=graph->operators()->Get(node_index);
      for(unsigned j=0;j<node->outputs()->size();++j) {
        const int id=node->outputs()->Get(j);
        const auto* tensor=interpreter.context_.GetEvalTensor(&interpreter.context_,id);
        const uintptr_t address=reinterpret_cast<uintptr_t>(tensor->data.raw);
        if(sequence==1)MicroPrintf("IRIS LIVE DMA node=%u tensor=%u output=0x%x\n\r",node_index,id,address);
        if(address!=output_address &&
           (address<reinterpret_cast<uintptr_t>(tensor_arena) ||
            address>=reinterpret_cast<uintptr_t>(tensor_arena)+sizeof(tensor_arena)))
          Stop("live intermediate DMA points outside tensor arena");
      }
    }
    IrisFlushCpuDataCache();cache_reset();
    iris_live_result[0]=2;
    profiler.Reset();
    const uint64_t begin=clint_getTime(BSP_CLINT);
    if(interpreter.Invoke()!=kTfLiteOk)Stop("live Invoke failed");
    const uint64_t ticks=clint_getTime(BSP_CLINT)-begin;
    IrisFlushCpuDataCache();cache_reset();
    if(!IrisCopyTensorDma(reinterpret_cast<uintptr_t>(output->data.int8),output_address,
                          kIrisHeight,kIrisWidth,kIrisChannels))Stop("style output DMA transport failed");
    iris_live_result[1]=sequence;iris_live_result[2]=input_address;
    iris_live_result[3]=output_address;iris_live_result[4]=output->bytes;
    iris_live_result[5]=static_cast<uint32_t>(ticks);iris_live_result[6]=static_cast<uint32_t>(ticks>>32);
    demo[0]=2u;
    deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
    while(demo[0]&32u)
      if(clint_getTime(BSP_CLINT)>deadline)Stop("live display commit timeout");
    if(demo[8]!=rejects)Stop("live command rejected");
    for(unsigned i=7;i<12;++i)iris_live_result[i]=demo[i-3];
    iris_live_result[0]=3;IrisFlushCpuDataCache();
    if(sequence==1)profiler.Print();
    MicroPrintf("IRIS LIVE frame=%u pair=%u Invoke_ticks=%u displayed=%u captures=%u underflow=%u readerr=%u rejects=%u\n\r",
       sequence,pair,static_cast<unsigned>(ticks),demo[4],demo[5],demo[6],demo[7],demo[8]);
  }
#else
  // Deterministic RGB fixture, already quantized with scale=1, zero_point=-128.
  for (int y = 0; y < kIrisHeight; ++y) {
    for (int x = 0; x < kIrisWidth; ++x) {
      const int i = (y * kIrisWidth + x) * kIrisChannels;
      input->data.int8[i] = static_cast<int8_t>(256 * x / kIrisWidth - 128);
      input->data.int8[i + 1] = static_cast<int8_t>(256 * y / kIrisHeight - 128);
      input->data.int8[i + 2] = static_cast<int8_t>((((x / 16) ^ (y / 16)) & 1) ? 127 : -128);
      if (kIrisChannels == 4) input->data.int8[i + 3] = -128;
    }
  }
  MicroPrintf("profile: node; op; vendor execution mode; CLINT ticks (printed after Invoke)\n\r");
  profiler.Reset();
  const uint64_t start = clint_getTime(BSP_CLINT);
  if (interpreter.Invoke() != kTfLiteOk) Stop("Invoke failed");
  const uint64_t ticks = clint_getTime(BSP_CLINT) - start;
  profiler.Print();
  const auto* output = interpreter.output(0);
  uint32_t hash = 2166136261u;
  for (size_t i = 0; i < output->bytes; ++i)
    hash = (hash ^ output->data.uint8[i]) * 16777619u;
  iris_result[2] = reinterpret_cast<uintptr_t>(output->data.int8);
  iris_result[3] = output->bytes;
  iris_result[4] = hash;
  iris_result[5] = static_cast<uint32_t>(ticks);
  iris_result[6] = static_cast<uint32_t>(ticks >> 32);
  asm volatile("fence rw,rw" ::: "memory");
  iris_result[0] = 2;
  // Publish the descriptor to external DDR before OpenOCD reads it. The
  // official driver uses the same Sapphire data-cache flush instruction.
  IrisFlushCpuDataCache();
  MicroPrintf("output bytes=%u FNV1a=0x%x (diagnostic, no golden parity claim)\n\r",
              static_cast<unsigned>(output->bytes), hash);
  MicroPrintf("CLINT ticks hi=0x%x lo=0x%x Hz=%u (excludes profile UART transmission)\n\r",
              static_cast<unsigned>(ticks >> 32), static_cast<unsigned>(ticks), SYSTEM_CLINT_HZ);
  ops_unload();
  Stop("inference complete; validate output dump against the matching integer reference");
#endif
}
