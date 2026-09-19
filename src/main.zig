const std = @import("std");
const pdapi = @import("playdate_api_definitions.zig");
const panic_handler = @import("panic_handler.zig");

pub const panic = panic_handler.panic;

const App = @import("app.zig").App;
const PlaydateAllocator = @import("platform/playdate_allocator.zig").PlaydateAllocator;

var platform_allocator: PlaydateAllocator = undefined;

pub export fn eventHandler(playdate: *pdapi.PlaydateAPI, event: pdapi.PDSystemEvent, arg: u32) callconv(.c) c_int {
    _ = arg;
    switch (event) {
        .EventInit => {
            panic_handler.init(playdate);

            platform_allocator = PlaydateAllocator.init(playdate.system);
            const app = App.init(playdate, &platform_allocator) catch |err| {
                playdate.system.@"error"("EPUBDate startup failed: %s", @errorName(err).ptr);
                return 1;
            };
            playdate.system.setUpdateCallback(update_and_render, app);
        },
        else => {},
    }
    return 0;
}

fn update_and_render(userdata: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(userdata orelse return 0));
    return app.updateAndRender();
}
