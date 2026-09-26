#pragma author Antonio Vázquez Blanco <antoniovazquezblanco@gmail.com>
#pragma description AMD microcode patch
#pragma once

#pragma endian little

#include <std/io.pat>
#include <std/mem.pat>

// AMD microcode patch
//
// A single AMD microcode patch, as distributed standalone or embedded inside a
// container (see amd_ucode_container.hexpat). The layout mirrors the reference
// parser at https://github.com/amd-zenith/amd-ucode-patch.
//
// A patch is a 32-byte header core -- build date, patch level, loader id and a
// 22-byte family-dependent data region -- followed by a signature block on the
// families that carry one, and then the body.
//
// Which of those layouts apply is decided by the CPU family, and the family
// comes from the patch level rather than from the header CPUID field: on a few
// pre-Zen patches that field holds an equivalence id that decodes to the wrong
// family (a Llano patch whose id is 0x1200 reads as family 0x10).


// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

fn bcd_u8(u8 value) {
    return ((value >> 4) & 0xF) * 10 + (value & 0xF);
};

fn bcd_u16(u16 value) {
    return bcd_u8((value >> 8) & 0xFF) * 100 + bcd_u8(value & 0xFF);
};

fn format_bcd_u8(u8 value) {
    return std::format("{:02d}", bcd_u8(value));
};

fn format_bcd_u16(u16 value) {
    return std::format("{:04d}", bcd_u16(value));
};

using BcdU8  = u8  [[format("format_bcd_u8")]];
using BcdU16 = u16 [[format("format_bcd_u16")]];

fn format_hex16(u16 value) {
    return std::format("{:04X}", value);
};

// The families AMD has actually shipped. A decoded family outside this set is
// not real silicon, and means the value it came from is malformed.
fn family_name(u32 family) {
    str name = "Unknown";
    match (family) {
        (0x0F): name = "K8";
        (0x10): name = "K10";
        (0x11): name = "Turion";
        (0x12): name = "Fusion";
        (0x14): name = "Bobcat";
        (0x15): name = "Bulldozer";
        (0x16): name = "Jaguar/Puma";
        (0x17): name = "Zen/Zen+/Zen2";
        (0x19): name = "Zen3/Zen3+/Zen4";
        (0x1A): name = "Zen5/Zen6";
    }
    return name;
};

// Re-encode a family/model/stepping triple as the standard CPUID(1).EAX
// signature the CPU itself reports. That is what the container equivalence
// table is keyed on, and what patch filenames usually carry.
fn cpuid_signature(u32 family, u32 model, u32 stepping) {
    return (stepping & 0xF)
         | ((model & 0xF) << 4)
         | (0xF << 8)                      // base family, 0xF on every part here
         | (((model >> 4) & 0xF) << 16)
         | (((family - 0xF) & 0xFF) << 20);
};

fn format_cpuid(u32 family, u32 model, u32 stepping) {
    return std::format("{:08X} - family {:#04x} ({}), model {:#04x}, stepping {:#x}",
                       cpuid_signature(family, model, stepping),
                       family, family_name(family), model, stepping);
};


// ---------------------------------------------------------------------------
// Build date (offset 0x00)
// ---------------------------------------------------------------------------

// Linux `data_code`, the AMD patent "date code". A little-endian packed BCD
// laid out as 0xMMDDYYYY, so the bytes `07 20 14 06` read as 2007-06-14.
struct PatchDate {
    BcdU16 year;   // BCD, 4 digits
    BcdU8  day;    // BCD, 2 digits
    BcdU8  month;  // BCD, 2 digits
} [[format("format_patch_date")]];

fn format_patch_date(PatchDate date) {
    return std::format("{:04d}-{:02d}-{:02d}",
                       bcd_u16(date.year), bcd_u8(date.month), bcd_u8(date.day));
};


// ---------------------------------------------------------------------------
// Patch level (offset 0x04)
// ---------------------------------------------------------------------------

// Linux `patch_id`, zentool `revision`. The value the CPU reports through
// MSR 0x8B (MSR_AMD64_PATCH_LEVEL) for the loaded microcode, and what the
// loader compares to decide whether an update is newer than the running patch.
//
// Its top byte is the extended family -- the one field every version of the
// word carries. The rest is a plain counter before Jaguar, and a packed CPUID
// from Jaguar on.
using PatchLevel = u32 [[format("format_patch_level")]];

// Two shipped K8 patch levels carry a top byte that does not name their family.
// Both are family 0x0F, i.e. extended family 0x00, as their filename, CPUID
// field and loader id all agree. Correcting the extended family here also fixes
// the family, which derives from it.
fn patch_level_extended_family(u32 value) {
    u32 extended_family = (value >> 24) & 0xFF;
    if (value == 0x02000008 || value == 0xC0012102)
        extended_family = 0x00;   // top byte would read as family 0x11 / 0xCF
    return extended_family;
};

// Base family 0xF plus the extended family, so a top byte of 0x08 is family
// 0x17 (Zen 1).
fn patch_level_family(u32 value) {
    return 0xF + patch_level_extended_family(value);
};

// Jaguar (0x16) and the Zen parts pack the CPUID they target beside the family.
// Only the model high nibble moves: Jaguar keeps it in the low nibble of
// byte 2, Zen in the high one.
fn patch_level_has_cpuid(u32 family) {
    return family == 0x16 || family == 0x17 || family == 0x19 || family == 0x1A;
};

fn format_patch_level(u32 value) {
    u32 family = patch_level_family(value);
    str text = std::format("{:08X} - family {:#04x} ({})",
                           value, family, family_name(family));
    if (patch_level_has_cpuid(family)) {
        u32 byte2 = (value >> 16) & 0xFF;
        u32 byte1 = (value >> 8) & 0xFF;
        u32 model_hi = family == 0x16 ? (byte2 & 0xF) : ((byte2 >> 4) & 0xF);
        text = std::format("{:08X} - {}", value,
                           format_cpuid(family,
                                        (model_hi << 4) | ((byte1 >> 4) & 0xF),
                                        byte1 & 0xF));
    }
    return text;
};


// ---------------------------------------------------------------------------
// Loader id (offset 0x08)
// ---------------------------------------------------------------------------

// Linux `mc_patch_data_id`, zentool `format`, the AMD patent "MPB ID". Kept as
// a stored value: the layouts below are selected by the family, not by this.
using LoaderId = u16 [[format("format_hex16")]];


// ---------------------------------------------------------------------------
// Header data (offset 0x0A, 22 bytes)
// ---------------------------------------------------------------------------

// The header CPUID field (Linux `processor_rev_id`, zentool `cpuid`). A packed
// form narrower than the CPUID(1).EAX signature: it is the key the container
// equivalence table maps a CPUID onto, so the loader matches a patch to a part
// by it.
bitfield UcodeCpuId {
    stepping   : 4;
    model_lo   : 4;
    model_hi   : 4;
    family_ext : 4;
} [[format("format_ucode_cpuid")]];

fn format_ucode_cpuid(UcodeCpuId cpuid) {
    return format_cpuid(0xF + cpuid.family_ext,
                        (cpuid.model_hi << 4) | cpuid.model_lo,
                        cpuid.stepping);
};

// The PCI device id of the northbridge a patch is restricted to. Zero means the
// patch is not restricted to one.
using NorthbridgeDeviceId = u32 [[format("format_nb_dev_id")]];

fn format_nb_dev_id(u32 value) {
    str text = std::format("{:08X}", value);
    if (value == 0)
        text = "00000000 - no northbridge restriction";
    return text;
};

// Families 0x0F-0x12 (K8, K10, Griffin, Llano): the pre-Bobcat parts whose
// patch body is an array of micro-op triads, described by the fields below. A
// triad is three micro-ops and a sequence control field.
struct HeaderDataFam0fTo12 {
    u8                  op_triad_count;     // 0x0A  Linux mc_patch_data_len
    u8                  init_flag;          // 0x0B  run the patch instead of resuming
    u32                 op_triad_checksum;  // 0x0C  sum of the triad array u32 words
    NorthbridgeDeviceId nb_dev_id;          // 0x10  Linux nb_dev_id
    u8                  unknown0[4];        // 0x14
    UcodeCpuId          cpuid;              // 0x18
    u8                  unknown1[6];        // 0x1A
};

// Bobcat (0x14) and Bulldozer (0x15): the default layout, except that bit 11 of
// the equivalence id is not part of the CPUID. AMD ships some of these patches
// twice under two ids, and the copy whose id has that bit set is in the clear
// while the one without it is encrypted. These families carry no body header,
// so this is the only place that signal lives.
bitfield EquivalenceIdFam14To15 {
    stepping    : 4;
    model_lo    : 4;
    model_hi    : 3;
    unencrypted : 1;  // bit 11, set on the plaintext copy
    family_ext  : 4;
} [[format("format_equivalence_id_fam14to15")]];

fn format_equivalence_id_fam14to15(EquivalenceIdFam14To15 id) {
    return std::format("{} - body {}",
                       format_cpuid(0xF + id.family_ext,
                                    (id.model_hi << 4) | id.model_lo,
                                    id.stepping),
                       id.unencrypted ? "plaintext" : "encrypted");
};

struct HeaderDataFam14To15 {
    u8                     unknown0[14];    // 0x0A  zero across the corpus
    EquivalenceIdFam14To15 equivalence_id;  // 0x18
    u8                     unknown1[6];     // 0x1A
};

// Zen 3 (0x19) and Zen 5 (0x1A): the default layout, except that these families
// put two fields of their own in the span their predecessors leave zero -- the
// patch's own size, and the patch level it expects to supersede. Either reads
// zero on a patch that declares none.

// The patch's total size, counted in 16-byte units.
using PatchSizeUnits = u16 [[format("format_patch_size_units")]];

fn format_patch_size_units(u16 value) {
    str text = std::format("{} ({} bytes)", value, value * 16);
    if (value == 0)
        text = "not declared";
    return text;
};

// The patch level this patch expects to supersede. Where declared it names the
// same processor as the patch's own level, and is always lower than it.
using RequiredPatchLevel = u32 [[format("format_required_patch_level")]];

fn format_required_patch_level(u32 value) {
    str text = format_patch_level(value);
    if (value == 0)
        text = "not declared";
    return text;
};

struct HeaderDataFam19To1A {
    PatchSizeUnits     patch_size_units;      // 0x0A
    RequiredPatchLevel required_patch_level;  // 0x0C
    u8                 unknown0[8];           // 0x10
    UcodeCpuId         cpuid;                 // 0x18
    u8                 unknown1[6];           // 0x1A
};

// Every other family: only the CPUID field is modelled, the rest kept verbatim.
struct HeaderDataDefault {
    u8         unknown0[14];  // 0x0A
    UcodeCpuId cpuid;         // 0x18
    u8         unknown1[6];   // 0x1A
};


// ---------------------------------------------------------------------------
// Signature slot (offset 0x20)
// ---------------------------------------------------------------------------

// The Jaguar 576-byte block. Unlike the Zen block it is not RSA, and its
// internal structure is unknown, so it is kept verbatim.
struct SignatureFam16 {
    u8 data[576];
};

// The 768-byte Zen block. AMD signs the AES-CMAC of the body rather than a hash
// of it, so verifying a patch needs a CMAC key as well as the modulus embedded
// here.
struct SignatureFam17Plus {
    u8 signature[256];  // RSA-2048 signature (PKCS#1 v1.5, e = 0x10001)
    u8 modulus[256];    // RSA-2048 public modulus embedded in the patch
    u8 check[256];      // Montgomery helper derived from the modulus
};

// The families with a signature slot, which are exactly those with a body
// header too.
fn family_is_signed(u32 family) {
    return family == 0x16 || family == 0x17 || family == 0x19 || family == 0x1A;
};


// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

struct AmdUcodeHeader {
    PatchDate  date;         // 0x00
    PatchLevel patch_level;  // 0x04
    LoaderId   loader_id;    // 0x08
    // 0x0A: the 22-byte data region, laid out per family.
    match (patch_level_family(patch_level)) {
        (0x0F | 0x10 | 0x11 | 0x12): HeaderDataFam0fTo12 data;
        (0x14 | 0x15):               HeaderDataFam14To15 data;
        (0x19 | 0x1A):               HeaderDataFam19To1A data;
        (_):                         HeaderDataDefault   data;
    }
    // 0x20: the signature slot, on the families that have one.
    match (patch_level_family(patch_level)) {
        (0x16):               SignatureFam16     signature;
        (0x17 | 0x19 | 0x1A): SignatureFam17Plus signature;
    }
};


// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

// The 8-byte body header a signed patch body opens with. Every layout opens
// with the same two flag bytes and closes with a copy of the header's patch
// level; the families differ only in the two bytes between them.

// Jaguar (0x16), Zen 1-2 (0x17) and Zen 3-4 (0x19) leave that span unmodelled;
// across the corpus it is always zero.
struct BodyHeaderFam16To19 {
    u8         init_flag;    // 0x00  zentool "autorun"; the pre-Zen init_flag
    u8         encrypted;    // 0x01  whether the microcode that follows is encrypted
    u8         unknown1;     // 0x02
    u8         unknown2;     // 0x03
    PatchLevel patch_level;  // 0x04  a copy of the header patch level
};

// Zen 5 (0x1A) fills the same span with a copy of the header's loader id. On
// every family 0x1A patch in the corpus the u16 there equals the header's
// loader id, while every 0x16/0x17/0x19 patch leaves it zero.
struct BodyHeaderFam1A {
    u8         init_flag;    // 0x00  zentool "autorun"; the pre-Zen init_flag
    u8         encrypted;    // 0x01  whether the microcode that follows is encrypted
    LoaderId   loader_id;    // 0x02  a copy of the header loader id
    PatchLevel patch_level;  // 0x04  a copy of the header patch level
};

// How many 32-bit match registers a family opens its body with. A family that
// is not listed here does not open its body with them at all.
fn match_register_count(u32 family) {
    u32 count = 0;
    match (family) {
        (0x0F | 0x10 | 0x11 | 0x12): count = 8;
        (0x17):                      count = 22;
        (0x19):                      count = 38;
        (0x1A):                      count = 60;
    }
    return count;
};

fn format_match_slot(u32 address, u32 in_use) {
    str text = "unused";
    if (in_use != 0)
        text = std::format("ROM address {:#06x}", address);
    return text;
};

// Families 0x0F-0x12 pack one 16-bit ROM address per register, in its low half.
// These carry no in-use flag: a free slot is marked by the address itself
// reading 0xFFFF.
using MatchRegister = u32 [[format("format_match_register")]];

fn format_match_register(u32 value) {
    u32 address = value & 0xFFFF;
    return std::format("{:08X} - {}", value,
                       format_match_slot(address, address != 0xFFFF));
};

// The Zen families pack two 13-bit ROM addresses per register, each followed by
// its own in-use flag, with four unused bits at the top. A slot is free when
// its flag is clear, whatever address it holds.
bitfield MatchRegisterPair {
    address0 : 13;
    in_use0  : 1;
    address1 : 13;
    in_use1  : 1;
    unused   : 4;
} [[format("format_match_register_pair")]];

fn format_match_register_pair(MatchRegisterPair registers) {
    return std::format("{} | {}",
                       format_match_slot(registers.address0, registers.in_use0),
                       format_match_slot(registers.address1, registers.in_use1));
};

// Microcode is stored as a repeating group: a fixed number of 64-bit micro-ops
// followed by a 32-bit sequence control word saying where execution goes next.
// Families 0x0F-0x12 group their ops in threes (a triad), the Zen families in
// fours (a quad). Neither the ops nor the control word are decoded further yet.
struct OpTriad {
    u64 ops[3];
    u32 sequence_word;
};

struct OpQuad {
    u64 ops[4];
    u32 sequence_word;
};

// Families 0x0F-0x12: the match registers, then the micro-op triad array the
// header counts in `op_triad_count` and sums in `op_triad_checksum`. A real
// array divides exactly into triads, so `trailing` only ever shows up on a
// short or padded patch.
struct BodyDataFam0fTo12<auto family, auto size> {
    u64 begin = $;
    MatchRegister match_registers[match_register_count(family)];
    u64 rest = size - ($ - begin);
    if (rest >= sizeof(OpTriad))
        OpTriad op_triads[rest / sizeof(OpTriad)];
    if (rest % sizeof(OpTriad) != 0)
        u8 trailing[rest % sizeof(OpTriad)];
};

// Bobcat (0x14) and Bulldozer (0x15) open their body with a 16-byte frame that
// ends in a copy of the header's patch level. The frame sits inside the region
// the encrypted variants encrypt, so it only reads back on a plaintext body: a
// zero `reserved` and a mirrored patch level are a second, structural opinion
// that the body really is in the clear.
struct BodyDataFam14To15<auto size> {
    u64 begin = $;
    u8         unknown0[8];   // 0x00
    u32        reserved;      // 0x08  zero on a plaintext body
    PatchLevel patch_level;   // 0x0C  a copy of the header patch level
    u64 rest = size - ($ - begin);
    // The microcode past the frame: not yet modelled, kept verbatim.
    if (rest > 0)
        u8 unknown1[rest];
};

// The Zen families: the match registers, then the micro-op quad array. Nothing
// in the header counts the quads, so the array itself is the only record of how
// many there are.
struct BodyDataFam17Plus<auto family, auto size> {
    u64 begin = $;
    MatchRegisterPair match_registers[match_register_count(family)];
    u64 rest = size - ($ - begin);
    if (rest >= sizeof(OpQuad))
        OpQuad op_quads[rest / sizeof(OpQuad)];
    if (rest % sizeof(OpQuad) != 0)
        u8 trailing[rest % sizeof(OpQuad)];
};

// Everything after the header. `headerEncrypted` is the patch header verdict on
// whether the body is encrypted: 0 or 1 where the header carries that signal
// (families 0x14/0x15, in their equivalence id), and -1 where it has no opinion
// and the body header has to answer instead.
struct AmdUcodeBody<auto family, auto headerEncrypted, auto totalSize> {
    u64 begin = $;
    // The body header, on the families that carry one -- exactly those with a
    // signature slot.
    match (family) {
        (0x16 | 0x17 | 0x19): BodyHeaderFam16To19 body_header;
        (0x1A):               BodyHeaderFam1A     body_header;
    }
    bool encrypted = headerEncrypted >= 0
                   ? headerEncrypted != 0
                   : (family_is_signed(family) && body_header.encrypted != 0);
    u64 rest = totalSize - ($ - begin);
    if (encrypted) {
        // Opaque: there is nothing to model until it is decrypted.
        u8 data[rest];
    } else {
        match (family) {
            (0x0F | 0x10 | 0x11 | 0x12): BodyDataFam0fTo12<family, rest> data;
            (0x14 | 0x15):               BodyDataFam14To15<rest>         data;
            (0x17 | 0x19 | 0x1A):        BodyDataFam17Plus<family, rest> data;
            // Jaguar, and anything unrecognised: plaintext, but not modelled.
            (_):                         u8 data[rest];
        }
    }
};


// ---------------------------------------------------------------------------
// Patch
// ---------------------------------------------------------------------------

// A whole patch, sized to `totalSize` bytes so it can be reused when the patch
// is embedded in a container (pass the section size) or parsed standalone (pass
// the file size).
struct AmdUcodePatch<auto totalSize> {
    u64 begin = $;
    AmdUcodeHeader header;
    u32 family = patch_level_family(header.patch_level);
    // -1 unless the header itself declares whether the body is encrypted.
    s32 header_encrypted = -1;
    if (family == 0x14 || family == 0x15)
        header_encrypted = header.data.equivalence_id.unencrypted ? 0 : 1;
    AmdUcodeBody<family, header_encrypted, totalSize - ($ - begin)> body;
};

// Define AMD_UCODE_PATCH_USE_LIB before including this file to reuse the types
// above without placing a patch at offset 0 (e.g. from the container pattern).
#ifndef AMD_UCODE_PATCH_USE_LIB
AmdUcodePatch<std::mem::size()> patch @ 0x00;
#endif
