const pdapi = @import("../playdate_api_definitions.zig");

/// The only layer that translates reader drawing primitives into Playdate
/// graphics calls. Higher layers provide already-selected text and geometry.
pub const Renderer = struct {
    playdate: *pdapi.PlaydateAPI,
    body_font: *pdapi.LCDFont,

    pub fn init(playdate: *pdapi.PlaydateAPI, body_font: *pdapi.LCDFont) Renderer {
        return .{ .playdate = playdate, .body_font = body_font };
    }

    pub fn beginFrame(self: *Renderer) void {
        self.playdate.graphics.setFont(self.body_font);
        self.playdate.graphics.clear(@intCast(@intFromEnum(pdapi.LCDSolidColor.ColorWhite)));
    }

    pub fn text(self: *const Renderer, value: []const u8, x: c_int, y: c_int) void {
        _ = self.playdate.graphics.drawText(value.ptr, value.len, .UTF8Encoding, x, y);
    }

    pub fn textWidth(self: *const Renderer, value: []const u8) c_int {
        return @intCast(self.playdate.graphics.getTextWidth(self.body_font, value.ptr, value.len, .UTF8Encoding, 0));
    }

    pub fn invertedText(self: *Renderer, value: []const u8, x: c_int, y: c_int, width: c_int, height: c_int) void {
        self.playdate.graphics.fillRect(x, y, width, height, @intCast(@intFromEnum(pdapi.LCDSolidColor.ColorBlack)));
        self.playdate.graphics.setDrawMode(.DrawModeInverted);
        self.text(value, x, y);
        self.playdate.graphics.setDrawMode(.DrawModeCopy);
    }
};
