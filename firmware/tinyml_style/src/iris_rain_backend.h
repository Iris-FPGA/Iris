#pragma once
#include <stdint.h>
#include "tensorflow/lite/kernels/internal/types.h"
bool IrisRainConv(const tflite::ConvParams& params, const int32_t* multipliers,
                  const int32_t* shifts, const tflite::RuntimeShape& input_shape,
                  const int8_t* input, const tflite::RuntimeShape& filter_shape,
                  const int8_t* filter, const int32_t* bias,
                  const tflite::RuntimeShape& output_shape, int8_t* output);
bool IrisRainAdd(int size, const tflite::ArithmeticParams& params,
                 const int8_t* a, const int8_t* b, int8_t* output);
void IrisRainLogPump();
bool IrisRainLogFrame(uint32_t sequence,uint32_t pair,uint32_t ticks,
                      uint32_t displayed,uint32_t captures,uint32_t underflow,
                      uint32_t readerr,uint32_t rejects,uint32_t period_ticks);
