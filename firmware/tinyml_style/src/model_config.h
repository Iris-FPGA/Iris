#ifndef IRIS_MODEL_CONFIG_H
#define IRIS_MODEL_CONFIG_H

#ifndef IRIS_MODEL_RGBA
#define IRIS_MODEL_RGBA 0
#endif
#ifndef IRIS_MODEL_RAIN_PRINCESS
#define IRIS_MODEL_RAIN_PRINCESS 0
#endif
#if IRIS_MODEL_RGBA && IRIS_MODEL_RAIN_PRINCESS
#error Select only one TinyML model profile
#endif

#if IRIS_MODEL_RGBA
#include "c448_lowdec_skip_r0_refined_rgba_640_int8_model_data.h"
#define IrisModelData c448_lowdec_skip_r0_refined_rgba_640_int8_model_data
#define IrisModelLength c448_lowdec_skip_r0_refined_rgba_640_int8_model_data_len
#define IRIS_MODEL_SOURCE "c448_lowdec_skip_r0_refined_rgba_640_int8_model_data.cc"
constexpr int kIrisHeight = 480, kIrisWidth = 640, kIrisChannels = 4;
constexpr int kIrisConvCount = 6, kIrisAddCount = 2;
#elif IRIS_MODEL_RAIN_PRINCESS
#include "rain_princess_int8_model_data.h"
#define IrisModelData rain_princess_int8_model_data
#define IrisModelLength rain_princess_int8_model_data_len
#define IRIS_MODEL_SOURCE "rain_princess_int8_model_data.cc"
constexpr int kIrisHeight = 128, kIrisWidth = 128, kIrisChannels = 3;
constexpr int kIrisConvCount = 16, kIrisAddCount = 5;
#else
#include "one_last_kiss_0_int8_model_data.h"
#define IrisModelData one_last_kiss_0_int8_model_data
#define IrisModelLength one_last_kiss_0_int8_model_data_len
#define IRIS_MODEL_SOURCE "one_last_kiss_0_int8_model_data.cc"
constexpr int kIrisHeight = 128, kIrisWidth = 128, kIrisChannels = 3;
constexpr int kIrisConvCount = 16, kIrisAddCount = 5;
#endif
#endif
