#if IRIS_RAIN_BACKEND
#include "iris_rain_backend.h"
#include "iris_dma_cache.h"
#include "model_config.h"
#include "rain_backend_model.h"
#include "riscv.h"
#include "bsp.h"
#include "clint.h"
#include "dispatch_guard.h"

// This backend polls its own completion and uses no vendor driver archive.
// Keep the platform interrupt entry fail-closed for an unexpected user IRQ.
extern "C" void ops_drv_intr() { IrisDispatchStop("unexpected polled-backend interrupt"); }
extern "C" void ops_unload() {}

namespace {
char log_buffer[256];
unsigned log_size=0,log_sent=0;
void LogText(const char* text) {
  while(*text && log_size<sizeof(log_buffer))log_buffer[log_size++]=*text++;
}
void LogNumber(uint32_t value) {
  char digits[10];unsigned count=0;
  do { digits[count++]=static_cast<char>('0'+value%10);value/=10; } while(value);
  while(count && log_size<sizeof(log_buffer))log_buffer[log_size++]=digits[--count];
}
uint32_t Capability() { return opcode_R(CUSTOM0,0,76,0,0); }
uint32_t Addresses(const void* src, void* dst) {
  return opcode_R(CUSTOM0,1,76,reinterpret_cast<uintptr_t>(src),reinterpret_cast<uintptr_t>(dst));
}
bool Config(unsigned index, uint32_t value) { return opcode_R(CUSTOM0,2,76,index,value)==0; }
bool Parameter(unsigned index, uint32_t value) { return opcode_R(CUSTOM0,3,76,index,value)==0; }
bool Execute(unsigned operation) {
  IrisFlushCpuDataCache();
  if(opcode_R(CUSTOM0,4,76,operation,0)!=0) return false;
  const uint64_t begin=clint_getTime(BSP_CLINT);
  for(;;) {
    IrisRainLogPump();
    const uint32_t status=opcode_R(CUSTOM0,5,76,0,0);
    if(!(status&1)) {
      IrisFlushCpuDataCache();
      return (status&6)==2;
    }
    if(clint_getTime(BSP_CLINT)-begin>SYSTEM_CLINT_HZ) {
      opcode_R(CUSTOM0,6,76,0,0);
      while(opcode_R(CUSTOM0,5,76,0,0)&1) {}
      return false;
    }
  }
}
}

void IrisRainLogPump() {
  unsigned available=uart_writeAvailability(BSP_UART_TERMINAL);
  while(log_sent<log_size && available--)uart_write(BSP_UART_TERMINAL,log_buffer[log_sent++]);
  if(log_sent==log_size)log_size=log_sent=0;
}
bool IrisRainLogFrame(uint32_t sequence,uint32_t pair,uint32_t ticks,
                      uint32_t displayed,uint32_t captures,uint32_t underflow,
                      uint32_t readerr,uint32_t rejects,uint32_t period_ticks) {
  IrisRainLogPump();
  if(log_size)return false;
  const char* labels[]={"IRIS LIVE frame="," pair="," Invoke_ticks="," displayed=",
                        " captures="," underflow="," readerr="," rejects="," period_ticks="};
  const uint32_t values[]={sequence,pair,ticks,displayed,captures,underflow,readerr,rejects,period_ticks};
  for(unsigned i=0;i<9;++i){LogText(labels[i]);LogNumber(values[i]);}
  LogText("\n\r");IrisRainLogPump();return true;
}

bool IrisRainConv(const tflite::ConvParams& p, const int32_t* mult,
                  const int32_t* shifts, const tflite::RuntimeShape& in,
                  const int8_t* input, const tflite::RuntimeShape& filter_shape,
                  const int8_t* filter, const int32_t* bias,
                  const tflite::RuntimeShape& out, int8_t* output) {
  if(Capability()!=0x49500101 || !bias || in.DimensionsCount()!=4 ||
     out.DimensionsCount()!=4 || filter_shape.DimensionsCount()!=4 ||
     in.Dims(0)!=1 || out.Dims(0)!=1 || filter_shape.Dims(0)!=out.Dims(3) ||
     filter_shape.Dims(1)!=3 || filter_shape.Dims(2)!=3 || filter_shape.Dims(3)!=in.Dims(3) ||
     p.dilation_width_factor!=1 || p.dilation_height_factor!=1 ||
     p.stride_height!=p.stride_width || (p.stride_width!=1 && p.stride_width!=2) ||
     p.padding_values.width!=(p.stride_width==1 ? 1 : 0) ||
     p.padding_values.height!=(p.stride_height==1 ? 1 : 0) ||
     out.Dims(1)*p.stride_height!=in.Dims(1) || out.Dims(2)*p.stride_width!=in.Dims(2) ||
     p.input_offset< -127 || p.input_offset>128 || p.output_offset< -128 || p.output_offset>127 ||
     p.quantized_activation_min< -128 || p.quantized_activation_max>127) return false;
  const IrisRainFilter* packed=nullptr;
  static bool validated[sizeof(iris_rain_filters)/sizeof(iris_rain_filters[0])] = {};
  for(unsigned n=0;n<sizeof(iris_rain_filters)/sizeof(iris_rain_filters[0]);++n) {
    const auto& candidate=iris_rain_filters[n];
    if(reinterpret_cast<const unsigned char*>(filter)!=IrisModelData+candidate.model_offset) continue;
    if(candidate.filter_bytes!=static_cast<unsigned>(filter_shape.FlatSize()))return false;
    if(!validated[n]) {
      uint32_t hash=0x811c9dc5;
      for(unsigned i=0;i<candidate.filter_bytes;++i)hash=(hash^static_cast<uint8_t>(filter[i]))*0x01000193;
      if(hash!=candidate.fnv)return false;
      validated[n]=true;
    }
    packed=&candidate;break;
  }
  if(!packed || Addresses(input,output)!=0) return false;
  const uint32_t quant=(static_cast<uint8_t>(-p.input_offset)) |
      (static_cast<uint32_t>(static_cast<uint8_t>(p.output_offset))<<8) |
      (static_cast<uint32_t>(static_cast<uint8_t>(p.quantized_activation_min))<<16) |
      (static_cast<uint32_t>(static_cast<uint8_t>(p.quantized_activation_max))<<24);
  const uint32_t values[]={static_cast<uint32_t>(in.Dims(2)),static_cast<uint32_t>(in.Dims(1)),
      static_cast<uint32_t>(in.Dims(3)),static_cast<uint32_t>(out.Dims(3)),static_cast<uint32_t>(p.stride_width),
      reinterpret_cast<uintptr_t>(iris_rain_weights+packed->packed_offset),packed->bytes,quant};
  for(unsigned i=0;i<8;++i)if(!Config(i,values[i]))return false;
  for(unsigned i=0;i<32;++i) {
    const bool present=i<static_cast<unsigned>(out.Dims(3));
    if(present && (mult[i]<0 || shifts[i]<-31 || shifts[i]>7))return false;
    if(!Parameter(i,present ? bias[i] : 0) || !Parameter(i+32,present ? mult[i] : 0) ||
       !Parameter(i+64,present ? shifts[i] : 0))return false;
  }
  const bool ok=Execute(0);
  if(ok)layer_mode[0]="IRIS_ROW_CONV";
  return ok;
}

bool IrisRainAdd(int size, const tflite::ArithmeticParams& p,
                 const int8_t* a, const int8_t* b, int8_t* output) {
  if(Capability()!=0x49500101 || size<=0 || Addresses(a,output)!=0)return false;
  const uint32_t values[]={reinterpret_cast<uintptr_t>(b),static_cast<uint32_t>(size),
      static_cast<uint32_t>(p.input1_offset),static_cast<uint32_t>(p.input2_offset),
      static_cast<uint32_t>(p.output_offset),static_cast<uint32_t>(p.input1_multiplier),
      static_cast<uint32_t>(p.input1_shift),static_cast<uint32_t>(p.input2_multiplier),
      static_cast<uint32_t>(p.input2_shift),static_cast<uint32_t>(p.output_multiplier),
      static_cast<uint32_t>(p.output_shift),static_cast<uint32_t>(p.left_shift),
      static_cast<uint32_t>(p.quantized_activation_min),static_cast<uint32_t>(p.quantized_activation_max)};
  for(unsigned i=0;i<14;++i)if(!Config(i+8,values[i]))return false;
  const bool ok=Execute(1);
  if(ok)layer_mode[0]="IRIS_ROW_ADD";
  return ok;
}
#endif
