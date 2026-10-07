#ifndef IRIS_MODEL_CONFIG_H
#define IRIS_MODEL_CONFIG_H

#ifndef IRIS_MODEL_RGBA
#define IRIS_MODEL_RGBA 0
#endif

#if IRIS_MODEL_RGBA
#include "c448_lowdec_skip_r0_refined_rgba_640_int8_model_data.h"
#define IrisModelData c448_lowdec_skip_r0_refined_rgba_640_int8_model_data
#define IrisModelLength c448_lowdec_skip_r0_refined_rgba_640_int8_model_data_len
#define IRIS_MODEL_SOURCE "c448_lowdec_skip_r0_refined_rgba_640_int8_model_data.cc"
constexpr int kIrisHeight = 480, kIrisWidth = 640, kIrisChannels = 4;
constexpr int kIrisConvCount = 6, kIrisAddCount = 2;
#else
#include "one_last_kiss_0_int8_model_data.h"
#define IrisModelData one_last_kiss_0_int8_model_data
#define IrisModelLength one_last_kiss_0_int8_model_data_len
#define IRIS_MODEL_SOURCE "one_last_kiss_0_int8_model_data.cc"
constexpr int kIrisHeight = 128, kIrisWidth = 128, kIrisChannels = 3;
constexpr int kIrisConvCount = 16, kIrisAddCount = 5;
#endif
#endif
