#pragma author Antonio Vázquez Blanco <antoniovazquezblanco@gmail.com>
#pragma description AMD Linux Kernel microcode container
#pragma once
#pragma magic [ "DMA\x00" ] @ 0x00

// AMD microcode container (Linux kernel / linux-firmware format)
//
// A concatenation of type/size framed sections:
//   - a 4-byte magic ("DMA\0", i.e. UCODE_MAGIC = 0x00414d44)
//   - one equivalence-CPU table section (type 0x0000), and
//   - one or more microcode patch sections (type 0x0001), each holding a full
//     AMD microcode patch (decoded via amd_ucode_patch.hexpat).
// See Linux arch/x86/kernel/cpu/microcode/amd.c and the reference parser at
// https://github.com/amd-zenith/amd-ucode-container

#pragma endian little

#include <std/io.pat>
#include <std/mem.pat>
#include <std/sys.pat>

// Reuse the patch types (date, patch level, the family-dependent header data,
// signature blocks and the sized AmdUcodePatch) instead of duplicating them
// here. The AMD_UCODE_PATCH_USE_LIB define suppresses the standalone patch
// placement so only the container is laid out at offset 0.
#define AMD_UCODE_PATCH_USE_LIB
#include "amd_ucode_patch.hexpat"

// Magic is "AMD\0" byte-reversed.
#define AMD_UCODE_MAGIC "DMA\x00"

// A CPUID(1).EAX signature exactly as the CPU reports it, kept as stored rather
// than re-encoded from a family/model/stepping triple.
using StdCpuId = u32 [[format("format_std_cpuid")]];

fn format_std_cpuid(u32 value) {
    u32 family = ((value >> 8) & 0xF) + ((value >> 20) & 0xFF);
    u32 model  = (((value >> 16) & 0xF) << 4) | ((value >> 4) & 0xF);
    return std::format("{:08X} - family {:#04x} ({}), model {:#04x}, stepping {:#x}",
                       value, family, family_name(family), model, value & 0xF);
};

// Equivalence-CPU table entry (Linux `struct equiv_cpu_entry`).
//
// Maps the signature a part reports onto the id patches are keyed by, so the
// loader can match a CPU to a patch whose id is not that CPU's own signature.
// The table is terminated by an all-zero entry.
struct EquivCpuEntry {
    StdCpuId   installed_cpu;         // CPUID(1).EAX signature of the part
    u32        fixed_errata_mask;
    u32        fixed_errata_compare;
    // The patch id to load, matching the patch header CPUID field. Decoded
    // generically, as the table itself carries no family: on a family 0x14/0x15
    // entry bit 11 is the "body is plaintext" marker rather than part of the
    // model (see EquivalenceIdFam14To15 in amd_ucode_patch.hexpat).
    UcodeCpuId equiv_cpu;
    u16        res;
};

enum FileSectionType : u32 {
    EQUIV_CPU_TABLE = 0x0000,
    UCODE           = 0x0001,
};

struct FileSection {
    FileSectionType section_type;
    u32 section_size;
    if (section_type == FileSectionType::EQUIV_CPU_TABLE) {
        EquivCpuEntry equiv_cpu_table[section_size / sizeof(EquivCpuEntry)];
    } else if (section_type == FileSectionType::UCODE) {
        AmdUcodePatch<section_size> patch;
    } else {
        u8 section_data[section_size];
    }
};

struct AmdUcodeContainer {
    char magic[4];
    FileSection sections[while(!std::mem::eof())];
};

AmdUcodeContainer container @ 0x00;
std::assert(container.magic == AMD_UCODE_MAGIC, "File magic is not a valid AMD microcode container!");
