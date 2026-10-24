#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>
#include "src/model_contract.h"

int main(int argc, char** argv) {
  std::vector<unsigned char> external;
  const unsigned char* bytes = IrisModelData;
  size_t length = IrisModelLength;
  if (argc > 2) return 2;
  if (argc == 2) {
    std::ifstream file(argv[1], std::ios::binary);
    if (!file) return 2;
    external.assign(std::istreambuf_iterator<char>(file), {});
    bytes = external.data(); length = external.size();
  }
  if (!IrisModelContract(bytes, length)) {
    std::fputs("FAIL: model does not meet the firmware contract\n", stderr);
    return 1;
  }
  std::printf("PASS: %zu model bytes; INT8 NHWC 1x%dx%dx%d; "
              "Conv2D v3 x%d, Add v2 x%d, ResizeNearestNeighbor v2 x2; "
              "2x resize with unchanged quantization and both flags false\n",
              length, kIrisHeight, kIrisWidth, kIrisChannels, kIrisConvCount, kIrisAddCount);
}
