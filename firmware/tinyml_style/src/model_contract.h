#ifndef IRIS_MODEL_CONTRACT_H
#define IRIS_MODEL_CONTRACT_H

#include "one_last_kiss_0_int8_model_data.h"
#include "tensorflow/lite/schema/schema_generated.h"

// Shared by the host check and firmware; reject options the vendor resize ignores.
inline bool IrisModelContract() {
  flatbuffers::Verifier verifier(one_last_kiss_0_int8_model_data,
                                 one_last_kiss_0_int8_model_data_len);
  if (!tflite::VerifyModelBuffer(verifier)) return false;
  const auto* model = tflite::GetModel(one_last_kiss_0_int8_model_data);
  if (model->version() != 3 || model->subgraphs()->size() != 1) return false;
  const auto* graph = model->subgraphs()->Get(0);
  if (graph->inputs()->size() != 1 || graph->outputs()->size() != 1) return false;
  for (int index : {graph->inputs()->Get(0), graph->outputs()->Get(0)}) {
    const auto* tensor = graph->tensors()->Get(index);
    const auto* shape = tensor->shape();
    if (tensor->type() != tflite::TensorType_INT8 || shape->size() != 4 ||
        shape->Get(0) != 1 || shape->Get(1) != 128 ||
        shape->Get(2) != 128 || shape->Get(3) != 3) return false;
  }
  const auto* input_q = graph->tensors()->Get(graph->inputs()->Get(0))->quantization();
  if (!input_q || !input_q->scale() || !input_q->zero_point() ||
      input_q->scale()->size() != 1 || input_q->zero_point()->size() != 1 ||
      input_q->scale()->Get(0) != 1.0f || input_q->zero_point()->Get(0) != -128)
    return false;
  int conv = 0, add = 0, resize = 0;
  for (const auto* op : *graph->operators()) {
    const auto* code = model->operator_codes()->Get(op->opcode_index());
    switch (code->builtin_code()) {
      case tflite::BuiltinOperator_CONV_2D:
        if (code->version() != 3) return false;
        ++conv;
        break;
      case tflite::BuiltinOperator_ADD:
        if (code->version() != 2) return false;
        ++add;
        break;
      case tflite::BuiltinOperator_RESIZE_NEAREST_NEIGHBOR: {
        const auto* options = op->builtin_options_as_ResizeNearestNeighborOptions();
        if (code->version() != 2 || !options || options->align_corners() ||
            options->half_pixel_centers()) return false;
        const auto* in = graph->tensors()->Get(op->inputs()->Get(0));
        const auto* out = graph->tensors()->Get(op->outputs()->Get(0));
        if (in->type() != tflite::TensorType_INT8 || out->type() != in->type() ||
            in->shape()->size() != 4 || out->shape()->size() != 4 ||
            in->shape()->Get(0) != 1 || out->shape()->Get(0) != 1 ||
            out->shape()->Get(1) != 2 * in->shape()->Get(1) ||
            out->shape()->Get(2) != 2 * in->shape()->Get(2) ||
            out->shape()->Get(3) != in->shape()->Get(3)) return false;
        const auto* iq = in->quantization();
        const auto* oq = out->quantization();
        if (!iq || !oq || !iq->scale() || !oq->scale() ||
            !iq->zero_point() || !oq->zero_point() ||
            iq->scale()->size() != 1 || oq->scale()->size() != 1 ||
            iq->zero_point()->size() != 1 || oq->zero_point()->size() != 1 ||
            iq->scale()->Get(0) != oq->scale()->Get(0) ||
            iq->zero_point()->Get(0) != oq->zero_point()->Get(0)) return false;
        ++resize;
        break;
      }
      default: return false;
    }
  }
  return conv == 16 && add == 5 && resize == 2;
}
#endif
