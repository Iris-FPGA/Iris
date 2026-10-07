#ifndef IRIS_RESIZE_H
#define IRIS_RESIZE_H
#include <stdint.h>
#include "tensorflow/lite/c/common.h"
TfLiteRegistration IrisRegisterResize2x();
// Transport only: no quantization, resizing or CPU pixel processing.
bool IrisCopyTensorDma(uintptr_t src, uintptr_t dst, uint32_t height, uint32_t width, uint32_t channels);
#endif
