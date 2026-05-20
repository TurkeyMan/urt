/// POSIX exception driver - stack-trace capture/print via ELF + DWARF.
///
/// Uses _Unwind_Backtrace (ARM/AArch64/RISC-V) or inline-asm RBP walking
/// (x86/x86_64) for capture. Symbol resolution via dladdr; file:line via
/// .debug_line (DWARF v3/4/5). Ported from druntime's
/// core.internal.backtrace.{dwarf,elf} and core.internal.elf.{io,dl}.
///
/// The DWARF exception-handling runtime (_d_throw_exception, personality
/// function, etc.) lives in urt.internal.dwarfeh so it compiles on bare-
/// metal builds too where urt.driver.posix.exception is not in the source list.
module urt.driver.posix.exception;

// Windows has its own driver; BareMetal has its own. Everything else
// (Linux, macOS, BSD) lands here. Compiled always (not just `debug`)
// so allocation-site tracking works in release builds.
version (Windows) {} else version (BareMetal) {} else:

import urt.internal.exception : Resolved, StackTraceData, _d_createTrace, _d_isbaseof, terminate;

import urt.mem : strlen, memcpy;

import urt.internal.sys.posix;

// ===================================================================
//   !!! TODO !!!  THREADING IS NOT SUPPORTED.                        
//                                                                    
//   dladdr is MT-safe but the static scratch buffers used by the     
//   DWARF .debug_line decoder (_dir_scratch, _file_scratch) and the  
//   ELF self-mapping state are not. Add a mutex or per-thread state  
//   before this program can use threads.                             
// ===================================================================

private enum SEEK_END = 2;

// --- _Unwind_Backtrace capture (ARM, AArch64, RISC-V) ------------

version (D_InlineAsm_X86_64) {} else version (D_InlineAsm_X86) {} else
{
    private alias _Unwind_Trace_Fn = extern(C) int function(void* ctx, void* data) nothrow @nogc;

    extern(C) private int _Unwind_Backtrace(_Unwind_Trace_Fn, void*) nothrow @nogc;
    extern(C) private size_t _Unwind_GetIP(void*) nothrow @nogc;

    private struct UnwindState { StackTraceData* trace; ubyte skip; }

    extern(C) private int unwind_trace_callback(void* ctx, void* data) nothrow @nogc
    {
        auto s = cast(UnwindState*) data;
        if (s.skip > 0) { s.skip--; return 0; }
        if (s.trace.length >= 32) return 1;
        auto ip = _Unwind_GetIP(ctx);
        if (!ip) return 1;
        s.trace.addrs[s.trace.length++] = cast(void*) ip;
        return 0;
    }

    private void unwind_backtrace(ref StackTraceData trace) nothrow @nogc @trusted
    {
        UnwindState state = UnwindState(&trace, 2);
        _Unwind_Backtrace(&unwind_trace_callback, &state);
    }
}

// --- Minimal ELF types --------------------------------------------

version (D_LP64)
{
    private struct Elf_Ehdr
    {
        ubyte[16] e_ident;
        ushort e_type;
        ushort e_machine;
        uint   e_version;
        ulong  e_entry;
        ulong  e_phoff;
        ulong  e_shoff;
        uint   e_flags;
        ushort e_ehsize;
        ushort e_phentsize;
        ushort e_phnum;
        ushort e_shentsize;
        ushort e_shnum;
        ushort e_shstrndx;
    }

    private struct Elf_Shdr
    {
        uint   sh_name;
        uint   sh_type;
        ulong  sh_flags;
        ulong  sh_addr;
        ulong  sh_offset;
        ulong  sh_size;
        uint   sh_link;
        uint   sh_info;
        ulong  sh_addralign;
        ulong  sh_entsize;
    }

    private struct Elf_Phdr
    {
        uint   p_type;
        uint   p_flags;
        ulong  p_offset;
        ulong  p_vaddr;
        ulong  p_paddr;
        ulong  p_filesz;
        ulong  p_memsz;
        ulong  p_align;
    }
}
else
{
    private struct Elf_Ehdr
    {
        ubyte[16] e_ident;
        ushort e_type;
        ushort e_machine;
        uint   e_version;
        uint   e_entry;
        uint   e_phoff;
        uint   e_shoff;
        uint   e_flags;
        ushort e_ehsize;
        ushort e_phentsize;
        ushort e_phnum;
        ushort e_shentsize;
        ushort e_shnum;
        ushort e_shstrndx;
    }

    private struct Elf_Shdr
    {
        uint sh_name;
        uint sh_type;
        uint sh_flags;
        uint sh_addr;
        uint sh_offset;
        uint sh_size;
        uint sh_link;
        uint sh_info;
        uint sh_addralign;
        uint sh_entsize;
    }

    private struct Elf_Phdr
    {
        uint p_type;
        uint p_offset;
        uint p_vaddr;
        uint p_paddr;
        uint p_filesz;
        uint p_memsz;
        uint p_flags;
        uint p_align;
    }
}

private enum EI_MAG0   = 0;
private enum EI_CLASS  = 4;
private enum EI_DATA   = 5;
private enum ELFMAG    = "\x7fELF";
private enum ET_DYN    = 3;
private enum SHF_COMPRESSED = 0x800;

version (D_LP64)
    private enum ELFCLASS_NATIVE = 2; // ELFCLASS64
else
    private enum ELFCLASS_NATIVE = 1; // ELFCLASS32

version (LittleEndian)
    private enum ELFDATA_NATIVE = 1; // ELFDATA2LSB
else
    private enum ELFDATA_NATIVE = 2; // ELFDATA2MSB

// --- dl_iterate_phdr for base address -----------------------------

private struct dl_phdr_info
{
    size_t         dlpi_addr;
    const(char)*   dlpi_name;
    const(Elf_Phdr)* dlpi_phdr;
    ushort         dlpi_phnum;
}

private alias dl_iterate_phdr_callback_t = extern(C) int function(dl_phdr_info*, size_t, void*) nothrow @nogc;

extern(C) private int dl_iterate_phdr(dl_iterate_phdr_callback_t callback, void* data) nothrow @nogc;

private size_t get_executable_base_address() nothrow @nogc @trusted
{
    size_t result = 0;

    extern(C) static int callback(dl_phdr_info* info, size_t, void* data) nothrow @nogc
    {
        // First entry is the executable itself
        *cast(size_t*) data = info.dlpi_addr;
        return 1; // stop iteration
    }

    dl_iterate_phdr(&callback, &result);
    return result;
}

// --- Memory-mapped file region ------------------------------------

private struct MappedRegion
{
    const(ubyte)* data;
    size_t mapped_size;

nothrow @nogc @trusted:

    static MappedRegion map(int fd, size_t offset, size_t length)
    {
        if (fd == -1 || length == 0)
            return MappedRegion.init;

        auto pgsz = cast(size_t) sysconf(_SC_PAGE_SIZE);
        if (cast(int) pgsz <= 0)
            pgsz = 4096;

        const page_off = offset / pgsz;
        const diff = offset - page_off * pgsz;
        const needed = length + diff;
        const pages = (needed + pgsz - 1) / pgsz;
        const msize = pages * pgsz;

        auto p = mmap(null, msize, PROT_READ, MAP_PRIVATE, fd, cast(off_t)(page_off * pgsz));
        if (p is MAP_FAILED)
            return MappedRegion.init;

        return MappedRegion(cast(const(ubyte)*) p + diff, msize);
    }

    void unmap()
    {
        if (data !is null)
        {
            auto pgsz = cast(size_t) sysconf(_SC_PAGE_SIZE);
            if (cast(int) pgsz <= 0)
                pgsz = 4096;
            // Align back to page boundary
            auto base = cast(void*)(cast(size_t) data & ~(pgsz - 1));
            munmap(base, mapped_size);
            data = null;
        }
    }
}

// --- ELF self-reader ----------------------------------------------

private struct ElfSelf
{
    int fd = -1;
    MappedRegion ehdr_region;
    const(Elf_Ehdr)* ehdr;

nothrow @nogc @trusted:

    static ElfSelf open()
    {
        ElfSelf self;

        // Read /proc/self/exe path
        char[512] pathbuf = void;
        auto n = readlink("/proc/self/exe", pathbuf.ptr, pathbuf.length - 1);
        if (n <= 0)
            return self;
        pathbuf[n] = 0;

        self.fd = .open(pathbuf.ptr, O_RDONLY);
        if (self.fd == -1)
            return self;

        // Map the ELF header
        self.ehdr_region = MappedRegion.map(self.fd, 0, Elf_Ehdr.sizeof);
        if (self.ehdr_region.data is null)
        {
            .close(self.fd);
            self.fd = -1;
            return self;
        }

        self.ehdr = cast(const(Elf_Ehdr)*) self.ehdr_region.data;

        // Validate ELF magic, class, and byte order
        if (self.ehdr.e_ident[0..4] != cast(const(ubyte)[4]) ELFMAG
            || self.ehdr.e_ident[EI_CLASS] != ELFCLASS_NATIVE
            || self.ehdr.e_ident[EI_DATA] != ELFDATA_NATIVE)
        {
            self.close();
            return ElfSelf.init;
        }

        return self;
    }

    void close()
    {
        ehdr_region.unmap();
        ehdr = null;
        if (fd != -1) { .close(fd); fd = -1; }
    }

    bool valid() const { return fd != -1 && ehdr !is null; }

    /// Find a section by name, return its offset and size.
    bool find_section(const(char)[] name, out size_t offset, out size_t size)
    {
        if (!valid())
            return false;

        // Map section headers
        auto shdr_total = cast(size_t) ehdr.e_shnum * Elf_Shdr.sizeof;
        auto shdr_region = MappedRegion.map(fd, cast(size_t) ehdr.e_shoff, shdr_total);
        if (shdr_region.data is null)
            return false;
        scope(exit) shdr_region.unmap();

        auto shdrs = (cast(const(Elf_Shdr)*) shdr_region.data)[0 .. ehdr.e_shnum];

        // Map string table section
        if (ehdr.e_shstrndx >= ehdr.e_shnum)
            return false;
        auto strtab_shdr = &shdrs[ehdr.e_shstrndx];
        auto strtab_region = MappedRegion.map(fd,
            cast(size_t) strtab_shdr.sh_offset,
            cast(size_t) strtab_shdr.sh_size);
        if (strtab_region.data is null)
            return false;
        scope(exit) strtab_region.unmap();

        auto strtab = cast(const(char)*) strtab_region.data;

        // Search for the named section
        foreach (ref shdr; shdrs)
        {
            if (shdr.sh_name >= strtab_shdr.sh_size)
                continue;
            auto sec_name = strtab + shdr.sh_name;
            auto sec_name_len = strlen(sec_name);
            if (sec_name_len == name.length && sec_name[0 .. sec_name_len] == name)
            {
                if (shdr.sh_flags & SHF_COMPRESSED)
                    return false; // compressed debug sections not supported
                offset = cast(size_t) shdr.sh_offset;
                size = cast(size_t) shdr.sh_size;
                return true;
            }
        }
        return false;
    }
}

// --- DWARF .debug_line types and constants ------------------------

private struct LocationInfo
{
    int file = -1;
    int line = -1;
}

private struct SourceFile
{
    const(char)[] file;
    size_t dir_index; // 1-based
}

private struct LineNumberProgram
{
    ulong unit_length;
    ushort dwarf_version;
    ubyte address_size;
    ubyte segment_selector_size;
    ulong header_length;
    ubyte minimum_instruction_length;
    ubyte maximum_operations_per_instruction;
    bool  default_is_statement;
    byte  line_base;
    ubyte line_range;
    ubyte opcode_base;
    const(ubyte)[] standard_opcode_lengths;
    // Directory and file tables stored as slices into scratch buffers.
    // The caller owns the scratch; the LineNumberProgram just borrows.
    const(char)[][] include_directories;
    size_t num_dirs;
    SourceFile[] source_files;
    size_t num_files;
    const(ubyte)[] program;
}

private struct StateMachine
{
    const(void)* address;
    uint operation_index = 0;
    uint file_index = 1;
    int  line = 1;
    uint column = 0;
    bool is_statement;
    bool is_end_sequence = false;
}

private enum StandardOpcode : ubyte
{
    extended_op = 0,
    copy = 1,
    advance_pc = 2,
    advance_line = 3,
    set_file = 4,
    set_column = 5,
    negate_statement = 6,
    set_basic_block = 7,
    const_add_pc = 8,
    fixed_advance_pc = 9,
    set_prologue_end = 10,
    set_epilogue_begin = 11,
    set_isa = 12,
}

private enum ExtendedOpcode : ubyte
{
    end_sequence = 1,
    set_address = 2,
    define_file = 3,
    set_discriminator = 4,
}

// --- LEB128 and DWARF helpers -------------------------------------

private T dw_read(T)(ref const(ubyte)[] buf) nothrow @nogc @trusted
{
    if (buf.length < T.sizeof)
        return T.init;
    version (X86_64)
        T result = *cast(const(T)*) buf.ptr;
    else version (X86)
        T result = *cast(const(T)*) buf.ptr;
    else
    {
        T result = void;
        memcpy(&result, buf.ptr, T.sizeof);
    }
    buf = buf[T.sizeof .. $];
    return result;
}

private const(char)[] dw_read_stringz(ref const(ubyte)[] buf) nothrow @nogc @trusted
{
    auto p = cast(const(char)*) buf.ptr;
    auto len = strlen(p);
    buf = buf[len + 1 .. $];
    return p[0 .. len];
}

private ulong dw_read_uleb128(ref const(ubyte)[] buf) nothrow @nogc
{
    ulong val = 0;
    uint shift = 0;
    while (buf.length > 0)
    {
        ubyte b = buf[0]; buf = buf[1 .. $];
        val |= cast(ulong)(b & 0x7f) << shift;
        if ((b & 0x80) == 0) break;
        shift += 7;
    }
    return val;
}

private long dw_read_sleb128(ref const(ubyte)[] buf) nothrow @nogc
{
    long val = 0;
    uint shift = 0;
    ubyte b;
    while (buf.length > 0)
    {
        b = buf[0]; buf = buf[1 .. $];
        val |= cast(long)(b & 0x7f) << shift;
        shift += 7;
        if ((b & 0x80) == 0) break;
    }
    if (shift < 64 && (b & 0x40) != 0)
        val |= -(cast(long) 1 << shift);
    return val;
}

// --- DWARF v5 entry format ----------------------------------------

private enum DW_LNCT : ushort
{
    path = 1,
    directory_index = 2,
}

private enum DW_FORM : ubyte
{
    data1 = 11,
    data2 = 5,
    data4 = 6,
    data8 = 7,
    data16 = 30,
    string_ = 8,
    strp = 14,
    line_strp = 31,
    udata = 15,
    block = 9,
    strx = 26,
    strx1 = 37,
    strx2 = 38,
    strx3 = 39,
    strx4 = 40,
    sec_offset = 23,
    sdata = 13,
    flag = 12,
    flag_present = 25,
}

private struct EntryFormatPair
{
    DW_LNCT type;
    DW_FORM form;
}

/// Skip a DWARF form value we don't care about.
private void dw_skip_form(ref const(ubyte)[] data, DW_FORM form, bool is64bit) nothrow @nogc
{
    with (DW_FORM) switch (form)
    {
        case strp, line_strp, sec_offset:
            data = data[is64bit ? 8 : 4 .. $]; break;
        case data1, strx1, flag, flag_present:
            data = data[1 .. $]; break;
        case data2, strx2:
            data = data[2 .. $]; break;
        case strx3:
            data = data[3 .. $]; break;
        case data4, strx4:
            data = data[4 .. $]; break;
        case data8:
            data = data[8 .. $]; break;
        case data16:
            data = data[16 .. $]; break;
        case udata, strx, sdata:
            dw_read_uleb128(data); break;
        case block:
            auto length = cast(size_t) dw_read_uleb128(data);
            data = data[length .. $]; break;
        default:
            break;
    }
}

// --- Read DWARF line number program header ------------------------

// Scratch buffers allocated on the stack for directory/file tables.
// 256 entries each should be more than enough for any compilation unit.
private enum MAX_DIRS  = 256;
private enum MAX_FILES = 512;

private LineNumberProgram dw_read_line_number_program(ref const(ubyte)[] data) nothrow @nogc @trusted
{
    const original_data = data;
    LineNumberProgram lp;

    bool is_64bit_dwarf = false;
    lp.unit_length = dw_read!uint(data);
    if (lp.unit_length == uint.max)
    {
        is_64bit_dwarf = true;
        lp.unit_length = dw_read!ulong(data);
    }

    const version_field_offset = cast(size_t)(data.ptr - original_data.ptr);
    lp.dwarf_version = dw_read!ushort(data);

    if (lp.dwarf_version >= 5)
    {
        lp.address_size = dw_read!ubyte(data);
        lp.segment_selector_size = dw_read!ubyte(data);
    }

    lp.header_length = is_64bit_dwarf ? dw_read!ulong(data) : dw_read!uint(data);

    const min_insn_field_offset = cast(size_t)(data.ptr - original_data.ptr);
    lp.minimum_instruction_length = dw_read!ubyte(data);
    lp.maximum_operations_per_instruction = (lp.dwarf_version >= 4) ? dw_read!ubyte(data) : 1;
    lp.default_is_statement = (dw_read!ubyte(data) != 0);
    lp.line_base = dw_read!byte(data);
    lp.line_range = dw_read!ubyte(data);
    lp.opcode_base = dw_read!ubyte(data);

    lp.standard_opcode_lengths = data[0 .. lp.opcode_base - 1];
    data = data[lp.opcode_base - 1 .. $];

    if (lp.dwarf_version >= 5)
    {
        // DWARF v5: directory format + entries
        auto num_pairs = dw_read!ubyte(data);
        EntryFormatPair[8] dir_fmt = void;
        foreach (i; 0 .. num_pairs)
        {
            if (i < 8)
            {
                dir_fmt[i].type = cast(DW_LNCT) dw_read_uleb128(data);
                dir_fmt[i].form = cast(DW_FORM) dw_read_uleb128(data);
            }
        }

        lp.num_dirs = cast(size_t) dw_read_uleb128(data);
        // Caller must provide scratch buffers; we use __gshared static for simplicity.
        foreach (d; 0 .. lp.num_dirs)
        {
            foreach (p; 0 .. num_pairs)
            {
                if (p < 8 && dir_fmt[p].type == DW_LNCT.path && dir_fmt[p].form == DW_FORM.string_)
                {
                    if (d < MAX_DIRS)
                        _dir_scratch[d] = dw_read_stringz(data);
                    else
                        dw_read_stringz(data);
                }
                else if (p < 8)
                    dw_skip_form(data, dir_fmt[p].form, is_64bit_dwarf);
            }
        }
        if (lp.num_dirs > MAX_DIRS) lp.num_dirs = MAX_DIRS;
        lp.include_directories = _dir_scratch[0 .. lp.num_dirs];

        // File format + entries
        num_pairs = dw_read!ubyte(data);
        EntryFormatPair[8] file_fmt = void;
        foreach (i; 0 .. num_pairs)
        {
            if (i < 8)
            {
                file_fmt[i].type = cast(DW_LNCT) dw_read_uleb128(data);
                file_fmt[i].form = cast(DW_FORM) dw_read_uleb128(data);
            }
        }

        lp.num_files = cast(size_t) dw_read_uleb128(data);
        foreach (f; 0 .. lp.num_files)
        {
            SourceFile sf;
            sf.file = "<unknown>";
            foreach (p; 0 .. num_pairs)
            {
                if (p < 8 && file_fmt[p].type == DW_LNCT.path && file_fmt[p].form == DW_FORM.string_)
                    sf.file = dw_read_stringz(data);
                else if (p < 8 && file_fmt[p].type == DW_LNCT.directory_index)
                {
                    if (file_fmt[p].form == DW_FORM.data1)
                        sf.dir_index = dw_read!ubyte(data);
                    else if (file_fmt[p].form == DW_FORM.data2)
                        sf.dir_index = dw_read!ushort(data);
                    else if (file_fmt[p].form == DW_FORM.udata)
                        sf.dir_index = cast(size_t) dw_read_uleb128(data);
                    else
                        dw_skip_form(data, file_fmt[p].form, is_64bit_dwarf);
                    sf.dir_index++; // DWARF v5 indices are 0-based, normalize to 1-based
                }
                else if (p < 8)
                    dw_skip_form(data, file_fmt[p].form, is_64bit_dwarf);
            }
            if (f < MAX_FILES)
                _file_scratch[f] = sf;
        }
        if (lp.num_files > MAX_FILES) lp.num_files = MAX_FILES;
        lp.source_files = _file_scratch[0 .. lp.num_files];
    }
    else
    {
        // DWARF v3/v4: NUL-terminated sequences
        lp.num_dirs = 0;
        while (data.length > 0 && data[0] != 0)
        {
            auto dir = dw_read_stringz(data);
            if (lp.num_dirs < MAX_DIRS)
                _dir_scratch[lp.num_dirs++] = dir;
        }
        if (data.length > 0) data = data[1 .. $]; // skip NUL terminator
        lp.include_directories = _dir_scratch[0 .. lp.num_dirs];

        lp.num_files = 0;
        while (data.length > 0 && data[0] != 0)
        {
            SourceFile sf;
            sf.file = dw_read_stringz(data);
            sf.dir_index = cast(size_t) dw_read_uleb128(data);
            dw_read_uleb128(data); // last modification time
            dw_read_uleb128(data); // file length
            if (lp.num_files < MAX_FILES)
                _file_scratch[lp.num_files++] = sf;
        }
        if (data.length > 0) data = data[1 .. $]; // skip NUL terminator
        lp.source_files = _file_scratch[0 .. lp.num_files];
    }

    const program_start = cast(size_t)(min_insn_field_offset + lp.header_length);
    const program_end = cast(size_t)(version_field_offset + lp.unit_length);
    if (program_start <= original_data.length && program_end <= original_data.length)
        lp.program = original_data[program_start .. program_end];

    data = (program_end <= original_data.length) ? original_data[program_end .. $] : null;

    return lp;
}

// Static scratch buffers for DWARF parsing (debug-only, no allocator needed).
private __gshared const(char)[][MAX_DIRS] _dir_scratch;
private __gshared SourceFile[MAX_FILES] _file_scratch;

// --- DWARF state machine - resolve addresses to file:line ---------

private struct ResolvedLocation
{
    const(char)[] file;
    const(char)[] dir;
    int line = -1;
}

/// Resolve an array of addresses to file:line using .debug_line data.
private void dw_resolve_addresses(
    const(ubyte)[] debug_line_data,
    const(void*)[] addresses,
    ResolvedLocation[] results,
    size_t base_address) nothrow @nogc @trusted
{
    size_t found = 0;
    const num_addrs = addresses.length;

    while (debug_line_data.length > 0 && found < num_addrs)
    {
        auto lp = dw_read_line_number_program(debug_line_data);
        if (lp.program.length == 0)
            break;

        StateMachine machine;
        machine.is_statement = lp.default_is_statement;

        LocationInfo last_loc = LocationInfo(-1, -1);
        const(void)* last_address;

        const(ubyte)[] prog = lp.program;
        while (prog.length > 0)
        {
            size_t advance_addr(size_t op_advance)
            {
                const inc = lp.minimum_instruction_length *
                    ((machine.operation_index + op_advance) / lp.maximum_operations_per_instruction);
                machine.address += inc;
                machine.operation_index =
                    (machine.operation_index + op_advance) % lp.maximum_operations_per_instruction;
                return inc;
            }

            void emit_row(bool is_end)
            {
                auto addr = machine.address + base_address;

                foreach (idx; 0 .. num_addrs)
                {
                    if (results[idx].line != -1)
                        continue;
                    auto target = addresses[idx];

                    void apply_loc(LocationInfo loc)
                    {
                        auto file_idx = loc.file - (lp.dwarf_version < 5 ? 1 : 0);
                        if (file_idx >= 0 && file_idx < lp.num_files)
                        {
                            results[idx].file = lp.source_files[file_idx].file;
                            auto di = lp.source_files[file_idx].dir_index;
                            if (di > 0 && di <= lp.num_dirs)
                                results[idx].dir = lp.include_directories[di - 1];
                        }
                        results[idx].line = loc.line;
                        found++;
                    }

                    if (target == addr)
                        apply_loc(LocationInfo(machine.file_index, machine.line));
                    else if (last_address !is null && target > last_address && target < addr)
                        apply_loc(last_loc);
                }

                if (is_end)
                    last_address = null;
                else
                {
                    last_address = addr;
                    last_loc = LocationInfo(machine.file_index, machine.line);
                }
            }

            ubyte opcode = prog[0]; prog = prog[1 .. $];

            if (opcode >= lp.opcode_base)
            {
                // Special opcode
                opcode -= lp.opcode_base;
                advance_addr(opcode / lp.line_range);
                machine.line += lp.line_base + (opcode % lp.line_range);
                emit_row(false);
            }
            else if (opcode == 0)
            {
                // Extended opcode
                auto len = cast(size_t) dw_read_uleb128(prog);
                if (prog.length == 0) break;
                ubyte eopcode = prog[0]; prog = prog[1 .. $];

                switch (eopcode)
                {
                    case ExtendedOpcode.end_sequence:
                        machine.is_end_sequence = true;
                        emit_row(true);
                        machine = StateMachine.init;
                        machine.is_statement = lp.default_is_statement;
                        break;
                    case ExtendedOpcode.set_address:
                        machine.address = dw_read!(const(void)*)(prog);
                        machine.operation_index = 0;
                        break;
                    case ExtendedOpcode.set_discriminator:
                        dw_read_uleb128(prog);
                        break;
                    default:
                        if (len > 1)
                            prog = prog[len - 1 .. $];
                        break;
                }
            }
            else switch (opcode) with (StandardOpcode)
            {
                case copy:
                    emit_row(false);
                    break;
                case advance_pc:
                    advance_addr(cast(size_t) dw_read_uleb128(prog));
                    break;
                case advance_line:
                    machine.line += cast(int) dw_read_sleb128(prog);
                    break;
                case set_file:
                    machine.file_index = cast(uint) dw_read_uleb128(prog);
                    break;
                case set_column:
                    machine.column = cast(uint) dw_read_uleb128(prog);
                    break;
                case negate_statement:
                    machine.is_statement = !machine.is_statement;
                    break;
                case set_basic_block:
                    break;
                case const_add_pc:
                    advance_addr((255 - lp.opcode_base) / lp.line_range);
                    break;
                case fixed_advance_pc:
                    machine.address += dw_read!ushort(prog);
                    machine.operation_index = 0;
                    break;
                case set_prologue_end:
                case set_epilogue_begin:
                    break;
                case set_isa:
                    dw_read_uleb128(prog);
                    break;
                default:
                    // Unknown standard opcode: skip according to standard_opcode_lengths
                    if (opcode > 0 && opcode <= lp.standard_opcode_lengths.length)
                    {
                        foreach (_; 0 .. lp.standard_opcode_lengths[opcode - 1])
                            dw_read_uleb128(prog);
                    }
                    break;
            }
        }
    }
}




// --- Driver interface --------------------------------------------------
//
// All three primitives assume they are called through a one-level public
// wrapper in urt.internal.exception (kept non-inlined via pragma(inline,
// false)). The wrapper's frame is accounted for in the skip counts
// below. Direct callers (like _d_createTrace) get the same semantics
// because their frame substitutes for the wrapper's.

/// Capture the caller's call stack. First entry = return address of
/// the function that called the public `capture_trace` wrapper.
size_t _capture_trace(void*[] addrs) nothrow @nogc @trusted
{
    if (addrs.length == 0)
        return 0;

    version (D_InlineAsm_X86_64)
    {
        size_t bp;
        asm nothrow @nogc { mov bp, RBP; }
        // Walk from _capture_trace's own frame up, storing caller frames.
        size_t n = 0;
        // Skip one: our own frame so first captured is wrapper/caller.
        if (bp)
        {
            auto next = *cast(size_t*) bp;
            if (next > bp) bp = next;
            else bp = 0;
        }
        while (n < addrs.length)
        {
            if (!bp) break;
            auto next_bp = *cast(size_t*) bp;
            if (!next_bp || next_bp <= bp) break;
            auto retaddr = *cast(void**)(bp + size_t.sizeof);
            if (!retaddr) break;
            addrs[n++] = retaddr;
            bp = next_bp;
        }
        return n;
    }
    else version (D_InlineAsm_X86)
    {
        size_t bp;
        asm nothrow @nogc { mov bp, EBP; }
        size_t n = 0;
        if (bp)
        {
            auto next = *cast(size_t*) bp;
            if (next > bp) bp = next;
            else bp = 0;
        }
        while (n < addrs.length)
        {
            if (!bp) break;
            auto next_bp = *cast(size_t*) bp;
            if (!next_bp || next_bp <= bp) break;
            auto retaddr = *cast(void**)(bp + size_t.sizeof);
            if (!retaddr) break;
            addrs[n++] = retaddr;
            bp = next_bp;
        }
        return n;
    }
    else
    {
        StackTraceData tmp;
        unwind_backtrace(tmp);  // skips its own frames internally
        auto n = tmp.length < addrs.length ? tmp.length : addrs.length;
        addrs[0 .. n] = tmp.addrs[0 .. n];
        return n;
    }
}

/// Return the return address of the `skip`-th frame above the public
/// `caller_address` wrapper's caller.
void* _caller_address(uint skip) nothrow @nogc @trusted
{
    void*[32] buf = void;
    const n = _capture_trace(buf[]);
    // _capture_trace, when invoked from _caller_address, lays out:
    //   buf[0] = PC inside the public wrapper
    //   buf[1] = PC inside USER (the caller_address caller)
    //   buf[2] = PC inside USER's caller   ← skip=0 wants this
    const want = skip + 2;
    if (n <= want)
        return null;
    return buf[want];
}

/// Resolve via dladdr (symbol name + offset). File/line is omitted -
/// per-address DWARF scans would re-parse .debug_line on every call.
/// For full file:line info, use `_resolve_batch`, which amortises one
/// scan across all frames.
/// Returned `name` slice is owned by dladdr-internal storage - consume
/// before the next call.
bool _resolve_address(void* addr, out Resolved r) nothrow @nogc @trusted
{
    Dl_info info = void;
    if (!dladdr(addr, &info) || info.dli_sname is null)
        return false;
    r.name = info.dli_sname[0 .. strlen(info.dli_sname)];
    r.offset = cast(size_t) addr - cast(size_t) info.dli_saddr;
    return true;
}

// Persistent .debug_line mapping. The first _resolve_batch call opens
// /proc/self/exe, finds .debug_line, mmap()s it, and closes the fd.
// We never unmap - the slice handed back to callers via Resolved.file
// and Resolved.dir points into this region, and the API contract
// promises stability until the next _resolve_batch call. Holding the
// mapping for process lifetime is the cheapest way to satisfy that
// (a few MB of read-only file pages the OS can demand-page).
private __gshared bool _elf_init_attempted;
private __gshared const(ubyte)[] _persistent_debug_line;
private __gshared size_t _persistent_base_addr;

private void ensure_debug_line_mapped() nothrow @nogc @trusted
{
    if (_elf_init_attempted)
        return;
    _elf_init_attempted = true;

    auto elf = ElfSelf.open();
    scope(exit) elf.close();
    if (!elf.valid())
        return;

    size_t dbg_offset, dbg_size;
    if (!elf.find_section(".debug_line", dbg_offset, dbg_size))
        return;

    auto region = MappedRegion.map(elf.fd, dbg_offset, dbg_size);
    if (region.data is null)
        return;
    // Intentionally not unmapped - kept for process lifetime.

    _persistent_debug_line = region.data[0 .. dbg_size];
    _persistent_base_addr  = (elf.ehdr.e_type == ET_DYN)
        ? get_executable_base_address() : cast(size_t) 0;
}

/// Resolve many addresses in one pass: dladdr per address for symbol
/// name + offset, then a single DWARF .debug_line scan to fill file /
/// dir / line for all of them at once.
///
/// String slices point into dladdr-internal storage, the static DWARF
/// scratch buffers (`_dir_scratch`, `_file_scratch`), or the persistent
/// .debug_line mapping. All three remain valid until the next
/// `_resolve_batch` call overwrites the scratch buffers; copy if you
/// need fields to outlive that.
bool _resolve_batch(const(void*)[] addrs, Resolved[] results) nothrow @nogc @trusted
{
    // Symbol + offset via dladdr (per-address; dladdr is O(1)-ish via
    // the dynamic linker's hash tables).
    bool any_resolved = false;
    foreach (i, a; addrs)
    {
        Dl_info info = void;
        if (dladdr(cast(void*) a, &info) && info.dli_sname !is null)
        {
            results[i].name = info.dli_sname[0 .. strlen(info.dli_sname)];
            results[i].offset = cast(size_t) a - cast(size_t) info.dli_saddr;
            any_resolved = true;
        }
    }

    // File / line via one DWARF .debug_line scan covering all addrs.
    // Failures here still leave dladdr-populated name/offset intact.
    ensure_debug_line_mapped();
    if (_persistent_debug_line.length == 0)
        return any_resolved;

    ResolvedLocation[32] locations;
    const n = addrs.length > locations.length ? locations.length : addrs.length;

    dw_resolve_addresses(
        _persistent_debug_line,
        addrs[0 .. n],
        locations[0 .. n],
        _persistent_base_addr);

    foreach (i; 0 .. n)
    {
        if (locations[i].line >= 0)
        {
            results[i].file = locations[i].file;
            results[i].dir  = locations[i].dir;
            results[i].line = cast(uint) locations[i].line;
            any_resolved = true;
        }
    }
    return any_resolved;
}
