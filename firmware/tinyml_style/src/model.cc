#include "model_config.h"
// Preserve the generated model bytes while giving FlatBuffers/DMA alignment.
alignas(16) extern const unsigned char IrisModelData[];
#include IRIS_MODEL_SOURCE
