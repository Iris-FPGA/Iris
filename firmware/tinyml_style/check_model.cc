#include <cstdio>
#include "src/model_contract.h"

int main() {
  if (!IrisModelContract()) {
    std::fputs("FAIL: model does not meet the firmware contract\n", stderr);
    return 1;
  }
  std::printf("PASS: %u model bytes; INT8 NHWC 1x128x128x3; "
              "Conv2D v3 x16, Add v2 x5, ResizeNearestNeighbor v2 x2; "
              "2x resize with unchanged quantization and both flags false\n",
              one_last_kiss_0_int8_model_data_len);
}
