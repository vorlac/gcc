/* Target definitions for AArch64 running Darwin (macOS).
   Copyright (C) 2024-2026 Free Software Foundation, Inc.

   This file is part of GCC.

   GCC is free software; you can redistribute it and/or modify it
   under the terms of the GNU General Public License as published by
   the Free Software Foundation; either version 3, or (at your option)
   any later version.

   GCC is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with GCC; see the file COPYING3.  If not see
   <http://www.gnu.org/licenses/>.  */

#ifndef GCC_AARCH64_DARWIN_TARGET_H
#define GCC_AARCH64_DARWIN_TARGET_H

/* Enable Mach-O bits in the aarch64 backend.  */
#undef TARGET_MACHO
#define TARGET_MACHO 1

/* Identify this as the AArch64 darwin sub-port.  */
#undef  DARWIN_AARCH64
#define DARWIN_AARCH64 1

/* Apple's arm64 ABI uses a 64-bit 'long double' that is identical to
   'double' (DFmode, 53-bit mantissa), matching clang.  aarch64.h defaults
   TARGET_LONG_DOUBLE_128 to 1 (TFmode/binary128); we turn it off here.
   Setting this to 0 drives every consumer through one knob:
     - aarch64_c_mode_for_floating_type (aarch64.cc) returns DFmode for
       TI_LONG_DOUBLE_TYPE instead of TFmode, so sizeof(long double)==8 and
       __LDBL_MANT_DIG__==53 (the precision/size flow from the mode in
       tree.cc:build_common_tree_nodes and c-family/c-cppbuiltin.cc);
     - aarch64_scalar_mode_supported_p returns false for TFmode, which also
       disables _Float128/__float128 -- this is correct, clang has NO 128-bit
       float on arm64-darwin.
   C++ mangling of 'long double' stays 'e' (cp/mangle.cc matches by type
   identity, not by mode), matching clang.  This mirrors how the in-tree
   aarch64 Windows MS ABI sub-port does it (aarch64-abi-ms.h).  aarch64/darwin.h
   is the last tm_file header, so #undef + #define wins over aarch64.h.
   HARD COUPLING: requires rebuilding libgcc and libstdc++ so their long
   double routines/typeinfo match the new 64-bit ABI.  */
#undef  TARGET_LONG_DOUBLE_128
#define TARGET_LONG_DOUBLE_128 0

/* AArch64 is always 64-bit.  darwin.cc uses TARGET_64BIT from x86.  */
#ifndef TARGET_64BIT
#define TARGET_64BIT 1
#endif

/* darwin.cc references UNSPEC_MACHOPIC_OFFSET which is defined in the i386
   machine description.  On AArch64, PIC is handled via ADRP/ADD or GOT
   indirection, so the picbase-relative UNSPEC is never used at runtime.
   We define it here so that darwin.cc compiles.  The machopic_gen_offset
   function that uses it will not be reached on aarch64 because
   MACHO_DYNAMIC_NO_PIC_P is always false (we always use PIC).  */
#ifndef UNSPEC_MACHOPIC_OFFSET
#define UNSPEC_MACHOPIC_OFFSET 0x1fff
#endif

/* Size of the Obj-C jump buffer.  Based on
   /usr/include/setjmp.h on Apple arm64:
   _JBLEN is defined as ((14 + 8 + 2) * 2) = 48 (in 32-bit words)
   which is 24 (in 64-bit words).  */
#define OBJC_JBLEN 48

#define TARGET_OS_CPP_BUILTINS()		\
  do {						\
    builtin_define ("__LITTLE_ENDIAN__");	\
    builtin_define ("__arm64__");		\
    builtin_define ("__arm64");			\
    darwin_cpp_builtins (pfile);		\
  } while (0)

/* AArch64 Darwin is always 64-bit, no biarch.  */
#undef PTRDIFF_TYPE
#define PTRDIFF_TYPE "long int"

/* Darwin uses the standard wchar_t type.  */
#undef WCHAR_TYPE
#define WCHAR_TYPE "int"

#undef WCHAR_TYPE_SIZE
#define WCHAR_TYPE_SIZE 32

/* Unlike the AArch64 ELF/AAPCS64 ABI (which makes plain char unsigned, see
   aarch64.h DEFAULT_SIGNED_CHAR 0), the Apple/Darwin ABI makes plain char
   SIGNED on every architecture, for consistency across Darwin targets and to
   match Apple clang.  This mirrors rs6000/darwin.h (which overrides the
   PowerPC unsigned default) and i386 (where DEFAULT_SIGNED_CHAR is already 1,
   so x86_64-apple-darwin inherits signed char).  */
#undef DEFAULT_SIGNED_CHAR
#define DEFAULT_SIGNED_CHAR 1

/* We want -fPIC by default on Darwin, unless building a kernel.
   Also disable section anchors: TARGET_ASM_OUTPUT_ANCHOR is NULL (from
   darwin.h) which makes -fsection-anchors unsupported, but -O2 enables it
   by default.  Disable it here to avoid -Werror failures in libgcc.  */
#undef CC1_SPEC
#define CC1_SPEC \
  "%{!mkernel:%{!static:%{!mdynamic-no-pic:-fPIC}}} " \
  "%{g: %{!fno-eliminate-unused-debug-symbols: " \
  "-feliminate-unused-debug-symbols }} " \
  "-fno-section-anchors " \
  DARWIN_CC1_SPEC

/* Darwin AArch64 assembler spec.  Apple's assembler uses -arch arm64.  */
#undef ASM_SPEC
#define ASM_SPEC \
  "%{static} -arch %(darwin_arch) " \
  ASM_OPTIONS ASM_MMACOSX_VERSION_MIN_SPEC

/* Apple's architecture identifier for AArch64 is "arm64".  */
#ifndef DARWIN_ARCH_SPEC
#define DARWIN_ARCH_SPEC "arm64"
#define DARWIN_SUBARCH_SPEC DARWIN_ARCH_SPEC
#endif

#undef DARWIN_HEAP_T_LIB
#define DARWIN_HEAP_T_LIB " -lheapt_w "

#undef SUBTARGET_EXTRA_SPECS
#define SUBTARGET_EXTRA_SPECS					\
  DARWIN_EXTRA_SPECS						\
  { "darwin_arch", DARWIN_ARCH_SPEC },				\
  { "darwin_crt2", "" },					\
  { "darwin_subarch", DARWIN_SUBARCH_SPEC },

/* Generate PIC symbol indirection stubs if this is true.  */
#undef TARGET_MACHO_SYMBOL_STUBS
#define TARGET_MACHO_SYMBOL_STUBS (darwin_symbol_stubs)

/* On Darwin, the stack is 128-bit aligned at the point of every call.
   This matches aarch64's AAPCS64 requirement.  */
#undef MAIN_STACK_BOUNDARY
#define MAIN_STACK_BOUNDARY 128

/* Static chain / nested-function trampoline register on Darwin.

   The generic aarch64 backend uses x18 as the static chain register
   (aarch64.h: STATIC_CHAIN_REGNUM == R18_REGNUM).  Two things make x18
   wrong on Apple targets:

     - x18 is reserved by the OS on Apple Silicon (the kernel may use
       and clobber it), exactly as on Windows.  clang never allocates
       x18 on Darwin/arm64.

     - The libgcc heap trampoline (the default trampoline on Darwin, see
       AARCH64_CUSTOM_FUNCTION_TEST below) delivers the static chain in
       x16 on Apple: libgcc/config/aarch64/heap-trampoline.c emits
       `ldr x16, .+24` (chain) / `ldr x17, .+20` (func) / `br x17` in its
       __APPLE__ instruction sequence, whereas the Linux sequence uses
       x18 for the chain.  The compiler must therefore read the incoming
       static chain from x16 to match the runtime.

   We override STATIC_CHAIN_REGNUM to R16_REGNUM (x16 == IP0) and reserve
   x18.  This mirrors aarch64-abi-ms.h, which overrides STATIC_CHAIN_REGNUM
   to R17 and sets FIXED_X18/CALL_USED_X18 because x18 is reserved on
   Windows, and aarch64-vxworks.h, which moves the chain off x18 because
   VxWorks uses it as the TCB.  We do NOT define TARGET_OS_USES_R18: that
   path (aarch64_conditional_register_usage) sets call_used_regs[R18]=1,
   which contradicts reserving x18 as a fixed, untouched register; the
   FIXED_X18/CALL_USED_X18 redefinition below is the canonical Darwin/
   Windows mechanism and reaches FIXED_REGISTERS/CALL_REALLY_USED_REGISTERS
   via macro indirection because aarch64/darwin.h is included after
   aarch64.h.  */
#undef  STATIC_CHAIN_REGNUM
#define STATIC_CHAIN_REGNUM R16_REGNUM

#undef  FIXED_X18
#define FIXED_X18 1

#undef  CALL_USED_X18
#define CALL_USED_X18 0

/* Jump tables go in the text section on Darwin (required for Mach-O PIC).  */
#undef JUMP_TABLES_IN_TEXT_SECTION
#define JUMP_TABLES_IN_TEXT_SECTION 1

#undef TARGET_ASM_FILE_END
#define TARGET_ASM_FILE_END darwin_file_end

/* Darwin labels begin with an underscore.  */
#undef USER_LABEL_PREFIX
#define USER_LABEL_PREFIX "_"

#undef LOCAL_LABEL_PREFIX
#define LOCAL_LABEL_PREFIX "L"

/* Assembler output directives for Darwin/Mach-O AArch64.  */
#define TEXT_SECTION_ASM_OP "\t.text"
#define DATA_SECTION_ASM_OP "\t.data"

/* Darwin uses # for asm comments.  Apple's arm64 assembler accepts both
   // and # but the Mach-O convention is #.  */
#define ASM_COMMENT_START "#"

/* NOTE: We do NOT override ASM_OUTPUT_LABELREF here.  The generic
   darwin.h version includes crucial machopic_validate_stub_or_non_lazy_ptr
   calls that mark non-lazy symbol pointer entries as "used", enabling
   machopic_output_indirection to emit their definitions at file end.
   Without this validation, references like L___gxx_personality_v0$non_lazy_ptr
   are emitted but never defined, causing assembler errors in libstdc++.  */

#undef GLOBAL_ASM_OP
#define GLOBAL_ASM_OP "\t.globl\t"

/* Include both Darwin driver self specs and aarch64-specific ones.
   Apple Silicon always has LSE atomics, so disable outline atomics
   (which would require ELF-syntax lse.S runtime stubs).

   Default to -mcpu=apple-m1 when the user gives neither -mcpu nor -march:
   every Apple-silicon Mac is M1 (Armv8.5-A) or newer, and this is what Apple
   clang effectively targets.  It enables FEAT_LSE, which is what makes the
   16-byte (TImode) casp atomics fire by default (TARGET_LSE) so that
   std::atomic<16-byte> / __int128 atomics are inline and lock-free instead of
   falling back to libatomic.  The user can still override with any
   -mcpu=/-march=.  */
#undef DRIVER_SELF_SPECS
#define DRIVER_SELF_SPECS			\
  "%{!mlittle-endian:-mlittle-endian} "		\
  "%{!mabi=*:-mabi=lp64} "			\
  "%{!mno-outline-atomics:-mno-outline-atomics} " \
  "%{!mcpu=*:%{!march=*:-mcpu=apple-m1}} "	\
  MCPU_MTUNE_NATIVE_SPECS			\
  SUBTARGET_DRIVER_SELF_SPECS

/* Darwin on AArch64 always uses DWARF.  */
#define DWARF2_DEBUGGING_INFO 1
#define PREFERRED_DEBUGGING_TYPE DWARF2_DEBUG

#undef REGISTER_SUBTARGET_PRAGMAS
#define REGISTER_SUBTARGET_PRAGMAS() DARWIN_REGISTER_TARGET_PRAGMAS()

#undef TARGET_SET_DEFAULT_TYPE_ATTRIBUTES
#define TARGET_SET_DEFAULT_TYPE_ATTRIBUTES darwin_set_default_type_attributes

/* Darwin uses sys_icache_invalidate instead of the Linux cache-clear call.  */
#undef CLEAR_INSN_CACHE
#define CLEAR_INSN_CACHE(beg, end)				\
  extern void sys_icache_invalidate(void *start, size_t len);	\
  sys_icache_invalidate ((beg), (size_t)((end)-(beg)))

#define SUBTARGET_ENCODE_SECTION_INFO darwin_encode_section_info

/* Darwin x86 has symbol stubs in an IMPORT section; not needed for arm64
   since it uses GOT-based indirection, but we keep the definition for
   compatibility with generic darwin code.  */
#undef MACHOPIC_NL_SYMBOL_PTR_SECTION
#define MACHOPIC_NL_SYMBOL_PTR_SECTION \
  ".section __DATA,__nl_symbol_ptr,non_lazy_symbol_pointers"

/* Disable custom function descriptors when we have heap trampolines.  */
#undef  AARCH64_CUSTOM_FUNCTION_TEST
#define AARCH64_CUSTOM_FUNCTION_TEST \
  (flag_trampolines && flag_trampoline_impl == TRAMPOLINE_IMPL_HEAP) ? 0 : 1

/* First available SYMBOL flag bit for use by subtargets.  */
#define SYMBOL_FLAG_SUBT_DEP (SYMBOL_FLAG_MACH_DEP << 5)

/* Darwin has asm aligned power-of-2 style.  */
#undef ASM_OUTPUT_ALIGN
#define ASM_OUTPUT_ALIGN(FILE, LOG) \
  do {								\
    if ((LOG) != 0)						\
      fprintf ((FILE), "\t.p2align %d\n", (int) (LOG));		\
  } while (0)

/* Define the syntax of pseudo-ops, labels and comments.  */
#define ASM_BYTE "\t.byte\t"
#define ASM_SHORT "\t.short\t"
#define ASM_LONG "\t.long\t"
#define ASM_QUAD "\t.quad\t"

/* Make the assembler produce DWARF .eh_frame sections.  */
#define DWARF2_UNWIND_INFO 1

/* Override EH encoded address output for AArch64 Darwin.
   Apple's arm64 assembler does not support relocations against local
   symbols (L_*$non_lazy_ptr) in the __eh_frame/__gcc_except_table sections,
   so we cannot use darwin_non_lazy_pcrel (which creates such references).
   Instead, for any indirect+pcrel+sdata4 reference (personality, typeinfo),
   we emit a GOT-relative reference using @GOT, similar to what x86_64
   darwin does with @GOTPCREL.  */
#undef ASM_MAYBE_OUTPUT_ENCODED_ADDR_RTX
#define ASM_MAYBE_OUTPUT_ENCODED_ADDR_RTX(FILE, ENCODING, SIZE, ADDR, DONE) \
  if ((ENCODING) & DW_EH_PE_indirect)					\
    {									\
      fputs (ASM_LONG, FILE);						\
      assemble_name (FILE, XSTR (ADDR, 0));				\
      fputs ("@GOT-.", FILE);						\
      goto DONE;							\
    }

/* Override ASM_PREFERRED_EH_DATA_FORMAT for AArch64 Darwin.
   - Personality (CODE==2, GLOBAL==1): indirect + pcrel + sdata4
   - Typeinfo (CODE==0, GLOBAL==1): indirect + pcrel + sdata4
     (must NOT use absptr — arm64 dylibs prohibit text relocations)
   - Local references (GLOBAL==0): pcrel
   - FDE (CODE==1): pcrel  */
#undef ASM_PREFERRED_EH_DATA_FORMAT
#define ASM_PREFERRED_EH_DATA_FORMAT(CODE,GLOBAL)  \
  (((GLOBAL) == 1) \
   ? (DW_EH_PE_pcrel | DW_EH_PE_indirect | DW_EH_PE_sdata4) : \
     DW_EH_PE_pcrel)

/* Do NOT pass -no_compact_unwind on arm64.

   The generic darwin.h defines DARWIN_NOCOMPACT_UNWIND to add
   -no_compact_unwind to the link line for macOS >= 10.6 (a workaround for
   PR41260 on old x86_64/ppc toolchains that could not turn GCC's DWARF
   __eh_frame into valid Apple compact unwind).  That workaround is harmful
   on Apple Silicon:

     - Apple arm64 objects produced by clang/LLVM are compact-unwind-only:
       they contain a __compact_unwind section and NO __eh_frame.
     - On arm64 the system unwinder reads the linker-synthesized
       __unwind_info index first.
     - -no_compact_unwind makes ld64 discard input __compact_unwind sections
       and skip synthesizing __unwind_info, leaving clang functions with no
       unwind data at all.  C++ exceptions thrown across such objects then
       reach std::terminate.

   GCC's own arm64 EH is unaffected by dropping the flag: GCC still emits
   DWARF __eh_frame (DWARF2_UNWIND_INFO is 1 above), ld64 synthesizes
   __unwind_info from it, and __eh_frame remains as a fallback.  This lets
   exceptions propagate correctly through both GCC- and clang-compiled
   objects, matching the Apple arm64 ABI as implemented by clang.

   We override the macro to empty rather than editing the generic
   LINK_COMMAND_SPEC so that x86_64-apple-darwin and *-apple-darwin (ppc)
   keep their existing PR41260 behavior unchanged.  config.gcc includes
   the generic darwin.h before this header, and gcc.cc expands
   LINK_COMMAND_SPEC (which references DARWIN_NOCOMPACT_UNWIND by name)
   after all target headers, so this redefinition is the value used for
   arm64 only.  */
#undef DARWIN_NOCOMPACT_UNWIND
#define DARWIN_NOCOMPACT_UNWIND ""

/* The ENDFILE_SPEC for Darwin aarch64.  */
#undef ENDFILE_SPEC
#define ENDFILE_SPEC \
  "%{Ofast|ffast-math|funsafe-math-optimizations:" \
  "%{!shared:%{!mno-daz-ftz:crtfastmath.o%s}}} " \
  TM_DESTRUCTOR

/* NOTE on 16-byte (TImode) atomics: the upstream aarch64 backend has no inline
   TImode atomic expander, so std::atomic<16-byte> / __int128 atomics lower to
   __atomic_*_16 libcalls that live in libatomic.  We deliberately do NOT force
   -latomic into the default link sequence here: forcing it deadlocks the
   bootstrap (libatomic, libstdc++ and libgomp configure-time link tests run
   before libatomic exists, since they carry no all-target-libatomic dependency
   in Makefile.def), and the supported x86_64-apple-darwin port never forces it
   either (x86 inlines via CMPXCHG16B).  The correct, bootstrap-safe fix is a
   TImode casp/caspal expander in the aarch64 backend (clang inlines via LSE);
   that is a separate upstream-level enhancement.  Users needing 16-byte atomics
   today can link with -latomic explicitly.  */

/* AArch64 Darwin uses the AAPCS64 ABI.  Aggregate passing matches
   the Apple arm64 ABI conventions which are the same as AAPCS64 for
   most practical purposes.  */

/* Section anchors are not supported for aarch64 darwin.  darwin.h sets
   TARGET_ASM_OUTPUT_ANCHOR to NULL.  We must NOT set it to
   darwin_asm_output_anchor because its .set directives cause N_ALT_ENTRY
   linker errors on arm64.  Instead, we ensure -fsection-anchors is off
   via the CC1_SPEC and the subtarget override.  */

/* Define this to be nonzero if static stack checking is supported.  */
#define STACK_CHECK_STATIC_BUILTIN 1

/* Darwin AArch64 assembler supports .ident directive.  */
#undef TARGET_ASM_OUTPUT_IDENT
#define TARGET_ASM_OUTPUT_IDENT default_asm_output_ident_directive

/* We do not use ELF .init_array / .fini_array — Darwin has its own
   mechanisms via mod_init_func / mod_term_func sections.  These are
   handled by the generic darwin.h / darwin.cc machinery.  */

/* We need EXTRA_SPECS to include the asm_cpu_spec.  */
#undef EXTRA_SPECS
#define EXTRA_SPECS					\
  { "asm_cpu_spec", ASM_CPU_SPEC },			\
  SUBTARGET_EXTRA_SPECS

#endif /* GCC_AARCH64_DARWIN_TARGET_H */
