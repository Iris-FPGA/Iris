#include <stdint.h>
#include "iris_resize.h"
#include "riscv.h"
#include "bsp.h"
#include "clint.h"
#include "platform/tinyml/ops/cache.h"
#include "platform/tinyml/accel_settings.h"
#include "tensorflow/lite/c/builtin_op_data.h"
#include "tensorflow/lite/micro/kernels/kernel_util.h"
#include "tensorflow/lite/kernels/kernel_util.h"
#include "tensorflow/lite/micro/micro_error_reporter.h"

namespace {
uint32_t Cap() { return opcode_R(CUSTOM0,0,64,0,0); }
uint32_t Addresses(uint32_t src,uint32_t dst) { return opcode_R(CUSTOM0,1,64,src,dst); }
uint32_t Dimensions(uint32_t h,uint32_t w) { return opcode_R(CUSTOM0,2,64,h,w); }
uint32_t Channels(uint32_t c) { return opcode_R(CUSTOM0,3,64,c,0); }
uint32_t Start() { return opcode_R(CUSTOM0,4,64,0,0); }
uint32_t Status() { return opcode_R(CUSTOM0,5,64,0,0); }
uint32_t Abort() { return opcode_R(CUSTOM0,6,64,0,0); }
TfLiteStatus Prepare(TfLiteContext* c,TfLiteNode* n) {
  TF_LITE_ENSURE_EQ(c,tflite::NumInputs(n),2);
  TF_LITE_ENSURE_EQ(c,tflite::NumOutputs(n),1);
  const auto* i=tflite::GetInput(c,n,0);
  const auto* size=tflite::GetInput(c,n,1);
  const auto* o=tflite::GetOutput(c,n,0);
  const auto* opts=static_cast<const TfLiteResizeNearestNeighborParams*>(n->builtin_data);
  TF_LITE_ENSURE(c,opts && !opts->align_corners && !opts->half_pixel_centers);
  TF_LITE_ENSURE(c,i->type==kTfLiteInt8 && o->type==kTfLiteInt8);
  TF_LITE_ENSURE(c,i->dims->size==4 && o->dims->size==4);
  TF_LITE_ENSURE(c,i->dims->data[0]==1 && o->dims->data[0]==1);
  TF_LITE_ENSURE(c,i->dims->data[1]>0 && i->dims->data[1]<=1024);
  TF_LITE_ENSURE(c,i->dims->data[2]>0 && i->dims->data[2]<=1024);
  const int ch=i->dims->data[3];
  TF_LITE_ENSURE(c,ch==4 || ch==8 || ch==16 || ch==32);
  TF_LITE_ENSURE(c,(i->dims->data[2]*ch)%16==0);
  TF_LITE_ENSURE(c,o->dims->data[1]==2*i->dims->data[1] &&
                  o->dims->data[2]==2*i->dims->data[2] && o->dims->data[3]==ch);
  TF_LITE_ENSURE(c,size->type==kTfLiteInt32 && tflite::IsConstantTensor(size) &&
                  size->dims->size==1 && size->dims->data[0]==2);
  TF_LITE_ENSURE(c,size->data.i32[0]==o->dims->data[1] && size->data.i32[1]==o->dims->data[2]);
  TF_LITE_ENSURE(c,i->params.scale==o->params.scale && i->params.zero_point==o->params.zero_point);
  return kTfLiteOk;
}
TfLiteStatus Eval(TfLiteContext* c,TfLiteNode* n) {
  const auto* i=tflite::micro::GetEvalInput(c,n,0);
  auto* o=tflite::micro::GetEvalOutput(c,n,0);
  const uintptr_t src=reinterpret_cast<uintptr_t>(i->data.int8),dst=reinterpret_cast<uintptr_t>(o->data.int8);
  TF_LITE_ENSURE(c,!(src%16) && !(dst%16));
  TF_LITE_ENSURE(c,Cap()==0x49520101u);
  asm volatile("fence rw,rw" ::: "memory");
  cache_reset();
  TF_LITE_ENSURE(c,Addresses(src,dst)==0);
  TF_LITE_ENSURE(c,Dimensions(i->dims->data[1],i->dims->data[2])==0);
  TF_LITE_ENSURE(c,Channels(i->dims->data[3])==0);
  TF_LITE_ENSURE(c,Start()==0);
  const uint64_t begin=clint_getTime(BSP_CLINT);
  while (true) {
    const uint32_t status=Status();
    if (!(status&1)) {
      TF_LITE_ENSURE(c,(status&6)==2);
      asm volatile("fence rw,rw" ::: "memory");
      cache_reset();
      layer_mode[0]="IRIS_RESIZE_HW";
      return kTfLiteOk;
    }
    if (clint_getTime(BSP_CLINT)-begin > SYSTEM_CLINT_HZ) {
      Abort();
      // Do not reuse an arena until the published write has drained. Return
      // error only after idle; a broken memory bus remains fail-closed here.
      while (Status()&1) {}
      TF_LITE_KERNEL_LOG(c,"Iris resize timeout");
      return kTfLiteError;
    }
  }
}
}
TfLiteRegistration IrisRegisterResize2x() {
  return {nullptr,nullptr,Prepare,Eval,nullptr,0,nullptr,0};
}
#if IRIS_STRICT_DISPATCH
namespace tflite { namespace ops { namespace micro {
TfLiteRegistration Register_RESIZE_NEAREST_NEIGHBOR() { return IrisRegisterResize2x(); }
}}}
#endif
