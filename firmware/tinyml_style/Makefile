.DEFAULT_GOAL := all
IRIS_ROOT := $(abspath ../..)
TINYML_ROOT ?= $(abspath $(IRIS_ROOT)/../tinyml)
VENDOR_STANDALONE := $(TINYML_ROOT)/tinyml_hello_world/Ti60F225_tinyml_hello_world/embedded_sw/SapphireSoc/software/standalone
VENDOR_SRC := $(VENDOR_STANDALONE)/tinyml_ypd/src
MODEL_DIR := $(IRIS_ROOT)/iris_ws/RISC-V
OBJDIR := build
HOST_CXX ?= g++
STRICT_DISPATCH ?= 0
ARENA_BYTES ?= 2097152
EXPECTED_TINYML_REVISION := 96886fa0c73e25e6218db7d0863f84677cf65138
TINYML_REVISION := $(shell git -C $(TINYML_ROOT) rev-parse HEAD 2>/dev/null)
ifneq ($(TINYML_REVISION),$(EXPECTED_TINYML_REVISION))
$(error TINYML_ROOT must reference official tinyml revision $(EXPECTED_TINYML_REVISION); found $(TINYML_REVISION))
endif

ifeq ($(STRICT_DISPATCH),1)
$(error Dispatch-only unavailable: hardware resize and fail-closed Conv/Add dispatch must be implemented first)
endif

.PHONY: check-model
check-model: build/check-model
	$<
build/check-model: Makefile check_model.cc src/model.cc src/model_contract.h $(MODEL_DIR)/one_last_kiss_0_int8_model_data.cc $(MODEL_DIR)/one_last_kiss_0_int8_model_data.h
	@mkdir -p build
	$(HOST_CXX) -std=c++17 -I$(VENDOR_SRC) -I$(VENDOR_SRC)/tensorflow/third_party/flatbuffers/include -I$(MODEL_DIR) check_model.cc src/model.cc -o $@

ifneq ($(MAKECMDGOALS),check-model)
STANDALONE ?= $(VENDOR_STANDALONE)
ifeq ($(wildcard $(STANDALONE)/common/bsp.mk),)
$(error Generated Sapphire BSP missing; set STANDALONE and BSP_PATH, see README.md)
endif
ifeq ($(strip $(DDR_BASE)),)
$(error Set DDR_BASE to the board-reserved CPU-visible external DDR base)
endif
ifeq ($(strip $(DDR_BYTES)),)
$(error Set DDR_BYTES to the size of that reserved DDR window)
endif

DEBUG := no
DEBUG_OG := no
BENCH := yes
RISCV_BIN ?= riscv-none-elf-
LDSCRIPT := $(CURDIR)/ddr.ld
include $(STANDALONE)/common/bsp.mk
include $(STANDALONE)/common/riscv64-unknown-elf.mk
# The supplied Ti60 archive is RV32IM soft-float, regardless of compiler prefix.
ifneq ($(MABI),ilp32)
$(error tinyml_lib.a requires ilp32 soft-float; generated BSP selected $(MABI))
endif
RISCV_CXX := $(RISCV_BIN)g++
INCLUDES := -Isrc -I$(MODEL_DIR) -I$(VENDOR_SRC) -I$(VENDOR_SRC)/platform \
 -I$(VENDOR_SRC)/platform/interrupt -I$(VENDOR_SRC)/platform/misc -I$(VENDOR_SRC)/platform/tinyml \
 -I$(VENDOR_SRC)/tensorflow/third_party/flatbuffers/include \
 -I$(VENDOR_SRC)/tensorflow/third_party/gemmlowp -I$(VENDOR_SRC)/tensorflow/third_party/ruy \
 -I$(STANDALONE)/include -I$(STANDALONE)/driver
CFLAGS += $(INCLUDES) -DOPTIMIZE_X -funroll-loops -mdiv -ffunction-sections -fdata-sections \
 -fno-common -fomit-frame-pointer -fno-builtin -g -MMD -MP \
 -DTF_LITE_STATIC_MEMORY -DTF_LITE_USE_GLOBAL_CMATH_FUNCTIONS \
 -DTF_LITE_USE_GLOBAL_MIN -DTF_LITE_USE_GLOBAL_MAX -DTF_LITE_DISABLE_X86_NEON \
 -DIRIS_STRICT_DISPATCH=$(STRICT_DISPATCH) -DIRIS_ARENA_BYTES=$(ARENA_BYTES)
CXXFLAGS += $(CFLAGS) -std=c++11 -fstrict-aliasing -fno-rtti -fno-exceptions \
 -fno-threadsafe-statics -fno-use-cxa-atexit

# Same source groups as the official tinyml_ypd Makefile; no example models/main.
VENDOR_GROUPS := platform/*/*.cc platform/*/*.c platform/*/*/*.cc platform/*/*/*.c \
 tensorflow/lite/*.c tensorflow/lite/c/*.c tensorflow/lite/core/api/*.cc \
 tensorflow/lite/kernels/*.cc tensorflow/lite/kernels/internal/*.cc \
 tensorflow/lite/kernels/internal/optimized/*.cc tensorflow/lite/kernels/internal/reference/*.cc \
 tensorflow/lite/kernels/internal/reference/integer_ops/*.cc tensorflow/lite/micro/*.cc \
 tensorflow/lite/micro/kernels/*.cc tensorflow/lite/micro/memory_planner/*.cc tensorflow/lite/schema/*.cc
VENDOR_SRCS := $(foreach group,$(VENDOR_GROUPS),$(wildcard $(VENDOR_SRC)/$(group)))
SRCS := $(abspath src/main.cc src/model.cc) $(VENDOR_SRCS) \
 $(STANDALONE)/common/start.S $(STANDALONE)/common/trap.S $(STANDALONE)/common/syscalls.s
$(foreach source,$(SRCS),$(if $(wildcard $(source)),,$(error Required vendor/BSP source missing: $(source))))
OBJS := $(addprefix build/obj/,$(addsuffix .o,$(SRCS)))
LIB := $(VENDOR_STANDALONE)/common/tinyml_lib.a
LDFLAGS += -specs=nosys.specs -nostartfiles \
 -Wl,--defsym=__iris_ddr_base=$(DDR_BASE),--defsym=__iris_ddr_bytes=$(DDR_BYTES) \
 -Wl,-Bstatic,-T,$(LDSCRIPT),-Map,build/tinyml_style.map,--gc-sections,--print-memory-usage

.PHONY: all FORCE
all: build/tinyml_style.elf
	$(RISCV_OBJCOPY) -O ihex $< build/tinyml_style.hex
	$(RISCV_OBJCOPY) -O binary $< build/tinyml_style.bin
build/tinyml_style.elf: $(OBJS) $(LIB) ddr.ld Makefile build/config.txt
	$(RISCV_CXX) $(OBJS) $(LDFLAGS) -Wl,--start-group $(LIB) -lc -lm -lgcc -Wl,--end-group -o $@

# Preserve a build manifest and invalidate objects when the BSP or flags change.
build/config.txt: FORCE
	@mkdir -p build
	@printf '%s\n' 'tinyml=$(TINYML_REVISION)' 'BSP_PATH=$(BSP_PATH)' 'CC=$(RISCV_CC)' 'CXX=$(RISCV_CXX)' 'CFLAGS=$(CFLAGS)' 'CXXFLAGS=$(CXXFLAGS)' 'LDFLAGS=$(LDFLAGS)' > $@.tmp
	@$(RISCV_CXX) --version >> $@.tmp
	@sha256sum $(LIB) $(MODEL_DIR)/one_last_kiss_0_int8_model_data.cc $(BSP_PATH)/include/soc.mk $(BSP_PATH)/include/soc.h >> $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

build/obj/%.cc.o: %.cc
	@mkdir -p $(dir $@)
	$(RISCV_CXX) $(CXXFLAGS) -c $< -o $@
build/obj/%.c.o: %.c
	@mkdir -p $(dir $@)
	$(RISCV_CC) $(CFLAGS) -c $< -o $@
build/obj/%.S.o: %.S
	@mkdir -p $(dir $@)
	$(RISCV_CC) $(CFLAGS) -c $< -o $@
build/obj/%.s.o: %.s
	@mkdir -p $(dir $@)
	$(RISCV_CC) $(CFLAGS) -c $< -o $@
$(OBJS): Makefile build/config.txt
-include $(OBJS:.o=.d)
endif
