const Self = @This();

const BuildOptions = @import("BuildOptions");

const std = @import("std");
const w = std.os.windows;
const w32 = @import("zigwin32");
const w32ll = w32.system.library_loader;
const w32f = w32.foundation;
const w32fs = w32.storage.file_system;

const core = @import("core.zig");
const allocator = core.Allocator;
const global = core.Global;
const GlobalSt = global.GlobalState;
const GLOBAL_STATE = &global.GLOBAL_STATE;
const GlobalFn = global.GlobalFunction;
const GLOBAL_FUNCTION = &global.GLOBAL_FUNCTION;
const PLUGIN_VERSION = global.PLUGIN_VERSION;

const hook = @import("../util/hooking.zig");
const mem = @import("../util/memory.zig");

const r = @import("racer");
const reh = r.Entity.Hang;

// TODO: switch to Sha256 for perf?
const Sha512 = std.crypto.hash.sha2.Sha512;
const plugin_hashes_data = @embedFile("hashfile");
const plugin_hashes_len: u32 = (plugin_hashes_data.len - 4) / 64;
const plugin_hashes: *align(1) const [plugin_hashes_len][64]u8 = std.mem.bytesAsValue([plugin_hashes_len][64]u8, plugin_hashes_data[4..]);

// TODO: figure out exactly where the patch gets executed on load (i.e. where
// the 'early init' happens), for documentation purposes

// FIXME: hooking (settings?) deinit causes racer process to never end, but only
// when you quit with the X button, not with the ingame quit option
// that said, again probably pointless to bother manually deallocating at the end anyway

// OKOKOKOKOK

const Plugin = plugin: {
    const stdf = .{
        .{ "Handle", ?w.HINSTANCE },
        .{ "WriteTime", ?w32f.FILETIME },
        .{ "Initialized", bool },
        .{ "Filename", [127:0]u8 },
    };
    const ev = std.enums.values(PluginExportFn);
    var fields: [stdf.len + ev.len]std.builtin.Type.StructField = undefined;

    for (stdf, 0..) |f, i| {
        fields[i] = .{
            .name = f[0],
            .type = f[1],
            .default_value = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }
    for (ev, stdf.len..) |f, i| {
        fields[i] = .{
            .name = @tagName(f),
            .type = PluginExportFnType(f),
            .default_value = null,
            .is_comptime = false,
            .alignment = 0,
        };
    }

    break :plugin @Type(.{ .Struct = .{
        .layout = .Auto,
        .fields = fields[0..],
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
};

fn PluginExportFnType(comptime f: PluginExportFn) type {
    return switch (f) {
        .PluginName, .PluginVersion => ?*const fn () callconv(.C) [*:0]const u8,
        .PluginCompatibilityVersion => ?*const fn () callconv(.C) u32,
        //.PluginCategoryFlags => *const fn () callconv(.C) u32,
        else => ?*const fn (*GlobalSt, *GlobalFn) callconv(.C) void,
    };
}

const PluginExportFn = enum(u32) {
    // Setup/Meta Functions
    PluginName,
    PluginVersion,
    PluginCompatibilityVersion,
    // TODO: flags for cosmetic, QOL, etc. (some ignored for non-whitelisted plugins)
    //PluginCategoryFlags,
    OnInit,
    OnInitLate,
    OnDeinit,
    //OnEnable,
    //OnDisable,
    OnSettingsLoad,

    // Hook Functions
    GameLoopB,
    GameLoopA,
    EarlyEngineUpdateB,
    EarlyEngineUpdateA,
    LateEngineUpdateB,
    LateEngineUpdateA,
    //EngineUpdateStage14B,
    EngineUpdateStage14A,
    //EngineUpdateStage18B,
    EngineUpdateStage18A,
    //EngineUpdateStage1CB,
    EngineUpdateStage1CA,
    //EngineUpdateStage20B,
    EngineUpdateStage20A,
    TimerUpdateB,
    TimerUpdateA,
    InputUpdateB,
    InputUpdateA,
    InputUpdateControlsB,
    InputUpdateControlsA,
    InputUpdateKeyboardB,
    InputUpdateKeyboardA,
    InputUpdateJoysticksB,
    InputUpdateJoysticksA,
    InputUpdateMouseB,
    InputUpdateMouseA,
    //InitHangQuadsB,
    InitHangQuadsA,
    //InitRaceQuadsB,
    InitRaceQuadsA,
    //EventJdgeBegnB,
    //EventJdgeBegnA,
    MenuTitleScreenB,
    MenuStartRaceB,
    MenuJunkyardB,
    MenuRaceResultsB,
    MenuWattosShopB,
    MenuHangarB,
    MenuVehicleSelectB,
    MenuTrackSelectB,
    MenuTrackB,
    MenuCantinaEntryB,
    TextRenderB,
    TextRenderA,
    MapRenderB,
    MapRenderA,
};

const PluginState = struct {
    const check_freq: u32 = 1000 / 24; // in lieu of every frame
    var last_check: u32 = 0;
    var core: std.ArrayList(Plugin) = undefined;
    var plugin: std.ArrayList(Plugin) = undefined;
};

pub fn PluginFnCallback(comptime ex: PluginExportFn) *const fn () void {
    const c = struct {
        fn callback() void {
            for (PluginState.core.items) |p|
                if (@field(p, @tagName(ex))) |f| f(GLOBAL_STATE, GLOBAL_FUNCTION);
            for (PluginState.plugin.items) |p|
                if (@field(p, @tagName(ex))) |f| f(GLOBAL_STATE, GLOBAL_FUNCTION);
        }
    };
    return &c.callback;
}

fn PluginFnCallback1_stub(_: u32) void {}

// MISC

// w32fs.CompareFileTime is slow as balls for some reason???
fn filetime_eql(t1: *w32f.FILETIME, t2: *w32f.FILETIME) bool {
    return (t1.dwLowDateTime == t2.dwLowDateTime and
        t1.dwHighDateTime == t2.dwHighDateTime);
}

// TODO: move to lib, share with generate_safe_plugin_hash_file.zig
fn getFileSha512(filename: []u8) ![Sha512.digest_length]u8 {
    const file = try std.fs.cwd().openFile(filename, .{});
    defer file.close();

    var sha512 = Sha512.init(.{});
    const rdr = file.reader();

    var buf: [std.mem.page_size]u8 = undefined;
    var n = try rdr.read(&buf);
    while (n != 0) {
        sha512.update(buf[0..n]);
        n = try rdr.read(&buf);
    }

    return sha512.finalResult();
}

// TODO: move to lib
/// @return     requested directory exists
fn ensureDirectoryExists(alloc: std.mem.Allocator, path: []const u8) bool {
    if (std.mem.lastIndexOf(u8, path, "/")) |end|
        _ = ensureDirectoryExists(alloc, path[0..end]);

    const p = std.fmt.allocPrintZ(alloc, "{s}", .{path}) catch return false;
    defer alloc.free(p);

    if (0 != w32fs.CreateDirectoryA(p, null)) return true;
    if (w.kernel32.GetLastError() == w.Win32Error.ALREADY_EXISTS) return true;

    return false;
}

// TODO: ignore hash check to re-enable hot reloading for dev and unofficial plugins
// only, probably want modal system in place properly first
// TODO: possibly assert that this fully sets all fields and acts as an initializer
// to a plugin struct, not just something that hooks up the fn refs
// TODO: OnLoad, OnUnload, OnEnable, OnDisable
// TODO: also stuff for loading and unloading based on watching the directory, outside of
// updating already loaded plugins
// NOTE: assumes index is allocated and initialized, to allow different
// ways of handling the backing data
/// @return plugin loaded correctly; guarantee of no dangling handles on failure
fn LoadPlugin(p: *Plugin, filename: []const u8) bool {
    const i_ext = filename.len - 4;

    std.debug.assert(std.mem.eql(u8, ".DLL", filename[i_ext..]) or
        std.mem.eql(u8, ".dll", filename[i_ext..]));

    var buf1: [2047:0]u8 = undefined;
    var filepath = std.fmt.bufPrintZ(&buf1, "annodue/plugin/{s}", .{
        filename,
    }) catch @panic("failed to format path to plugin");

    // do we even need to do anything
    var fd1: w32fs.WIN32_FIND_DATAA = undefined;
    _ = w32fs.FindFirstFileA(&buf1, &fd1);
    if (p.Initialized and filetime_eql(&fd1.ftLastWriteTime, &p.WriteTime.?))
        return true;

    if (BuildOptions.BUILD_MODE != .Developer) blk: {
        const this_hash = getFileSha512(filepath) catch return false;
        for (plugin_hashes) |hash|
            if (std.mem.eql(u8, &this_hash, &hash))
                break :blk;
        return false;
    }

    // separated from buf1 to minimize work on the hot path
    var buf0: [127:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&buf0, "{s}", .{filename}) catch @panic("failed to format plugin filename");
    var buf2: [2047:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&buf2, "annodue/tmp/plugin/{s}.tmp.dll", .{
        filename[0..i_ext],
    }) catch @panic("failed to format path to plugin tmp file");

    // do we need to unload anything
    if (p.Handle) |h| {
        p.OnDeinit.?(GLOBAL_STATE, GLOBAL_FUNCTION);
        _ = w32ll.FreeLibrary(h);
    }

    // now we ball

    _ = w32fs.CopyFileA(&buf1, &buf2, 0);
    p.Handle = w32ll.LoadLibraryA(&buf2);
    p.WriteTime = fd1.ftLastWriteTime;
    @memcpy(p.Filename[0..], buf0[0..]);

    const fields = comptime std.enums.values(PluginExportFn);
    inline for (fields) |field| {
        const process = w32ll.GetProcAddress(p.Handle, @tagName(field));
        @field(p, @tagName(field)) = if (process) |proc| @ptrCast(proc) else null;
    }

    if (p.PluginName == null or
        p.PluginVersion == null or
        p.PluginCompatibilityVersion == null or
        p.PluginCompatibilityVersion.?() != PLUGIN_VERSION or
        p.OnInit == null or
        p.OnInitLate == null or
        p.OnDeinit == null)
    {
        _ = w32ll.FreeLibrary(p.Handle);
        p.Initialized = false;
        return false;
    }

    p.OnInit.?(GLOBAL_STATE, GLOBAL_FUNCTION);
    if (GLOBAL_STATE.init_late_passed) p.OnInitLate.?(GLOBAL_STATE, GLOBAL_FUNCTION);
    p.Initialized = true;
    return true;
}

// SETUP

pub fn init() void {
    const alloc = allocator.allocator();
    _ = ensureDirectoryExists(alloc, "annodue/tmp/plugin");

    PluginState.core = std.ArrayList(Plugin).init(alloc);
    PluginState.plugin = std.ArrayList(Plugin).init(alloc);

    var p: *Plugin = undefined;

    // loading core
    // TODO: hot-reloading core (i.e. all of annodue)

    // TODO: move to LoadPlugin equivalent?
    // TODO: require OnInit, OnLateInit, OnDeinit?
    // TODO: run OnInit immediately like plugins
    // TODO: (after hot-reloading core) run OnLateInit immediately on hot-reload like plugins
    // TODO: filtering/error-checking the fields to make sure they're actually objects, not functions etc.
    const fn_fields = comptime std.enums.values(PluginExportFn);
    const core_decls = @typeInfo(core).Struct.decls;
    inline for (core_decls) |cd| {
        const this_decl = @field(core, cd.name);
        var this_p: ?*Plugin = null;
        inline for (fn_fields) |ff| {
            if (@hasDecl(this_decl, @tagName(ff))) {
                if (this_p == null) {
                    p = PluginState.core.addOne() catch @panic("failed to add core plugin to arraylist");
                    p.* = std.mem.zeroInit(Plugin, .{});
                    this_p = p;
                }
                @field(this_p.?, @tagName(ff)) = &@field(this_decl, @tagName(ff));
            }
        }
    }

    // loading plugins

    const cwd = std.fs.cwd();
    var dir = cwd.openIterableDir("./annodue/plugin", .{}) catch
        cwd.makeOpenPathIterable("./annodue/plugin", .{}) catch @panic("failed to open plugin directory");
    defer dir.close();

    var it_dir = dir.iterate();
    while (it_dir.next() catch @panic("failed to fetch next plugin")) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.eql(u8, ".DLL", file.name[file.name.len - 4 ..]) and
            !std.mem.eql(u8, ".dll", file.name[file.name.len - 4 ..])) continue;

        p = PluginState.plugin.addOne() catch @panic("failed to add user plugin to arraylist");
        p.* = std.mem.zeroInit(Plugin, .{});
        if (!LoadPlugin(p, file.name))
            _ = PluginState.plugin.pop();
    }

    // hooking game

    var off = global.GLOBAL_STATE.patch_offset;
    off = HookGameSetup(off);
    off = HookGameLoop(off);
    off = HookEngineUpdate(off);
    off = HookInputUpdate(off);
    off = HookTimerUpdate(off);
    off = HookInitRaceQuads(off);
    off = HookInitHangQuads(off);
    //off = HookGameEnd(off);
    off = HookTextRender(off);
    off = HookMenuDrawing(off);
    //off = HookLoadSprite(off);
    global.GLOBAL_STATE.patch_offset = off;
}

pub fn GameLoopB(gs: *GlobalSt, _: *GlobalFn) callconv(.C) void {
    if (gs.timestamp > PluginState.last_check + PluginState.check_freq) {
        for (PluginState.plugin.items, 0..) |*p, i| {
            const len = for (p.Filename, 0..) |c, j| {
                if (c == 0) break j;
            } else p.Filename.len;
            if (!LoadPlugin(p, p.Filename[0..len]))
                _ = PluginState.plugin.swapRemove(i);
        }
        PluginState.last_check = gs.timestamp;
    }
}

// GAME SETUP

// last function call in successful setup path
fn HookGameSetup(memory: usize) usize {
    const addr: usize = 0x4240AD;
    const len: usize = 0x4240B7 - addr;
    const off_call: usize = 0x4240AF - addr;
    return hook.detour_call(memory, addr, off_call, len, null, PluginFnCallback(.OnInitLate));
}

// GAME LOOP

fn HookGameLoop(memory: usize) usize {
    return hook.intercept_call(
        memory,
        0x49CE2A,
        PluginFnCallback(.GameLoopB),
        PluginFnCallback(.GameLoopA),
    );
}

// ENGINE UPDATES

fn HookEngineUpdate(memory: usize) usize {
    var off: usize = memory;

    // fn_445980 case 1
    // physics updates, etc.
    off = hook.intercept_call(off, 0x445991, PluginFnCallback(.EarlyEngineUpdateB), null);
    off = hook.intercept_call(off, 0x445A00, null, PluginFnCallback(.EarlyEngineUpdateA));

    // fn_445980 case 2
    // text processing, etc. before the actual render
    off = hook.intercept_call(off, 0x445A10, PluginFnCallback(.LateEngineUpdateB), null);
    off = hook.intercept_call(off, 0x445A40, null, PluginFnCallback(.LateEngineUpdateA));

    // entity system stages in EarlyEngineUpdate (CallAll0x14, etc.)
    // will only run when game is not paused
    off = hook.intercept_call(off, 0x4459D6, null, PluginFnCallback(.EngineUpdateStage14A));
    off = hook.intercept_call(off, 0x4459E0, null, PluginFnCallback(.EngineUpdateStage18A));
    off = hook.intercept_call(off, 0x4459E5, null, PluginFnCallback(.EngineUpdateStage1CA));
    off = hook.intercept_call(off, 0x4459EF, null, PluginFnCallback(.EngineUpdateStage20A));

    return off;
}

// GAME LOOP TIMER

fn HookTimerUpdate(memory: usize) usize {
    // fn_480540, in early engine update
    return hook.intercept_call(
        memory,
        0x4459AF,
        PluginFnCallback(.TimerUpdateB),
        PluginFnCallback(.TimerUpdateA),
    );
}

// INPUT READING

// NOTE: before early engine update in main loop; not the only calls to the
// hooked functions, but the main ones
fn HookInputUpdate(memory: usize) usize {
    var off = memory;
    off = hook.intercept_call( // fn_404DD0
        off,
        0x423592,
        PluginFnCallback(.InputUpdateB),
        PluginFnCallback(.InputUpdateA),
    );
    off = hook.intercept_call( // fn_485630
        off,
        0x404DD7,
        PluginFnCallback(.InputUpdateControlsB),
        PluginFnCallback(.InputUpdateControlsA),
    );
    off = hook.intercept_call( // fn_486170
        off,
        0x4856B3,
        PluginFnCallback(.InputUpdateKeyboardB),
        PluginFnCallback(.InputUpdateKeyboardA),
    );
    off = hook.intercept_call( // fn_486340
        off,
        0x4856C1,
        PluginFnCallback(.InputUpdateJoysticksB),
        PluginFnCallback(.InputUpdateJoysticksA),
    );
    off = hook.intercept_call( // fn_486710
        off,
        0x4856C6,
        PluginFnCallback(.InputUpdateMouseB),
        PluginFnCallback(.InputUpdateMouseA),
    );
    return off;
}

// 'HANG' SETUP

// NOTE: disabling before fn to match RaceQuads
fn HookInitHangQuads(memory: usize) usize {
    const addr: usize = 0x454DCF;
    const len: usize = 0x454DD8 - addr;
    const off_call: usize = 0x454DD0 - addr;
    return hook.detour_call(memory, addr, off_call, len, null, PluginFnCallback(.InitHangQuadsA));
}

// SPRITES

// FIXME: remove stub and integrate one-param hooks with PluginFnCallback
fn HookLoadSprite(memory: usize) usize {
    return hook.intercept_call_one_u32_param(memory, 0x446FB5, &PluginFnCallback1_stub);
}

// RACE SETUP

// FIXME: before fn crashes when hooked with any function contents; disabling for now
fn HookInitRaceQuads(memory: usize) usize {
    const addr: usize = 0x466D76;
    const len: usize = 0x466D81 - addr;
    const off_call: usize = 0x466D79 - addr;
    return hook.detour_call(memory, addr, off_call, len, null, PluginFnCallback(.InitRaceQuadsA));
}

// GAME END; executable closing

// FIXME: probably just switch to fn_4240D0 (GameShutdown), not sure if hook should
// be before or after the function contents (or both); might want to make available
// opportunity to intercept e.g. the final savedata write
// also look into doexit_49EA80, may be the last thing called regardless of exit path,
// will definitely come after GameShutdown though
// WARNING: in the current scheme, core deinit happens before plugin deinit, keep this
// hook location as a stage2 or core-only deinit and use above for arbitrary deinit?
fn HookGameEnd(memory: usize) usize {
    const exit1_off: usize = 0x49CE31;
    const exit2_off: usize = 0x49CE3D;
    const exit1_len: usize = exit2_off - exit1_off - 1; // excluding retn
    const exit2_len: usize = 0x49CE48 - exit2_off - 1; // excluding retn
    var offset: usize = memory;

    offset = hook.detour(offset, exit1_off, exit1_len, null, PluginFnCallback(.OnDeinit));
    offset = hook.detour(offset, exit2_off, exit2_len, null, PluginFnCallback(.OnDeinit));

    return offset;
}

// MENU DRAW CALLS in 'Hang' callback0x14

fn HookMenuDrawing(memory: usize) usize {
    var off: usize = memory;

    // see fn_457620 @ 0x45777F
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 1, PluginFnCallback(.MenuTitleScreenB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 3, PluginFnCallback(.MenuStartRaceB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 4, PluginFnCallback(.MenuJunkyardB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 5, PluginFnCallback(.MenuRaceResultsB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 7, PluginFnCallback(.MenuWattosShopB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 8, PluginFnCallback(.MenuHangarB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 9, PluginFnCallback(.MenuVehicleSelectB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 12, PluginFnCallback(.MenuTrackSelectB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 13, PluginFnCallback(.MenuTrackB));
    off = hook.intercept_jumptable(off, reh.DRAW_MENU_JUMPTABLE_ADDR, 18, PluginFnCallback(.MenuCantinaEntryB));

    return off;
}

// TEXT RENDER QUEUE FLUSHING

fn HookTextRender(memory: usize) usize {
    // NOTE: 0x483F8B calls ProcessQueue1, only usable with after-fn when using intercept_call()
    var off = memory;
    // FlushQueue1
    off = hook.intercept_call(
        off,
        0x450297,
        PluginFnCallback(.TextRenderB),
        PluginFnCallback(.TextRenderA),
    );
    // FlushMapQueue
    off = hook.intercept_call(
        off,
        0x45029C,
        PluginFnCallback(.MapRenderB),
        PluginFnCallback(.MapRenderA),
    );
    return off;
}
