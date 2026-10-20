.DEFAULT_GOAL := all
IRIS_ROOT := $(abspath ../..)
TINYML_ROOT ?= $(abspath $(IRIS_ROOT)/../tinyml)
VENDOR_STANDALONE := $(TINYML_ROOT)/tinyml_hello_world/Ti60F225_tinyml_hello_world/embedded_sw/SapphireSoc/software/standalone
VENDOR_SRC := $(VENDOR_STANDALONE)/tinyml_ypd/src
MODEL_PROFILE ?= original
LIVE_DEMO ?= 0
LIVE_SNAPSHOT ?= 0
LIVE_PIPELINE ?= 0
RAIN_BACKEND ?= 0
RAIN_BACKEND_DIR ?= $(CURDIR)/build/rain_row_backend
ifeq ($(RAIN_BACKEND),1)
ifneq ($(MODEL_PROFILE),rain_princess)
$(error RAIN_BACKEND requires MODEL_PROFILE=rain_princess)
endif
ifeq ($(wildcard $(RAIN_BACKEND_DIR)/rain_backend_model.h),)
$(error Generate rain_backend_model.h with .script/compile-rain-backend.py first)
endif
endif
MODEL_RAIN_PRINCESS := 0
ifeq ($(MODEL_PROFILE),rgba640)
MODEL_DIR ?= $(IRIS_ROOT)/iris_ws/RISC-V/rgba640
MODEL_STEM := c448_lowdec_skip_r0_refined_rgba_640_int8
MODEL_RGBA := 1
ARENA_BYTES ?= 4194304
else ifeq ($(MODEL_PROFILE),original)
MODEL_DIR ?= $(IRIS_ROOT)/iris_ws/RISC-V
MODEL_STEM := one_last_kiss_0_int8
MODEL_RGBA := 0
else ifeq ($(MODEL_PROFILE),rain_princess)
MODEL_DIR ?= $(IRIS_ROOT)/iris_ws/RISC-V/rain_princess
MODEL_STEM := rain_princess_int8
MODEL_RGBA := 0
MODEL_RAIN_PRINCESS := 1
ifeq ($(LIVE_DEMO),1)
OBJDIR ?= build/rain_princess_live
else
OBJDIR ?= build/rain_princess
endif
STRICT_DISPATCH ?= 1
else
$(error Unsupported MODEL_PROFILE $(MODEL_PROFILE); choose original, rgba640 or rain_princess)
endif
OBJDIR ?= build
HOST_CXX ?= g++
STRICT_DISPATCH ?= 0
ARENA_BYTES ?= 2097152
EXPECTED_TINYML_REVISION := 96886fa0c73e25e6218db7d0863f84677cf65138
TINYML_REVISION := $(shell git -C $(TINYML_ROOT) rev-parse HEAD 2>/dev/null)
ifneq ($(TINYML_REVISION),$(EXPECTED_TINYML_REVISION))
$(error TINYML_ROOT must reference official tinyml revision $(EXPECTED_TINYML_REVISION); found $(TINYML_REVISION))
endif

.PHONY: check-model
check-model: $(OBJDIR)/check-model-$(MODEL_PROFILE)
	$<
$(OBJDIR)/check-model-$(MODEL_PROFILE): Makefile check_model.cc src/model.cc src/model_contract.h src/model_config.h $(MODEL_DIR)/$(MODEL_STEM)_model_data.cc $(MODEL_DIR)/$(MODEL_STEM)_model_data.h
	@mkdir -p $(OBJDIR)
	$(HOST_CXX) -std=c++17 -DIRIS_MODEL_RGBA=$(MODEL_RGBA) -DIRIS_MODEL_RAIN_PRINCESS=$(MODEL_RAIN_PRINCESS) -I$(VENDOR_SRC) -I$(VENDOR_SRC)/tensorflow/third_party/flatbuffers/include -I$(MODEL_DIR) check_model.cc src/model.cc -o $@

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
INCLUDES := -Isrc/overrides -Isrc -I$(MODEL_DIR) -I$(VENDOR_SRC) -I$(VENDOR_SRC)/platform \
 -I$(VENDOR_SRC)/platform/interrupt -I$(VENDOR_SRC)/platform/misc -I$(VENDOR_SRC)/platform/tinyml \
 -I$(VENDOR_SRC)/tensorflow/third_party/flatbuffers/include \
 -I$(VENDOR_SRC)/tensorflow/third_party/gemmlowp -I$(VENDOR_SRC)/tensorflow/third_party/ruy \
 -I$(STANDALONE)/include -I$(STANDALONE)/driver
CFLAGS += $(INCLUDES) -DOPTIMIZE_X -funroll-loops -mdiv -ffunction-sections -fdata-sections \
 -fno-common -fomit-frame-pointer -fno-builtin -g -MMD -MP \
 -DTF_LITE_STATIC_MEMORY -DTF_LITE_USE_GLOBAL_CMATH_FUNCTIONS \
 -DTF_LITE_USE_GLOBAL_MIN -DTF_LITE_USE_GLOBAL_MAX -DTF_LITE_DISABLE_X86_NEON \
 -DIRIS_TML_PROFILER_EVENTS=24 \
 -DIRIS_STRICT_DISPATCH=$(STRICT_DISPATCH) -DIRIS_ARENA_BYTES=$(ARENA_BYTES) -DIRIS_MODEL_RGBA=$(MODEL_RGBA) -DIRIS_MODEL_RAIN_PRINCESS=$(MODEL_RAIN_PRINCESS) -DIRIS_LIVE_DEMO=$(LIVE_DEMO) -DIRIS_LIVE_SNAPSHOT=$(LIVE_SNAPSHOT) -DIRIS_LIVE_PIPELINE=$(LIVE_PIPELINE)
ifneq ($(strip $(VENDOR_CACHE_OVERRIDE)),)
CFLAGS += -DIRIS_VENDOR_CACHE_OVERRIDE=$(VENDOR_CACHE_OVERRIDE)
endif
CXXFLAGS += $(CFLAGS) -std=c++11 -fstrict-aliasing -fno-rtti -fno-exceptions \
 -fno-threadsafe-statics -fno-use-cxa-atexit
CFLAGS += -DIRIS_RAIN_BACKEND=$(RAIN_BACKEND) -I$(RAIN_BACKEND_DIR)
CXXFLAGS += -DIRIS_RAIN_BACKEND=$(RAIN_BACKEND) -I$(RAIN_BACKEND_DIR)

# Same source groups as the official tinyml_ypd Makefile; no example models/main.
VENDOR_GROUPS := platform/*/*.cc platform/*/*.c platform/*/*/*.cc platform/*/*/*.c \
 tensorflow/lite/*.c tensorflow/lite/c/*.c tensorflow/lite/core/api/*.cc \
 tensorflow/lite/kernels/*.cc tensorflow/lite/kernels/internal/*.cc \
 tensorflow/lite/kernels/internal/optimized/*.cc tensorflow/lite/kernels/internal/reference/*.cc \
 tensorflow/lite/kernels/internal/reference/integer_ops/*.cc tensorflow/lite/micro/*.cc \
 tensorflow/lite/micro/kernels/*.cc tensorflow/lite/micro/memory_planner/*.cc tensorflow/lite/schema/*.cc
VENDOR_SRCS := $(foreach group,$(VENDOR_GROUPS),$(wildcard $(VENDOR_SRC)/$(group)))
VENDOR_SRCS := $(filter-out $(VENDOR_SRC)/tensorflow/lite/micro/micro_interpreter.cc $(VENDOR_SRC)/tensorflow/lite/micro/micro_graph.cc,$(VENDOR_SRCS))
ifeq ($(STRICT_DISPATCH),1)
VENDOR_SRCS := $(filter-out $(VENDOR_SRC)/tensorflow/lite/micro/kernels/resize_nearest_neighbor.cc,$(VENDOR_SRCS))
endif
# The Efinity-generated standalone tree ships syscalls.c (not the syscalls.s
# assumed by the original README); same minimal newlib stubs.
SRCS := $(abspath src/main.cc src/model.cc src/crt_compat.cc src/iris_resize.cc src/overrides/tensorflow/lite/micro/micro_interpreter.cc src/overrides/tensorflow/lite/micro/micro_graph.cc) $(VENDOR_SRCS) \
 $(STANDALONE)/common/start.S $(STANDALONE)/common/trap.S $(STANDALONE)/common/syscalls.c
$(foreach source,$(SRCS),$(if $(wildcard $(source)),,$(error Required vendor/BSP source missing: $(source))))
ifeq ($(RAIN_BACKEND),1)
SRCS += $(abspath src/iris_rain_backend.cc)
endif
OBJS := $(addprefix $(OBJDIR)/obj/,$(addsuffix .o,$(SRCS)))
LIB := $(VENDOR_STANDALONE)/common/tinyml_lib.a
ifeq ($(RAIN_BACKEND),1)
LIB :=
endif
LDFLAGS += -specs=nosys.specs -nostartfiles \
 -Wl,--defsym=__iris_ddr_base=$(DDR_BASE),--defsym=__iris_ddr_bytes=$(DDR_BYTES) \
 -Wl,-Bstatic,-T,$(LDSCRIPT),-Map,$(OBJDIR)/tinyml_style.map,--gc-sections,--print-memory-usage

.PHONY: all FORCE
all: $(OBJDIR)/tinyml_style.elf
	$(RISCV_OBJCOPY) -O ihex $< $(OBJDIR)/tinyml_style.hex
	$(RISCV_OBJCOPY) -O binary $< $(OBJDIR)/tinyml_style.bin
$(OBJDIR)/tinyml_style.elf: $(OBJS) $(LIB) ddr.ld Makefile $(OBJDIR)/config.txt
	$(RISCV_CXX) $(OBJS) $(LDFLAGS) -Wl,--start-group $(LIB) -lc -lm -lgcc -Wl,--end-group -o $@

# Preserve a build manifest and invalidate objects when the BSP or flags change.
$(OBJDIR)/config.txt: FORCE
	@mkdir -p $(OBJDIR)
	@printf '%s\n' 'tinyml=$(TINYML_REVISION)' 'BSP_PATH=$(BSP_PATH)' 'CC=$(RISCV_CC)' 'CXX=$(RISCV_CXX)' 'CFLAGS=$(CFLAGS)' 'CXXFLAGS=$(CXXFLAGS)' 'LDFLAGS=$(LDFLAGS)' > $@.tmp
	@$(RISCV_CXX) --version >> $@.tmp
	@sha256sum $(LIB) $(MODEL_DIR)/$(MODEL_STEM)_model_data.cc $(BSP_PATH)/include/soc.mk $(BSP_PATH)/include/soc.h >> $@.tmp
	@cmp -s $@.tmp $@ && rm $@.tmp || mv $@.tmp $@

$(OBJDIR)/obj/%.cc.o: %.cc
	@mkdir -p $(dir $@)
	$(RISCV_CXX) $(CXXFLAGS) -c $< -o $@
$(OBJDIR)/obj/%.c.o: %.c
	@mkdir -p $(dir $@)
	$(RISCV_CC) $(CFLAGS) -c $< -o $@
$(OBJDIR)/obj/%.S.o: %.S
	@mkdir -p $(dir $@)
	$(RISCV_CC) $(CFLAGS) -c $< -o $@
$(OBJDIR)/obj/%.s.o: %.s
	@mkdir -p $(dir $@)
	$(RISCV_CC) $(CFLAGS) -c $< -o $@
$(OBJS): Makefile $(OBJDIR)/config.txt
-include $(OBJS:.o=.d)
endif
