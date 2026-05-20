# =======================================================================
# URT platform/processor/toolchain configuration
#
# Shared between URT's own Makefile and downstream consumers (OpenWatt etc.).
# Anything that depends on which SoC/core/toolchain we're targeting lives here.
#
# Inputs (set by caller before include):
#   PLATFORM   - SoC/board (esp32-s3, bl808, bl618, bk7231n, rp2350, stm4xx, ...)
#                or OS name (windows, linux, ubuntu, freebsd) for host builds.
#                Auto-detected from `uname` if undefined.
#   PROCESSOR  - CPU core (e907, c906, lx7, cortex-m33, ...). Usually derived
#                from PLATFORM; override only for multi-core SoCs (e.g.
#                PROCESSOR=e907 for the BL808 M0 core).
#   CONFIG     - debug | release | unittest
#   COMPILER   - dmd | ldc | gdc. Auto-promoted to ldc for cross-compile.
#   URT_SRCDIR - path to URT's src/ tree. Default `src` (URT in-tree); outer
#                projects set this to e.g. `third_party/urt/src`.
#
# Outputs (resolved variables for caller to consume):
#   ARCH, OS, MARCH, MATTR, MABI, PROCESSOR, BUILDNAME, COMPILER, DC
#   DFLAGS               - augmented with triple, mattr, platform version flags
#   URT_SOURCES          - urt/**.d + urt/driver/<platform>/**.d (+ mbedtls.c on host)
#   BAREMETAL_DIR        - dir containing start.S etc. (empty on host targets)
#   BAREMETAL_SRCS       - basenames of asm/c sources for cross-gcc
#   BAREMETAL_GCC        - cross-gcc path
#   BAREMETAL_CFLAGS     - cross-gcc cflags (mcpu/march/mabi/mfpu)
#   BAREMETAL_LIBC/M/GCC - resolved newlib/picolibc/libgcc archive paths
#   ESPRESSIF_PATH, ESPRESSIF_XTENSA_BIN, ESPRESSIF_RISCV32_BIN
#   XTENSA_TWO_STAGE, ESPRESSIF_LLC, XTENSA_MATTR
#
# Caller still owns (NOT set here -- these are app-specific):
#   - BAREMETAL_LD: linker script (app memory map lives in the consumer's
#                   platforms/<x>/ld/*.ld tree).
#   - `-J` string-imports for app config dirs (consumer's platforms/<x>/).
#   - Vendor SDK roots and blob paths (BK_SDK_ROOT, ESP_PROJECT_DIR, ...).
#   - Final link/objcopy/packaging (containers, .bin, flashing, OTA).
#   - The build rule that actually produces $(TARGET).
# =======================================================================

URT_SRCDIR ?= src
CONFIG     ?= debug
COMPILER   ?= dmd

# Windows always sets env OS=Windows_NT -- normalize so OS-conditional blocks
# (driver/windows source selection, host triple) recognize it. Plain `:=` (not
# `override`) so platform blocks can still set OS=baremetal/freertos for cross.
ifeq ($(OS),Windows_NT)
    OS := windows
endif

# =======================================================================
# PLATFORM -- SoC/board identity
#
# Sets: BUILDNAME, PROCESSOR (default), OS, vendor version flags,
#       platform source paths, vendor-specific GCC wrappers (Xtensa).
# =======================================================================

# Normalize CI-friendly platform aliases before platform detection
ifeq ($(PLATFORM),bl808_m0)
    override PLATFORM := bl808
    PROCESSOR := e907
endif

ifeq ($(PLATFORM),esp8266)
    # ESP8266 has no FPU!
    BUILDNAME := esp8266
    PROCESSOR := l106
    OS = freertos
    XTENSA_GCC := xtensa-lx106-elf-gcc
else ifeq ($(PLATFORM),esp32)
    BUILDNAME := esp32
    PROCESSOR := lx6
    OS = freertos
    XTENSA_GCC := xtensa-esp32-elf-gcc
else ifeq ($(PLATFORM),esp32-s2)
    # Single-core LX7, 240MHz -- NO FPU, NO loops
    BUILDNAME := esp32-s2
    PROCESSOR := lx7
    OS = freertos
    XTENSA_GCC := xtensa-esp32s2-elf-gcc
else ifeq ($(PLATFORM),esp32-s3)
    # Dual-core LX7, 240MHz -- FPU, loops, hardware unaligned access
    BUILDNAME := esp32-s3
    PROCESSOR := lx7
    OS = freertos
    XTENSA_GCC := xtensa-esp32s3-elf-gcc
    MATTR = +fp,+loop
    DFLAGS := $(DFLAGS) -d-version=SupportUnaligned
else ifeq ($(PLATFORM),esp32-h2)
    BUILDNAME := esp32-h2
    PROCESSOR := e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c2)
    BUILDNAME := esp32-c2
    PROCESSOR := e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c3)
    BUILDNAME := esp32-c3
    PROCESSOR := e906
    OS = freertos
else ifeq ($(PLATFORM),esp32-c5)
    # RV32IMAC, 240MHz -- has atomics
    BUILDNAME := esp32-c5
    PROCESSOR := e907
    OS = freertos
else ifeq ($(PLATFORM),esp32-c6)
    # RV32IMAC, 160MHz -- has atomics
    BUILDNAME := esp32-c6
    PROCESSOR := e907
    OS = freertos
else ifeq ($(PLATFORM),esp32-p4)
    # HP core: RV32IMAFDCV, 400MHz
    BUILDNAME := esp32-p4
    PROCESSOR := esp32p4
    OS = freertos
else ifeq ($(PLATFORM),bl808)
    # BL808 multi-core SoC -- default to D0 (C906 RV64GC)
    # Override with PROCESSOR=e907 for M0 core (E907 RV32IMAFC)
    PROCESSOR ?= c906
    OS = baremetal
    ifeq ($(PROCESSOR),c906)
        BUILDNAME := bl808-d0
    else ifeq ($(PROCESSOR),e907)
        BUILDNAME := bl808-m0
    else
        $(error "BL808: unsupported PROCESSOR=$(PROCESSOR) (expected c906 or e907)")
    endif
else ifeq ($(PLATFORM),bl618)
    # Sipeed M0P -- Bouffalo BL618, single-core T-Head E907 RV32IMAFC, 320MHz
    BUILDNAME := bl618
    PROCESSOR := e907
    OS = baremetal
else ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    # Beken BK7231 family -- ARM968E-S (ARMv5TE), 120MHz, 256KB SRAM, 2MB SPI flash
    # BK7231N adds BLE 5.0; BK7231T is Wi-Fi only. Same MCU peripherals.
    BUILDNAME := $(PLATFORM)
    PROCESSOR := arm968e-s
    OS = baremetal
else ifeq ($(PLATFORM),rp2350)
    # Raspberry Pi RP2350 -- dual Cortex-M33, 150MHz, 520KB SRAM, XIP QSPI flash
    BUILDNAME := rp2350
    PROCESSOR := cortex-m33
    OS = baremetal
else ifeq ($(PLATFORM),stm7xx)
    BUILDNAME := stm7xx
    PROCESSOR := cortex-m7
    OS = baremetal
    STM32_VARIANT = f7
    MFPU = fpv5-d16
else ifeq ($(PLATFORM),stm4xx)
    BUILDNAME := stm4xx
    PROCESSOR := cortex-m4
    OS = baremetal
    STM32_VARIANT = f4
    MFPU = fpv4-sp-d16
else ifeq ($(PLATFORM),routeros)
    # MikroTik RouterOS container (ARM64 Linux). Packaging is consumer-side.
    BUILDNAME := routeros
    PROCESSOR := aarch64-generic
    OS := linux
else
  ifeq ($(origin PLATFORM),undefined)
    # No platform specified -- auto-detect host
    UNAME_S := $(shell uname -s 2>/dev/null || echo Unknown)
    UNAME_M := $(shell uname -m 2>/dev/null || echo unknown)

    ifneq ($(findstring MINGW,$(UNAME_S)),)
        PLATFORM := windows
        OS := windows
    else ifneq ($(findstring MSYS,$(UNAME_S)),)
        PLATFORM := windows
        OS := windows
    else ifneq ($(findstring CYGWIN,$(UNAME_S)),)
        PLATFORM := windows
        OS := windows
    else ifeq ($(UNAME_S),Unknown)
        # no uname, probably native Windows - assume x86_64
        PLATFORM := windows
        OS := windows
        UNAME_M := x86_64
    else ifeq ($(UNAME_S),)
        # cmd.exe / PowerShell: shell couldn't honour `|| echo Unknown` either
        OS := windows
        UNAME_M := x86_64
    else
        OS ?= linux
    endif

    PLATFORM := $(OS)

    ifndef ARCH
        ifeq ($(UNAME_M),x86_64)
            ARCH := x86_64
        else ifeq ($(UNAME_M),amd64)
            ARCH := x86_64
        else ifeq ($(UNAME_M),i686)
            ARCH := x86
        else ifeq ($(UNAME_M),i386)
            ARCH := x86
        else ifeq ($(UNAME_M),aarch64)
            ARCH := arm64
        else ifeq ($(UNAME_M),arm64)
            ARCH := arm64
        else ifeq ($(UNAME_M),armv7l)
            ARCH := arm
        else ifeq ($(UNAME_M),riscv64)
            ARCH := riscv64
        endif
    endif
  endif
endif

# Bare-processor fallback: if PLATFORM was set but didn't match any known
# platform above, treat it as a raw processor name (e.g., make PLATFORM=e906).
ifndef PROCESSOR
  ifdef PLATFORM
    ifneq ($(PLATFORM),$(OS))
      PROCESSOR := $(PLATFORM)
    endif
  endif
endif

# =======================================================================
# PROCESSOR -- CPU core identity
#
# Sets: ARCH, MARCH, MABI. Pure ISA/compiler-target config.
# OS is set with ?= only as a fallback for bare-processor builds;
# PLATFORM always takes precedence.
# =======================================================================

ifdef PROCESSOR
  ifeq ($(PROCESSOR),aarch64-generic)
      ARCH = arm64
  else ifeq ($(PROCESSOR),cortex-a7)
      ARCH = arm
      MARCH = cortex-a7
  else ifeq ($(PROCESSOR),cortex-m4)
      ARCH = thumb
      MARCH = cortex-m4
  else ifeq ($(PROCESSOR),arm968e-s)
      ARCH = arm
      MARCH = arm968e-s
      MABI = soft
      OS ?= baremetal
  else ifeq ($(PROCESSOR),cortex-m33)
      ARCH = thumb
      MARCH = cortex-m33
  else ifeq ($(PROCESSOR),cortex-m7)
      ARCH = thumb
      MARCH = cortex-m7
  else ifeq ($(PROCESSOR),l106)
      ARCH  = xtensa
  else ifeq ($(PROCESSOR),lx6)
      ARCH  = xtensa
      MATTR = +fp,+loop,+mac16,+dfpaccel
  else ifeq ($(PROCESSOR),lx7)
      ARCH  = xtensa
  else ifeq ($(PROCESSOR),k210)
      ARCH  = riscv64
      MARCH = rv64imafdc
      MATTR = +m,+a,+f,+d,+c,+zicsr,+zifencei
      MABI  = lp64d
      OS ?= baremetal
  else ifeq ($(PROCESSOR),c906)
      ARCH  = riscv64
      MARCH = rv64imafdc
      MATTR = +m,+a,+f,+d,+c,+unaligned-scalar-mem,+xtheadba,+xtheadbb,+xtheadbs,+xtheadcmo,+xtheadcondmov,+xtheadfmemidx,+xtheadmac,+xtheadmemidx,+xtheadsync
      MABI  = lp64d
      OS ?= baremetal
  else ifeq ($(PROCESSOR),e902)
      ARCH  = riscv
      MARCH = rv32emc
      MATTR = +e,+m,+c
      MABI  = ilp32e
      OS ?= baremetal
  else ifeq ($(PROCESSOR),e906)
      ARCH  = riscv
      MARCH = rv32imc
      MATTR = +m,+c
      MABI  = ilp32
      OS ?= freertos
  else ifeq ($(PROCESSOR),e907)
      ARCH  = riscv
      MARCH = rv32imafc
      MATTR = +m,+a,+f,+c
      MABI  = ilp32f
      OS ?= freertos
  else ifeq ($(PROCESSOR),esp32p4)
      ARCH  = riscv
      MARCH = rv32imafdcv
      MATTR = +m,+a,+f,+d,+c,+v
      MABI  = ilp32f
      OS ?= freertos
  endif
endif

ifndef BUILDNAME
    ifdef PROCESSOR
        BUILDNAME := $(PROCESSOR)
    else
        BUILDNAME := $(ARCH)_$(OS)
    endif
endif

# =======================================================================
# Compiler auto-selection: cross-compilation targets use LDC
# =======================================================================

ifeq ($(COMPILER),dmd)
ifdef ARCH
ifneq ($(ARCH),x86_64)
ifneq ($(ARCH),x86)
    COMPILER = ldc
endif
endif
endif
endif

ifeq ($(COMPILER),dmd)
    VERSION_FLAG := -version=
else ifeq ($(COMPILER),gdc)
    VERSION_FLAG := -fversion=
else
    VERSION_FLAG := -d-version=
endif

# =======================================================================
# Toolchain discovery (Espressif)
# =======================================================================

ESPRESSIF_PATH ?= $(wildcard $(HOME)/.espressif)
ifdef ESPRESSIF_PATH
    ESPRESSIF_XTENSA_BIN := $(lastword $(sort $(wildcard $(ESPRESSIF_PATH)/tools/xtensa-esp-elf/*/xtensa-esp-elf/bin)))
    ESPRESSIF_RISCV32_BIN := $(lastword $(sort $(wildcard $(ESPRESSIF_PATH)/tools/riscv32-esp-elf/*/riscv32-esp-elf/bin)))
endif

# =======================================================================
# URT_SOURCES -- urt/**.d + urt/driver/<platform>/**.d
#
# Caller appends app sources separately. C glue (mbedtls) is host-only.
# =======================================================================

URT_SOURCES := $(shell find "$(URT_SRCDIR)" -type f -name '*.d' -not -path '$(URT_SRCDIR)/urt/driver/*')
URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver" -maxdepth 1 -type f -name '*.d')
URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/baremetal" -type f -name '*.d')

# mbedtls availability -- host posix builds get it from system libs,
# ESP-IDF ships it for esp% targets (linked via IDF main component).
# User can force via USE_MBEDTLS=1/0 on the command line.
ifneq ($(filter linux ubuntu freebsd,$(OS)),)
    USE_MBEDTLS ?= 1
endif
ifneq ($(filter esp%,$(PLATFORM)),)
    USE_MBEDTLS ?= 1
endif
ifneq ($(filter bl808 bl618,$(PLATFORM)),)
    USE_MBEDTLS ?= 1
endif

# mbedtls C glue: host posix builds compile it directly via URT_SOURCES.
# Embedded targets must compile it via their platform's build system
# (e.g. esp32 via IDF main component, bouffalo via consumer Makefile) so
# the cross-compiler picks up the right mbedtls headers.
ifeq ($(USE_MBEDTLS),1)
ifeq ($(filter freertos baremetal,$(OS)),)
    URT_SOURCES := $(URT_SOURCES) $(URT_SRCDIR)/urt/internal/mbedtls.c
endif
endif

ifeq ($(PLATFORM),bl808)
  URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bl_common" -type f -name '*.d')
  ifeq ($(PROCESSOR),c906)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bl808" -type f -name '*.d')
  else ifeq ($(PROCESSOR),e907)
    # BL808 M0 core -- E907 uses same peripheral drivers as BL618.
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bl618" -type f -name '*.d')
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bl808_m0" -type f -name '*.d')
  endif
endif
ifeq ($(PLATFORM),bl618)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bl618" -type f -name '*.d')
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bl_common" -type f -name '*.d')
endif
ifeq ($(PLATFORM),rp2350)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/rp2350" -type f -name '*.d')
endif
ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/bk7231" -type f -name '*.d' 2>/dev/null)
endif
ifneq ($(filter esp%,$(PLATFORM)),)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/esp32" -type f -name '*.d')
endif
ifdef STM32_VARIANT
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/stm32" -type f -name '*.d')
endif
ifeq ($(OS),windows)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/windows" -type f -name '*.d')
endif
ifneq ($(filter linux ubuntu freebsd,$(OS)),)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/posix" -type f -name '*.d')
endif
ifeq ($(OS),freertos)
    URT_SOURCES := $(URT_SOURCES) $(shell find "$(URT_SRCDIR)/urt/driver/freertos" -type f -name '*.d')
endif

# =======================================================================
# DFLAGS -- version flags + previews
#
# Only platform/processor *version* flags live here (so URT's urt/driver/<x> code
# can `version (BL808)` etc.). Consumer-side `-J platforms/<x>` string
# imports stay in the consumer Makefile.
# =======================================================================

DFLAGS := $(DFLAGS) -preview=bitfields -preview=rvaluerefparam -preview=in #-preview=nosharedaccess <- TODO

# OS-level versions
ifeq ($(OS),freertos)
    DFLAGS := $(DFLAGS) -d-version=FreeRTOS
endif
ifeq ($(OS),baremetal)
    DFLAGS := $(DFLAGS) -d-version=BareMetal
endif
ifneq ($(filter freertos baremetal,$(OS)),)
    DFLAGS := $(DFLAGS) -d-version=Embedded
endif

# "Tiny" targets: <~350KB RAM and <2MB flash, or no external memory at all.
# Code gates nice-to-haves (verbose help, optional protocols) behind
# `version (Tiny)` to minimise binary size. Override with TINY=1/0.
ifneq ($(filter esp8266 bk7231n bk7231t esp32-c2 esp32-h2 esp32-s2,$(PLATFORM)),)
    TINY ?= 1
endif
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),e907)
    TINY ?= 1
  endif
endif
ifeq ($(TINY),1)
    DFLAGS := $(DFLAGS) -d-version=Tiny
endif
ifeq ($(USE_MBEDTLS),1)
ifdef VERSIONS
    VERSIONS := $(VERSIONS),MbedTLS
else
    VERSIONS := MbedTLS
endif
endif

# Vendor/family versions consumed by URT's urt/driver/<x> code
ifneq ($(filter esp%,$(PLATFORM)),)
    DFLAGS := $(DFLAGS) -d-version=Espressif -d-version=CRuntime_Picolibc
    USE_LWIP := 1
endif
ifeq ($(PLATFORM),bl808)
  ifeq ($(PROCESSOR),c906)
    DFLAGS := $(DFLAGS) -d-version=BL808 -d-version=Bouffalo -d-version=CRuntime_Picolibc
  else ifeq ($(PROCESSOR),e907)
    DFLAGS := $(DFLAGS) -d-version=BL808 -d-version=BL808_M0 -d-version=Bouffalo -d-version=CRuntime_Picolibc
  endif
endif
ifeq ($(PLATFORM),bl618)
    DFLAGS := $(DFLAGS) -d-version=BL618 -d-version=Bouffalo -d-version=CRuntime_Picolibc
endif
ifeq ($(PLATFORM),rp2350)
    DFLAGS := $(DFLAGS) -d-version=RP2350 -d-version=CRuntime_Picolibc
endif
ifdef STM32_VARIANT
    DFLAGS := $(DFLAGS) -d-version=STM32 -d-version=CRuntime_Picolibc
    ifeq ($(STM32_VARIANT),f4)
        DFLAGS := $(DFLAGS) -d-version=STM32F4
    else ifeq ($(STM32_VARIANT),f7)
        DFLAGS := $(DFLAGS) -d-version=STM32F7
    endif
endif
ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
    DFLAGS := $(DFLAGS) -d-version=Beken -d-version=CRuntime_Picolibc
    ifeq ($(PLATFORM),bk7231n)
        DFLAGS := $(DFLAGS) -d-version=BK7231N
    else
        DFLAGS := $(DFLAGS) -d-version=BK7231T
    endif
endif

# Chip-specific versions
ifeq ($(PLATFORM),esp8266)
    DFLAGS := $(DFLAGS) -d-version=ESP8266
else ifeq ($(PLATFORM),esp32)
    DFLAGS := $(DFLAGS) -d-version=ESP32
else ifeq ($(PLATFORM),esp32-s2)
    DFLAGS := $(DFLAGS) -d-version=ESP32_S2
else ifeq ($(PLATFORM),esp32-s3)
    DFLAGS := $(DFLAGS) -d-version=ESP32_S3
else ifeq ($(PLATFORM),esp32-c2)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C2
else ifeq ($(PLATFORM),esp32-c3)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C3
else ifeq ($(PLATFORM),esp32-c5)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C5
else ifeq ($(PLATFORM),esp32-c6)
    DFLAGS := $(DFLAGS) -d-version=ESP32_C6
else ifeq ($(PLATFORM),esp32-h2)
    DFLAGS := $(DFLAGS) -d-version=ESP32_H2
else ifeq ($(PLATFORM),esp32-p4)
    DFLAGS := $(DFLAGS) -d-version=ESP32_P4
endif

# IP stack: URT internal stack may override vendor stacks
USE_INTERNAL_IP_STACK ?=
ifeq ($(USE_INTERNAL_IP_STACK),1)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)UseInternalIPStack
else ifeq ($(USE_LWIP),1)
    DFLAGS := $(DFLAGS) $(VERSION_FLAG)lwIP
endif

ifeq ($(CONFIG),unittest)
    DFLAGS := $(DFLAGS) -unittest
endif

# =======================================================================
# Compiler configuration -- triple, mattr, link flags
# =======================================================================

ifeq ($(COMPILER),ldc)
    # Prefer dlang-installer LDC (avoids system package conflicts with cross-compile)
    DC := $(lastword $(sort $(wildcard $(HOME)/dlang/ldc-*/bin/ldc2)))
    DC := $(if $(DC),$(DC),ldc2)

    # Strip druntime/phobos -- URT brings its own object.d and runtime support.
    # OpenWatt's ldc2.conf does the same via `switches = ["-defaultlib="]` for
    # builds invoked from its tree; setting it here too means URT-standalone
    # builds (e.g. URT's own CI) don't need their own ldc2.conf.
    #
    # -frame-pointer=all: keep the frame pointer in every function. URT's
    # exception/unwind machinery walks EBP/RBP chains directly (notably on
    # x86 Windows SEH and bare-metal stack-trace capture); leaf-FPO would
    # leave gaps and crash the walker. Skipped for Espressif targets, which
    # use libgcc _Unwind_Backtrace (DWARF) and have no FP-chain walker --
    # and where the attribute also triggers an Xtensa LLVM register
    # scavenger bug at -O>=1 (LLVM_BUG_5_REGSCAVENGER_SPILL).
    DFLAGS := $(DFLAGS) -defaultlib= -I $(URT_SRCDIR)
    ifneq ($(filter esp%,$(PLATFORM)),)
        # ESP32 family: DWARF unwind, no FP-chain walking.
    else
        DFLAGS := $(DFLAGS) -frame-pointer=all
    endif

    ifeq ($(ARCH),x86_64)
#        DFLAGS := $(DFLAGS) -mtriple=x86_64-linux-gnu
    else ifeq ($(ARCH),x86)
        ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=i686-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=i686-linux-gnu
        endif
    else ifeq ($(ARCH),arm64)
        ifeq ($(OS),freertos)
            DFLAGS := $(DFLAGS) -mtriple=aarch64-none-elf
        else ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=aarch64-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=aarch64-linux-gnu
            # Cross-compile linker, fully static for minimal container size
            DFLAGS := $(DFLAGS) -gcc=aarch64-linux-gnu-gcc -static -L-static
        endif
    else ifeq ($(ARCH),thumb)
        ifeq ($(MARCH),cortex-m33)
            DFLAGS := $(DFLAGS) -mtriple=thumbv8m.main-none-eabihf -gcc=arm-none-eabi-gcc
        else
            DFLAGS := $(DFLAGS) -mtriple=thumbv7em-none-eabihf -gcc=arm-none-eabi-gcc
        endif
        ifdef MARCH
            DFLAGS := $(DFLAGS) -mcpu=$(MARCH)
        endif
    else ifeq ($(ARCH),arm)
        ifeq ($(OS),baremetal)
          ifeq ($(MABI),soft)
            # ARMv5TE has no atomic instructions -- single-thread model
            # makes LLVM lower atomics to plain loads/stores
            DFLAGS := $(DFLAGS) -mtriple=armv5te-none-eabi -float-abi=soft --thread-model=single
          else
            DFLAGS := $(DFLAGS) -mtriple=arm-none-eabihf
          endif
        else ifeq ($(OS),freertos)
            DFLAGS := $(DFLAGS) -mtriple=arm-none-eabihf
        else ifeq ($(OS),windows)
            DFLAGS := $(DFLAGS) -mtriple=armv7-windows-msvc
        else
            DFLAGS := $(DFLAGS) -mtriple=armv7-linux-gnueabihf
        endif
        DFLAGS := $(DFLAGS) -gcc=arm-none-eabi-gcc
        ifdef MARCH
            DFLAGS := $(DFLAGS) -mcpu=$(MARCH)
        endif
    else ifeq ($(ARCH),riscv64)
        DFLAGS := $(DFLAGS) -mtriple=riscv64-unknown-elf -gcc=riscv64-unknown-elf-gcc -code-model=medium
        DFLAGS := $(DFLAGS) -mattr=$(MATTR)
        # ImportC needs picolibc headers for C imports (stdio.h etc.)
        PICOLIBC_INCLUDE := $(firstword $(wildcard /usr/riscv64-unknown-elf/include /usr/lib/picolibc/riscv64-unknown-elf/include))
        DFLAGS := $(DFLAGS) $(if $(PICOLIBC_INCLUDE),-P=-isystem -P=$(PICOLIBC_INCLUDE))
    else ifeq ($(ARCH),riscv)
        RISCV32_GCC ?= $(or $(if $(ESPRESSIF_RISCV32_BIN),$(ESPRESSIF_RISCV32_BIN)/riscv32-esp-elf-gcc),$(shell which riscv32-esp-elf-gcc 2>/dev/null),riscv64-unknown-elf-gcc)
        DFLAGS := $(DFLAGS) -mtriple=riscv32-unknown-elf -gcc=$(RISCV32_GCC)
        DFLAGS := $(DFLAGS) -mattr=$(MATTR) -mabi=$(MABI)
        ifeq ($(PROCESSOR),e902)
            DFLAGS := $(DFLAGS) -d-version=RISCV32E
        endif
    else ifeq ($(ARCH),xtensa)
        # Xtensa -- requires Espressif toolchain (chip-specific GCC wrappers).
        # Two-stage codegen: LDC emits bitcode, Espressif's llc does codegen
        # (upstream LLVM Xtensa backend crashes on invoke+landingpad at -O1+).
        XTENSA_GCC_DIR ?= $(or $(if $(ESPRESSIF_XTENSA_BIN),$(ESPRESSIF_XTENSA_BIN)/),$(dir $(shell which xtensa-esp-elf-gcc 2>/dev/null)))
        # Base features common to all ESP32 Xtensa cores (LX6, S2 LX7, S3 LX7).
        # +fp and +loop are NOT universal -- S2 lacks both.
        XTENSA_MATTR := -mattr=+density,+mul16,+mul32,+mul32high,+div32 \
            -mattr=+sext,+nsa,+clamps,+minmax,+bool \
            -mattr=+windowed,+threadptr \
            -mattr=+exception,+interrupt,+highpriinterrupts,+debug
        ifdef MATTR
            XTENSA_MATTR := $(XTENSA_MATTR) -mattr=$(MATTR)
        endif
        # Workarounds:
        # - single-thread model: no atomic instructions, lower atomics to plain loads/stores
        # - emulated TLS: @TPOFF symbol suffixes incompatible with GNU ld
        # - align-all-functions=2: ensures 4-byte alignment for l32r literal targets
        DFLAGS := $(DFLAGS) -mtriple=xtensa-none-elf --thread-model=single -emulated-tls \
            --align-all-functions=2 $(XTENSA_MATTR) \
            -gcc=$(XTENSA_GCC_DIR)$(XTENSA_GCC)
        ESPRESSIF_LLC := $(lastword $(sort $(wildcard $(HOME)/.espressif/tools/esp-clang/*/esp-clang/bin/llc)))
        XTENSA_TWO_STAGE := 1
    else
        $(error "Unsupported ARCH: $(ARCH)")
    endif

    # Embedded baremetal: assemble cross-gcc flags + libc/libm/libgcc paths.
    # Caller supplies BAREMETAL_LD (linker script) -- without it we emit `-c`
    # (compile-only; sufficient for CI link-check of URT-only builds).
    ifneq ($(filter freertos baremetal,$(OS)),)
      ifeq ($(PLATFORM),bl808)
        ifeq ($(PROCESSOR),c906)
          BAREMETAL_DIR  := $(URT_SRCDIR)/urt/driver/bl808
          BAREMETAL_SRCS := start.S hbn_ram.c
        else ifeq ($(PROCESSOR),e907)
          BAREMETAL_DIR  := $(URT_SRCDIR)/urt/driver/bl808_m0
          BAREMETAL_SRCS := start.S
        endif
      else ifeq ($(PLATFORM),bl618)
        BAREMETAL_DIR  := $(URT_SRCDIR)/urt/driver/bl618
        BAREMETAL_SRCS := start.S
      else ifneq ($(filter bk7231n bk7231t,$(PLATFORM)),)
        BAREMETAL_DIR  := $(URT_SRCDIR)/urt/driver/bk7231
        BAREMETAL_SRCS := start.S
      else ifeq ($(PLATFORM),rp2350)
        BAREMETAL_DIR  := $(URT_SRCDIR)/urt/driver/rp2350
        BAREMETAL_SRCS := start.S boot2.S
      else ifdef STM32_VARIANT
        BAREMETAL_DIR  := $(URT_SRCDIR)/urt/driver/stm32
        BAREMETAL_SRCS := start.S
      endif

      ifdef BAREMETAL_DIR
        ifeq ($(ARCH),arm)
          BAREMETAL_GCC    := arm-none-eabi-gcc
          BAREMETAL_CFLAGS := -mcpu=$(MARCH) -marm -mfloat-abi=$(MABI)
        else ifeq ($(ARCH),thumb)
          BAREMETAL_GCC    := arm-none-eabi-gcc
          MFPU ?= fpv5-sp-d16
          BAREMETAL_CFLAGS := -mcpu=$(MARCH) -mthumb -mfloat-abi=hard -mfpu=$(MFPU)
        else
          BAREMETAL_GCC    := riscv64-unknown-elf-gcc
          BAREMETAL_CFLAGS := -march=$(MARCH) -mabi=$(MABI)
        endif
        BAREMETAL_LIBGCC := $(shell $(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) --print-libgcc-file-name)
        # picolibc/newlib via --specs=picolibc.specs first, then plain gcc, then multilib fallback
        PICOLIBC_MULTIDIR := $(shell $(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) --print-multi-directory 2>/dev/null)
        BAREMETAL_LIBC   := $(or $(filter /%,$(shell $(BAREMETAL_GCC) --specs=picolibc.specs $(BAREMETAL_CFLAGS) --print-file-name=libc.a 2>/dev/null)),$(filter /%,$(shell $(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) --print-file-name=libc.a 2>/dev/null)),$(wildcard /usr/lib/picolibc/riscv64-unknown-elf/lib/$(PICOLIBC_MULTIDIR)/libc.a))
        BAREMETAL_LIBM   := $(or $(filter /%,$(shell $(BAREMETAL_GCC) --specs=picolibc.specs $(BAREMETAL_CFLAGS) --print-file-name=libm.a 2>/dev/null)),$(filter /%,$(shell $(BAREMETAL_GCC) $(BAREMETAL_CFLAGS) --print-file-name=libm.a 2>/dev/null)),$(wildcard /usr/lib/picolibc/riscv64-unknown-elf/lib/$(PICOLIBC_MULTIDIR)/libm.a))
        # Caller adds: -L-T<linker_script> + any vendor blob archives.
        # TODO: drop -L--allow-multiple-definition once we migrate intentional
        # blob-symbol overrides (currently bl_sleep_check) to -L--wrap=<sym>.
        # The flag silently hides shadow-stub bugs (see bl808_m0/wifi.d for
        # the history of bl_init/bl_pm_ops_register/bl_nap_calculate/bl_reset_evt
        # accidental shadows). Re-enable the strict link periodically by
        # commenting this out and running clean to catch new shadows.
        DFLAGS := $(DFLAGS) -L--gc-sections -L--allow-multiple-definition --link-internally -L-z -Lnorelro -L$(BAREMETAL_LIBC) -L$(BAREMETAL_LIBM) -L$(BAREMETAL_LIBGCC)
      else ifeq ($(ARCH),xtensa)
        # Xtensa: emit LLVM bitcode for two-stage codegen via Espressif's llc
        # (upstream LLVM Xtensa backend crashes on invoke+landingpad at -O1+).
        DFLAGS := $(DFLAGS) --output-bc
      else
        # No link script wired up (e.g. ESP RISC-V variants without ESP-IDF):
        # compile-only object output.
        DFLAGS := $(DFLAGS) -c
      endif
    endif

    ifeq ($(CONFIG),release)
      ifeq ($(TINY),1)
        DFLAGS := $(DFLAGS) -release --enable-asserts -Oz -enable-inlining
      else ifeq ($(ARCH),xtensa)
        DFLAGS := $(DFLAGS) -release --enable-asserts -Oz -enable-inlining
      else
        DFLAGS := $(DFLAGS) -release --enable-asserts -O3 -enable-inlining
      endif
    else ifdef BAREMETAL_DIR
        # Embedded debug/unittest: still optimize to fit in firmware partition
        DFLAGS := $(DFLAGS) --enable-asserts -O2 -enable-inlining
    else ifeq ($(ARCH),xtensa)
        # Xtensa: -Oz to fit in flash; bitcode emission set above
        DFLAGS := $(DFLAGS) --enable-asserts -Oz -enable-inlining -d-debug
    else
        DFLAGS := $(DFLAGS) -g -d-debug
    endif

else ifeq ($(COMPILER),dmd)
    DC ?= dmd

    # Strip druntime/phobos, use URT's own object.d.
    # Consumers may need to prepend their own -I to shadow druntime's
    # __importc_builtins.di (e.g. OpenWatt's third_party/dmd/ for MSVC va_list).
    DFLAGS := $(DFLAGS) -defaultlib= -I=$(URT_SRCDIR)

    ifeq ($(ARCH),x86_64)
#        DFLAGS := $(DFLAGS) -m64
    else ifeq ($(ARCH),x86)
        DFLAGS := $(DFLAGS) -m32
    else
        $(error "DMD: unsupported ARCH=$(ARCH) for PLATFORM=$(PLATFORM) (use COMPILER=ldc)")
    endif

    ifeq ($(CONFIG),release)
        DFLAGS := $(DFLAGS) -release -O -inline
    else
        DFLAGS := $(DFLAGS) -g -debug
    endif
else
    $(error "Unknown D compiler: $(COMPILER)")
endif

# User-specified D version idents, comma-separated (e.g. VERSIONS=Foo,Bar)
ifdef VERSIONS
    comma := ,
    empty :=
    space := $(empty) $(empty)
    DFLAGS := $(DFLAGS) $(addprefix $(VERSION_FLAG),$(subst $(comma),$(space),$(VERSIONS)))
endif
