pub const Self = @This();

const std = @import("std");

const VirtualProtect = std.os.windows.VirtualProtect;
const VirtualAlloc = std.os.windows.VirtualAlloc;
const VirtualFree = std.os.windows.VirtualFree;
const MEM_COMMIT = std.os.windows.MEM_COMMIT;
const MEM_RESERVE = std.os.windows.MEM_RESERVE;
const MEM_RELEASE = std.os.windows.MEM_RELEASE;
const PAGE_EXECUTE_READWRITE = std.os.windows.PAGE_EXECUTE_READWRITE;
const DWORD = std.os.windows.DWORD;

// TODO: experiment with unprotected/raw memory access without the bullshit
// - switching to PAGE_EXECUTE_READWRITE is required
// - maybe add fns: write_unsafe, write_unsafe_enable, write_unsafe_disable ?
//     then you could do something like:
//     GameLoopAfter() {
//        write_unsafe_enable();
//        function_containing_write_unsafe();
//        ...
//        write_unsafe_disable();
//     }
//     and only have to set it a handful of times outside of special cases
// - need to know exactly the perf cost of calling virtualprotect to know
//     if making a arch shift is worth it tho

pub fn write(offset: usize, comptime T: type, value: T) usize {
    const addr: [*]align(1) T = @ptrFromInt(offset);
    const data: [1]T = [1]T{value};
    var protect: DWORD = undefined;
    _ = VirtualProtect(addr, @sizeOf(T), PAGE_EXECUTE_READWRITE, &protect) catch unreachable;
    @memcpy(addr, &data);
    _ = VirtualProtect(addr, @sizeOf(T), protect, &protect) catch unreachable;
    return offset + @sizeOf(T);
}

pub fn write_bytes(offset: usize, ptr_in: ?*anyopaque, len: usize) usize {
    const addr: [*]u8 = @ptrFromInt(offset);
    const data: []u8 = @as([*]u8, @ptrCast(ptr_in))[0..len];
    var protect: DWORD = undefined;
    _ = VirtualProtect(addr, len, PAGE_EXECUTE_READWRITE, &protect) catch unreachable;
    @memcpy(addr, data);
    _ = VirtualProtect(addr, len, protect, &protect) catch unreachable;
    return offset + len;
}

pub fn read(offset: usize, comptime T: type) T {
    const addr: [*]align(1) T = @ptrFromInt(offset);
    var data: [1]T = undefined;
    @memcpy(&data, addr);
    return data[0];
}

pub fn read_bytes(offset: usize, ptr_out: ?*anyopaque, len: usize) void {
    const addr: [*]u8 = @ptrFromInt(offset);
    const data: []u8 = @as([*]u8, @ptrCast(ptr_out))[0..len];
    @memcpy(data, addr);
}

pub fn patchAdd(offset: usize, comptime T: type, delta: T) usize {
    const value: T = read(offset, T);
    return write(offset, T, value + delta);
}

pub fn add_rm32_imm8(memory_offset: usize, rm32: u8, imm8: u8) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x83);
    offset = write(offset, u8, rm32);
    offset = write(offset, u8, imm8);
    return offset;
}

pub fn add_esp8(memory_offset: usize, value: u8) usize {
    return add_rm32_imm8(memory_offset, 0xC4, value);
}

pub fn add_rm32_imm32(memory_offset: usize, rm32: u8, imm32: u32) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x81);
    offset = write(offset, u8, rm32);
    offset = write(offset, u32, imm32);
    return offset;
}

pub fn add_esp32(memory_offset: usize, value: u32) usize {
    return add_rm32_imm32(memory_offset, 0xC4, value);
}

pub fn test_rm32_r32(memory_offset: usize, r32: u8) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x85);
    offset = write(offset, u8, r32);
    return offset;
}

pub fn test_eax_eax(memory_offset: usize) usize {
    return test_rm32_r32(memory_offset, 0xC0);
}

pub fn test_edx_edx(memory_offset: usize) usize {
    return test_rm32_r32(memory_offset, 0xD2);
}

pub fn mov_r32_rm32(memory_offset: usize, r32: u8, value: u32) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x8B);
    offset = write(offset, u8, r32);
    offset = write(offset, u32, value);
    return offset;
}

pub fn mov_edx(memory_offset: usize, value: u32) usize {
    return mov_r32_rm32(memory_offset, 0x15, value);
}

pub fn mov_rm32_r32(memory_offset: usize, r32: u8) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x89);
    offset = write(offset, u8, r32);
    return offset;
}

pub fn mov_edx_esp(memory_offset: usize) usize {
    return mov_rm32_r32(memory_offset, 0xE2);
}

pub fn nop(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x90);
}

pub fn nop_align(memory_offset: usize, increment: usize) usize {
    var offset: usize = memory_offset;
    while (offset % increment > 0) {
        offset = nop(offset);
    }
    return offset;
}

pub fn nop_until(memory_offset: usize, end: usize) usize {
    var offset: usize = memory_offset;
    while (offset < end) {
        offset = nop(offset);
    }
    return offset;
}

pub fn push_eax(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x50);
}

pub fn push_edx(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x52);
}

pub fn push_esi(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x56);
}

pub fn push_edi(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x57);
}

pub fn pop_eax(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x58);
}

pub fn pop_edx(memory_offset: usize) usize {
    return write(memory_offset, u8, 0x5A);
}

pub fn push_u32(memory_offset: usize, value: usize) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x68);
    offset = write(offset, u32, value);
    return offset;
}

// WARN: could underflow, but not likely for our use case i guess
// call_rel32
pub fn call(memory_offset: usize, address: usize) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0xE8);
    offset = write(offset, i32, @as(i32, @bitCast(address)) - (@as(i32, @bitCast(offset)) + 4));
    //offset = write(offset, u32, address - (offset + 4));
    return offset;
}

// WARN: could underflow, but not likely for our use case i guess
// jmp_rel32
pub fn jmp(memory_offset: usize, address: usize) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0xE9);
    offset = write(offset, i32, @as(i32, @bitCast(address)) - (@as(i32, @bitCast(offset)) + 4));
    //offset = write(offset, u32, address - (offset + 4));
    return offset;
}

// WARN: could underflow, but not likely for our use case i guess
// jcc jnz_rel32
pub fn jnz(memory_offset: usize, address: usize) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x0F);
    offset = write(offset, u8, 0x85);
    offset = write(offset, i32, @as(i32, @bitCast(address)) - (@as(i32, @bitCast(offset)) + 4));
    //offset = write(offset, u32, address - (offset + 4));
    return offset;
}

pub fn jz_rel8(memory: usize, value: i8) usize {
    var offset = memory;
    offset = write(offset, u8, 0x74);
    offset = write(offset, i8, value);
    return offset;
}

// WARN: could underflow, but not likely for our use case i guess
// jcc jz_rel32
pub fn jz(memory_offset: usize, address: usize) usize {
    var offset = memory_offset;
    offset = write(offset, u8, 0x0F);
    offset = write(offset, u8, 0x84);
    offset = write(offset, i32, @as(i32, @bitCast(address)) - (@as(i32, @bitCast(offset)) + 4));
    //offset = write(offset, u32, address - (offset + 4));
    return offset;
}

pub fn retn(memory_offset: usize) usize {
    return write(memory_offset, u8, 0xC3);
}

pub fn detour(memory: usize, addr: usize, len: usize, dest: *const fn () void) usize {
    std.debug.assert(len >= 5);

    const scr_alloc = MEM_COMMIT | MEM_RESERVE;
    const scr_protect = PAGE_EXECUTE_READWRITE;
    const scratch = VirtualAlloc(null, len, scr_alloc, scr_protect) catch unreachable;
    defer VirtualFree(scratch, 0, MEM_RELEASE);
    read_bytes(addr, scratch, len);

    var offset: usize = memory;

    const off_hook: usize = call(addr, offset);
    _ = nop_until(off_hook, addr + len);

    offset = call(offset, @intFromPtr(dest));
    offset = write_bytes(offset, scratch, len);
    offset = retn(offset);
    offset = nop_align(offset, 16);

    return offset;
}
