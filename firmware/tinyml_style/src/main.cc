#include <stdint.h>
#include <cmath>
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
#if IRIS_RAIN_BACKEND
#include "iris_rain_backend.h"
#include "rain_backend_anime_sketch.h"
#include "rain_backend_monet.h"
#endif
#include "anime_sketch_int8_model_data.h"
#include "monet_int8_model_data.h"

extern "C" volatile uint32_t iris_result[8];

namespace {
#if IRIS_RAIN_BACKEND
class IrisInterpreter : public tflite::MicroInterpreter {
 public:
  using tflite::MicroInterpreter::MicroInterpreter;
  TfLiteEvalTensor* EvalTensor(int index) {
    const auto& c=context();
    return c.GetEvalTensor(&c,index);
  }
};
#else
using IrisInterpreter=tflite::MicroInterpreter;
#endif

// Allocate separate DDR arenas for the two models to avoid tensor re-allocation during runtime switching
alignas(64) uint8_t tensor_arena[2][IRIS_ARENA_BYTES]
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
  MicroPrintf("Iris style dual-model bring-up; STRICT HARDWARE DISPATCH\n\r");
  MicroPrintf("Styles: [0] Anime Sketch (5k) | [1] Monet (Oil Painting)\n\r");
  MicroPrintf("Press SW1 (KEY0) anytime to switch styles in real time!\n\r");
#else
  MicroPrintf("Iris style dual-model bring-up; NOT DISPATCH-ONLY\n\r");
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
  }

  if (!IrisModelContract(anime_sketch_int8_model_data, anime_sketch_int8_model_data_len))
    Stop("anime_sketch model contract mismatch");
  if (!IrisModelContract(monet_int8_model_data, monet_int8_model_data_len))
    Stop("monet model contract mismatch");
  iris_result[1] = 1;

#if defined(IRIS_VENDOR_CACHE_OVERRIDE)
  override_hw_accel_setting[0].cache_en=IRIS_VENDOR_CACHE_OVERRIDE;
  override_hw_accel_setting[0].override_flag=1;
#endif
#if IRIS_RAIN_BACKEND
  if(opcode_R(CUSTOM0,0,76,0,0)!=0x49500101u)Stop("row backend ABI mismatch");
  hw_accel_setting[0].cache_en=0;
  MicroPrintf("Iris 8x8 row-cached Conv and pipelined Add backend active\n\r");
#else
  init_accel(0);
  print_accel(0);
  if (accel_count < 1 || !hw_accel_setting[0].accel_active ||
      hw_accel_setting[0].conv_depthw_mode == 0 || hw_accel_setting[0].add_mode == 0)
    Stop("required Conv/Add accelerator configuration absent");
#endif
  IntcInitialize();
  iris_result[1] = 2;

  static tflite::MicroErrorReporter reporter;
  static tflite::MicroMutableOpResolver<3> resolver(&reporter);
  if (resolver.AddConv2D() != kTfLiteOk || resolver.AddAdd() != kTfLiteOk)
    Stop("op registration failed");
  if (resolver.AddResizeNearestNeighbor() != kTfLiteOk) Stop("resize registration failed");
  static IrisProfiler profiler __attribute__((section(".tinyml_control")));

  static IrisInterpreter interpreter0 __attribute__((section(".tinyml_control")))(
      tflite::GetModel(anime_sketch_int8_model_data), resolver,
      tensor_arena[0], sizeof(tensor_arena[0]), &reporter, &profiler);
  static IrisInterpreter interpreter1 __attribute__((section(".tinyml_control")))(
      tflite::GetModel(monet_int8_model_data), resolver,
      tensor_arena[1], sizeof(tensor_arena[1]), &reporter, &profiler);

  if (interpreter0.AllocateTensors() != kTfLiteOk) Stop("interpreter0 AllocateTensors failed");
  if (interpreter1.AllocateTensors() != kTfLiteOk) Stop("interpreter1 AllocateTensors failed");
  iris_result[1] = 3;

  MicroPrintf("DDR arena 0 [AnimeSketch]: base=0x%x capacity=%u used=%u\n\r",
              static_cast<unsigned>(reinterpret_cast<uintptr_t>(tensor_arena[0])),
              static_cast<unsigned>(sizeof(tensor_arena[0])),
              static_cast<unsigned>(interpreter0.arena_used_bytes()));
  MicroPrintf("DDR arena 1 [Monet]:       base=0x%x capacity=%u used=%u\n\r",
              static_cast<unsigned>(reinterpret_cast<uintptr_t>(tensor_arena[1])),
              static_cast<unsigned>(sizeof(tensor_arena[1])),
              static_cast<unsigned>(interpreter1.arena_used_bytes()));

  auto* input0 = interpreter0.input(0);
  auto* input1 = interpreter1.input(0);
  if (input0->bytes != kIrisHeight * kIrisWidth * kIrisChannels || input0->type != kTfLiteInt8)
    Stop("unexpected input0 tensor");
  if (input1->bytes != kIrisHeight * kIrisWidth * kIrisChannels || input1->type != kTfLiteInt8)
    Stop("unexpected input1 tensor");

#if IRIS_LIVE_DEMO
#if !(IRIS_MODEL_RGBA || IRIS_MODEL_RAIN_PRINCESS) || !IRIS_STRICT_DISPATCH
#error Live demo requires a supported camera model and strict hardware dispatch
#endif
  volatile uint32_t* demo = reinterpret_cast<volatile uint32_t*>(0xf8100000u);
  const uint32_t expected_abi = IRIS_MODEL_RAIN_PRINCESS ? 0x00030003u : 0x00030002u;
  if ((demo[0] >> 16) != 0x4953 || demo[9] != expected_abi || demo[16]!=0x49500301u)
    Stop("live camera/display hardware ABI absent");

  auto* output0 = interpreter0.output(0);
  auto* output1 = interpreter1.output(0);
  if (!output0 || output0->bytes != input0->bytes)
    Stop("live tensor binding failed (0)");
  if (!output1 || output1->bytes != input1->bytes)
    Stop("live tensor binding failed (1)");

#if IRIS_RAIN_BACKEND
  const auto* live_graph0 = tflite::GetModel(anime_sketch_int8_model_data)->subgraphs()->Get(0);
  auto* live_input0 = interpreter0.EvalTensor(live_graph0->inputs()->Get(0));
  auto* live_output0 = interpreter0.EvalTensor(live_graph0->outputs()->Get(0));

  const auto* live_graph1 = tflite::GetModel(monet_int8_model_data)->subgraphs()->Get(0);
  auto* live_input1 = interpreter1.EvalTensor(live_graph1->inputs()->Get(0));
  auto* live_output1 = interpreter1.EvalTensor(live_graph1->outputs()->Get(0));

  if (!live_input0 || !live_output0 || live_input0->type != kTfLiteInt8 || live_output0->type != kTfLiteInt8)
    Stop("live eval tensor binding 0 failed");
  if (!live_input1 || !live_output1 || live_input1->type != kTfLiteInt8 || live_output1->type != kTfLiteInt8)
    Stop("live eval tensor binding 1 failed");
#endif

  // Hardware dequantizer contract hardcoded in the Ti60 video bitstream:
  // RGB = clip((INT8_code - (-89)) * 2.2834375)
  const float kHwScale = 2.283437490463257f;
  const float kHwZeroPoint = -89.0f;

  int8_t dequant_lut[2][256];
  bool need_dequant_remap[2] = {false, false};
  const char* style_names[2] = {"Anime Sketch (5k)", "Monet (Oil Painting)"};

  for (int m = 0; m < 2; ++m) {
    auto* out = (m == 0) ? output0 : output1;
    const float model_scale = out->params.scale;
    const int32_t model_zp = out->params.zero_point;
    if (model_scale > 0.0f && (fabsf(model_scale - kHwScale) > 0.001f || model_zp != -89)) {
      need_dequant_remap[m] = true;
      MicroPrintf("IRIS LIVE: [%s] Output dequant adaptation enabled (scale: %d/1000->%d/1000, zp: %d->%d)\n\r",
                  style_names[m],
                  static_cast<int>(model_scale * 1000.0f), static_cast<int>(kHwScale * 1000.0f),
                  static_cast<int>(model_zp), static_cast<int>(kHwZeroPoint));
      for (int i = 0; i < 256; ++i) {
        int8_t code = static_cast<int8_t>(static_cast<uint8_t>(i));
        float real = (static_cast<float>(code) - static_cast<float>(model_zp)) * model_scale;
        float hw_val = real / kHwScale + kHwZeroPoint;
        int rounded = static_cast<int>(roundf(hw_val));
        if (rounded < -128) rounded = -128;
        if (rounded > 127) rounded = 127;
        dequant_lut[m][i] = static_cast<int8_t>(rounded);
      }
    } else {
      MicroPrintf("IRIS LIVE: [%s] Output dequant matches bitstream contract natively.\n\r", style_names[m]);
    }
  }

  // Active style index: 0 = Anime Sketch, 1 = Monet
  uint32_t active_model = 0;
#if IRIS_RAIN_BACKEND
  IrisRainSetModel(anime_sketch_int8_model_data, anime_sketch_rain_weights,
                   anime_sketch_rain_filters, sizeof(anime_sketch_rain_filters) / sizeof(anime_sketch_rain_filters[0]));
#endif

  MicroPrintf("IRIS LIVE: %ux%ux%u dual-model paired camera/style; strict hardware; %s\n\r",
              kIrisWidth,kIrisHeight,kIrisChannels,
              IRIS_FLASH_BOOT ? "standalone Flash" : "SRAM only");
  MicroPrintf("IRIS LIVE: Active Style: [0] %s\n\r", style_names[active_model]);

  const uintptr_t input_banks[3]={0x03000000u,0x03200000u,0x03800000u};
  const uintptr_t output_banks[3]={0x03400000u,0x03600000u,0x03a00000u};
  auto start_capture=[&](uint32_t bank) {
    const uint32_t rejected=demo[8];
    demo[1]=bank;
    if(demo[2]!=input_banks[bank] || demo[3]!=output_banks[bank])
      Stop("capture bank address mismatch");
    demo[0]=1u;
    const uint64_t deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
    while(!(demo[0]&1u))
      if(demo[8]!=rejected || clint_getTime(BSP_CLINT)>deadline)Stop("capture start failed");
  };
  MicroPrintf("IRIS LIVE: capture/inference overlap=%u\n\r",IRIS_LIVE_PIPELINE ? 1u : 0u);
  // A debugger CPU reset leaves the independent camera/display hardware
  // running. Finish its old capture/commit and release the old CPU lease.
  const uint64_t startup_deadline=clint_getTime(BSP_CLINT)+2ull*SYSTEM_CLINT_HZ;
  while(demo[0]&(1u|32u))
    if(clint_getTime(BSP_CLINT)>startup_deadline)Stop("live startup hardware timeout");
  const uint32_t old_lease=demo[18];
  if(old_lease&4u)demo[18]=old_lease&3u;
  const uint32_t initial_display=demo[19];
  const uint32_t initial_pair=(initial_display&4u) ? ((initial_display&3u)+1u)%3u : 0u;
  uint64_t previous_commit=0;

  // Track button states (demo[23] bits 3:0 for KEY0..KEY3 / SW0..SW3)
  uint32_t last_keys = demo[23] & 0x0Fu;

  for (uint32_t sequence=1;;++sequence) {
    // Check button press with edge detection
    const uint32_t keys_cur = demo[23] & 0x0Fu;
    if (keys_cur && !last_keys) {
      active_model = 1u - active_model;
#if IRIS_RAIN_BACKEND
      if (active_model == 0) {
        IrisRainSetModel(anime_sketch_int8_model_data, anime_sketch_rain_weights,
                         anime_sketch_rain_filters, sizeof(anime_sketch_rain_filters) / sizeof(anime_sketch_rain_filters[0]));
      } else {
        IrisRainSetModel(monet_int8_model_data, monet_rain_weights,
                         monet_rain_filters, sizeof(monet_rain_filters) / sizeof(monet_rain_filters[0]));
      }
#endif
      MicroPrintf("\n\r====================================================\n\r");
      MicroPrintf(">>> [BUTTON PRESSED: 0x%x] Switched to Style [%u]: %s <<<\n\r",
                  keys_cur, active_model, style_names[active_model]);
      MicroPrintf("====================================================\n\r");
    }
    last_keys = keys_cur;

    uint64_t deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
    while(demo[0]&32u)
      if(clint_getTime(BSP_CLINT)>deadline)Stop("display acknowledgement timeout");
    const uint32_t display=demo[19];
    const uint32_t pair=IRIS_LIVE_PIPELINE ? (initial_pair+sequence-1u)%3u :
        (display&4u) ? ((display&3u)+1u)%3u : 0u;
    if((display&4u) && (display&3u)==pair)Stop("inference would overwrite displayed bank");
    demo[1]=pair;
    const uintptr_t input_address=demo[2],output_address=demo[3];
    if(input_address!=input_banks[pair] || output_address!=output_banks[pair])
      Stop("live bank address mismatch");
    iris_live_result[0]=1;
    const uint32_t rejects=demo[8];
    if(!IRIS_LIVE_PIPELINE || sequence==1)start_capture(pair);
    else if(demo[20]!=pair)Stop("prefetched camera bank mismatch");
    deadline=clint_getTime(BSP_CLINT)+2ull*SYSTEM_CLINT_HZ;
    while(demo[0]&1u)
      if(clint_getTime(BSP_CLINT)>deadline)Stop("camera capture timeout");
    if(!(demo[0]&2u) || (demo[0]&4u)) {
      if(IRIS_LIVE_PIPELINE)Stop("prefetched camera frame incomplete");
      MicroPrintf("IRIS LIVE: incomplete camera frame; retry\n\r");
      continue;
    }
    if(demo[10] || demo[11])Stop("camera payload audit failed");
    demo[18]=4u|pair;
    if(demo[18]!=(4u|pair) || demo[8]!=rejects)Stop("inference lease rejected");

    IrisInterpreter* cur_interpreter = (active_model == 0) ? &interpreter0 : &interpreter1;
#if IRIS_RAIN_BACKEND
    auto* cur_live_input = (active_model == 0) ? live_input0 : live_input1;
    auto* cur_live_output = (active_model == 0) ? live_output0 : live_output1;
    cur_live_input->data.int8=reinterpret_cast<int8_t*>(input_address);
    cur_live_output->data.int8=reinterpret_cast<int8_t*>(output_address);
    auto* input = cur_interpreter->input(0);
    auto* output = cur_interpreter->output(0);
    input->data.int8=cur_live_input->data.int8;
    output->data.int8=cur_live_output->data.int8;
#else
    auto* input = cur_interpreter->input(0);
    auto* output = cur_interpreter->output(0);
    if(!IrisCopyTensorDma(input_address,reinterpret_cast<uintptr_t>(input->data.int8),
                          kIrisHeight,kIrisWidth,kIrisChannels))Stop("input DMA failed");
#endif
    // The third bank is distinct from the displayed and leased banks. Its
    // capture can finish while all 23 operators process the current tensor.
    if(IRIS_LIVE_PIPELINE && !IRIS_LIVE_SNAPSHOT)start_capture((pair+1u)%3u);
    IrisFlushCpuDataCache();IrisResetVendorCache();
    iris_live_result[0]=2;
    profiler.Reset();
    const uint64_t begin=clint_getTime(BSP_CLINT);
    if(cur_interpreter->Invoke()!=kTfLiteOk)Stop("live Invoke failed");
    const uint64_t ticks=clint_getTime(BSP_CLINT)-begin;
    IrisFlushCpuDataCache();IrisResetVendorCache();
#if !IRIS_RAIN_BACKEND
    if(!IrisCopyTensorDma(reinterpret_cast<uintptr_t>(output->data.int8),output_address,
                          kIrisHeight,kIrisWidth,kIrisChannels))Stop("output DMA failed");
#endif
    if (need_dequant_remap[active_model]) {
      uint32_t* out32 = reinterpret_cast<uint32_t*>(output_address);
      const size_t word_count = (kIrisHeight * kIrisWidth * kIrisChannels) / 4;
      const int8_t* lut = dequant_lut[active_model];
      for (size_t i = 0; i < word_count; ++i) {
        uint32_t w = out32[i];
        uint32_t b0 = static_cast<uint8_t>(lut[w & 0xFF]);
        uint32_t b1 = static_cast<uint8_t>(lut[(w >> 8) & 0xFF]);
        uint32_t b2 = static_cast<uint8_t>(lut[(w >> 16) & 0xFF]);
        uint32_t b3 = static_cast<uint8_t>(lut[(w >> 24) & 0xFF]);
        out32[i] = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24);
      }
      IrisFlushCpuDataCache();
    }
    demo[18]=pair;  // Release the inference lease before requesting display.
    if(demo[18]&4u)Stop("inference lease release failed");
    iris_live_result[1]=sequence;iris_live_result[2]=input_address;
    iris_live_result[3]=output_address;iris_live_result[4]=output->bytes;
    iris_live_result[5]=static_cast<uint32_t>(ticks);iris_live_result[6]=static_cast<uint32_t>(ticks>>32);
    demo[1]=pair;  // Prefetch selected another capture bank; commit this result.
    demo[0]=2u;
    deadline=clint_getTime(BSP_CLINT)+SYSTEM_CLINT_HZ;
    while(demo[0]&32u)
      if(clint_getTime(BSP_CLINT)>deadline)Stop("display commit timeout");
    if(demo[8]!=rejects || demo[19]!=(4u|pair))Stop("display commit rejected");
    for(unsigned i=7;i<12;++i)iris_live_result[i]=demo[i-3];
    const uint64_t committed=clint_getTime(BSP_CLINT);
    const uint32_t frame_period=previous_commit ? static_cast<uint32_t>(committed-previous_commit) : 0;
    if(previous_commit) {
      const uint64_t centifps=100ull*SYSTEM_CLINT_HZ/(committed-previous_commit);
      demo[22]=static_cast<uint32_t>(centifps>4095 ? 4095 : centifps);
    }
    previous_commit=committed;
    iris_live_result[0]=3;IrisFlushCpuDataCache();
    // Profile warm frame
    if(sequence==(IRIS_RAIN_BACKEND ? 3u : 1u))profiler.Print();
#if IRIS_RAIN_BACKEND
    if(!IrisRainLogFrame(sequence,pair,static_cast<unsigned>(ticks),demo[4],demo[5],demo[6],demo[7],demo[8],frame_period))
      Stop("live log queue overflow");
#else
    MicroPrintf("IRIS LIVE frame=%u pair=%u Invoke_ticks=%u displayed=%u captures=%u underflow=%u readerr=%u rejects=%u\n\r",
       sequence,pair,static_cast<unsigned>(ticks),demo[4],demo[5],demo[6],demo[7],demo[8]);
#endif
  }
#else
  // Non-live static fixture mode
  Stop("non-live static fixture mode not supported with dual models");
#endif
}
