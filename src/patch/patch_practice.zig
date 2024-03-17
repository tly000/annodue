pub const Self = @This();

const std = @import("std");

const s = @import("settings.zig").state;
const GlobalSt = @import("global.zig").GlobalState;
const GlobalFn = @import("global.zig").GlobalFunction;

const fl = @import("util/flash.zig");
const st = @import("util/active_state.zig");
const mem = @import("util/memory.zig");
const r = @import("util/racer.zig");
const rf = r.functions;
const rc = r.constants;
const rt = r.text;
const rto = rt.TextStyleOpts;

// FIXME: refactor and merge with core

// PRACTICE MODE VISUALIZATION

const mode_vis = struct {
    const scale: f32 = 0.35;
    const x_rt: u16 = 640 - @round(32 * scale);
    const y_bt: u16 = 480 - @round(32 * scale);
    var spr: u32 = undefined;
    var tl: u16 = undefined;
    var tr: u16 = undefined;
    var bl: u16 = undefined;
    var br: u16 = undefined;

    fn init() void {
        spr = rf.swrQuad_LoadTga("annodue/images/corner_round_32.tga", 8000);
        init_single(&tl, false, false);
        init_single(&tr, false, true);
        init_single(&bl, true, false);
        init_single(&br, true, true);
    }

    fn init_single(id: *u16, bottom: bool, right: bool) void {
        id.* = r.InitNewQuad(spr);
        rf.swrQuad_SetFlags(id.*, 1 << 15 | 1 << 16);
        if (right) rf.swrQuad_SetFlags(id.*, 1 << 2);
        if (!bottom) rf.swrQuad_SetFlags(id.*, 1 << 3);
        rf.swrQuad_SetColor(id.*, 0xFF, 0xFF, 0x9C, 0xFF);
        rf.swrQuad_SetPosition(id.*, if (right) x_rt else 0, if (bottom) y_bt else 0);
        rf.swrQuad_SetScale(id.*, scale, scale);
    }

    fn update(active: bool, cr: u8, cg: u8, cb: u8) void {
        rf.swrQuad_SetActive(tl, @intFromBool(active));
        rf.swrQuad_SetActive(tr, @intFromBool(active));
        rf.swrQuad_SetActive(bl, @intFromBool(active));
        rf.swrQuad_SetActive(br, @intFromBool(active));
        if (active) {
            rf.swrQuad_SetColor(tl, cr, cg, cb, 0xFF);
            rf.swrQuad_SetColor(tr, cr, cg, cb, 0xFF);
            rf.swrQuad_SetColor(bl, cr, cg, cb, 0xFF);
            rf.swrQuad_SetColor(br, cr, cg, cb, 0xFF);
        }
    }
};

// HOOK FUNCTIONS

pub fn InitRaceQuadsA(gs: *GlobalSt, gf: *GlobalFn) callconv(.C) void {
    _ = gf;
    _ = gs;
    mode_vis.init();
}

pub fn TextRenderB(gs: *GlobalSt, gf: *GlobalFn) callconv(.C) void {
    _ = gf;

    const f = struct {
        var start_time: ?u32 = null;
        var player_ok: st.ActiveState = .Off;
    };

    // TODO: add this to global state, fix QOL fps limiter too once it is
    f.player_ok.update(mem.read(rc.RACE_DATA_PLAYER_RACE_DATA_PTR_ADDR, u32) != 0 and
        r.ReadRaceDataValue(0x84, u32) != 0);

    if (f.player_ok == .JustOff)
        f.start_time = null;

    if (!gs.practice_mode) return;

    if (f.player_ok.on()) blk: {
        mode_vis.update(false, 0, 0, 0);
        if (f.start_time != null) break :blk;

        f.start_time = gs.timestamp;
    }

    // TODO: fade-in/out the corner things
    if (f.start_time) |ts| {
        const t = @as(f32, @floatFromInt(gs.timestamp - ts)) / 1000;
        const color: u32 = fl.flash_color(@intFromEnum(rt.ColorRGB.Yellow), t, 3);
        mode_vis.update(true, @truncate(color >> 16), @truncate(color >> 8), @truncate(color >> 0));
    }
}
