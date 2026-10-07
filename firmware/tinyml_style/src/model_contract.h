#ifndef IRIS_MODEL_CONTRACT_H
#define IRIS_MODEL_CONTRACT_H

#include "model_config.h"
#include "tensorflow/lite/schema/schema_generated.h"

// Shared by the host check and firmware; reject options the vendor resize ignores.
inline bool IrisModelContract(const unsigned char* bytes = IrisModelData,
                              size_t length = IrisModelLength) {
  flatbuffers::Verifier verifier(bytes, length);
  if (!tflite::VerifyModelBuffer(verifier)) return false;
  const auto* model = tflite::GetModel(bytes);
  if (model->version() != 3 || !model->subgraphs() || model->subgraphs()->size() != 1 ||
      !model->operator_codes()) return false;
  const auto* graph = model->subgraphs()->Get(0);
  if (!graph->inputs() || !graph->outputs() || !graph->tensors() || !graph->operators() ||
      graph->inputs()->size() != 1 || graph->outputs()->size() != 1) return false;
  for (int index : {graph->inputs()->Get(0), graph->outputs()->Get(0)}) {
    if (index < 0 || static_cast<unsigned>(index) >= graph->tensors()->size()) return false;
    const auto* tensor = graph->tensors()->Get(index);
    const auto* shape = tensor->shape();
    if (tensor->type() != tflite::TensorType_INT8 || !shape || shape->size() != 4 ||
        shape->Get(0) != 1 || shape->Get(1) != kIrisHeight ||
        shape->Get(2) != kIrisWidth || shape->Get(3) != kIrisChannels) return false;
  }
  const auto* input_q = graph->tensors()->Get(graph->inputs()->Get(0))->quantization();
  if (!input_q || !input_q->scale() || !input_q->zero_point() ||
      input_q->scale()->size() != 1 || input_q->zero_point()->size() != 1 ||
      input_q->scale()->Get(0) != 1.0f || input_q->zero_point()->Get(0) != -128)
    return false;
  int conv = 0, add = 0, resize = 0;
  for (const auto* op : *graph->operators()) {
    if (!op->inputs() || !op->outputs() || op->outputs()->size() != 1)
      return false;
    const auto tensor = [&](int index) -> const tflite::Tensor* {
      if (index < 0 || static_cast<unsigned>(index) >= graph->tensors()->size())
        return nullptr;
      return graph->tensors()->Get(index);
    };
    const auto* result = tensor(op->outputs()->Get(0));
    if (!result || result->type() != tflite::TensorType_INT8) return false;
    if (op->opcode_index() >= model->operator_codes()->size()) return false;
    const auto* code = model->operator_codes()->Get(op->opcode_index());
    switch (code->builtin_code()) {
      case tflite::BuiltinOperator_CONV_2D: {
        if (code->version() != 3 || op->inputs()->size() != 3) return false;
        const auto* input = tensor(op->inputs()->Get(0));
        const auto* filter = tensor(op->inputs()->Get(1));
        const auto* bias = tensor(op->inputs()->Get(2));
        if (!input || !filter || !bias || input->type() != tflite::TensorType_INT8 ||
            filter->type() != tflite::TensorType_INT8 || bias->type() != tflite::TensorType_INT32)
          return false;
        ++conv;
        break;
      }
      case tflite::BuiltinOperator_ADD: {
        if (code->version() != 2 || op->inputs()->size() != 2) return false;
        for (int index : *op->inputs()) {
          const auto* operand = tensor(index);
          if (!operand || operand->type() != tflite::TensorType_INT8 ||
              !operand->shape() || !result->shape() ||
              operand->shape()->size() != result->shape()->size()) return false;
          for (unsigned d = 0; d < result->shape()->size(); ++d)
            if (operand->shape()->Get(d) != result->shape()->Get(d)) return false;
        }
        ++add;
        break;
      }
      case tflite::BuiltinOperator_RESIZE_NEAREST_NEIGHBOR: {
        const auto* options = op->builtin_options_as_ResizeNearestNeighborOptions();
        if (code->version() != 2 || op->inputs()->size() != 2 || !options || options->align_corners() ||
            options->half_pixel_centers()) return false;
        const auto* in = tensor(op->inputs()->Get(0));
        const auto* out = result;
        if (!in || !in->shape() || !out->shape() || in->type() != tflite::TensorType_INT8 || out->type() != in->type() ||
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
  return conv == kIrisConvCount && add == kIrisAddCount && resize == 2;
}
#endif
