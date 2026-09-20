const std = @import("std");
const zip = @import("archive/zip.zig");
const persistence = @import("storage/persistence.zig");
const reader_input = @import("reader_input.zig");
const reader_coordinator = @import("reader_coordinator.zig");
const reader_host = @import("reader_host.zig");
const pdapi = @import("playdate_api_definitions.zig");
const PlaydateAllocator = @import("platform/playdate_allocator.zig").PlaydateAllocator;
const PlaydateFileReader = @import("platform/playdate_file_reader.zig").PlaydateFileReader;
const playdate_persistence = @import("platform/playdate_persistence.zig");
const PlaydateRenderer = @import("platform/playdate_renderer.zig").Renderer;

pub const App = struct {
    playdate: *pdapi.PlaydateAPI,
    allocator: *PlaydateAllocator,
    renderer: PlaydateRenderer,
    coordinator: reader_coordinator.ReaderCoordinator,
    opening_file: ?PlaydateFileReader = null,
    // Chapter source is never collected: this file and stream stay open while
    // a current/next pair of drawable pages is built incrementally.
    chapter_file: ?PlaydateFileReader = null,
    // Once a chapter's final page is known, the Paged engine reserves an
    // unpinned cache slot for the first page of the following chapter.
    prefetch_file: ?PlaydateFileReader = null,
    // Progress indexing owns an independent stream and decoder workspace.
    progress_file: ?PlaydateFileReader = null,
    telemetry_menu: ?*pdapi.PDMenuItem = null,

    pub fn init(playdate: *pdapi.PlaydateAPI, allocator: *PlaydateAllocator) !*App {
        const body_font = playdate.graphics.loadFont("/System/Fonts/Roobert-20-Medium.pft", null) orelse return error.FontLoadFailed;
        const newsleak_serif_font = playdate.graphics.loadFont("assets/fonts/Newsleak-Serif.pft", null) orelse return error.FontLoadFailed;
        const app = try allocator.allocator().create(App);
        app.playdate = playdate;
        app.allocator = allocator;
        app.renderer = PlaydateRenderer.init(playdate, body_font, newsleak_serif_font);
        app.opening_file = null;
        app.chapter_file = null;
        app.prefetch_file = null;
        app.progress_file = null;
        app.telemetry_menu = null;
        app.coordinator.initInPlace(reader_coordinator.default_checkpoint_byte_budget);
        app.coordinator.attachAllocator(allocator.allocator());
        app.coordinator.attachPersistence(persistence.Service.init(playdate_persistence.fileStore(playdate.file)));
        app.coordinator.attachHost(app.readerHost());
        app.coordinator.loadSettings();
        app.renderer.selectFont(app.coordinator.font);
        app.installSystemMenu();
        app.discoverLibrary();
        return app;
    }

    pub fn updateAndRender(self: *App) c_int {
        const started_at = self.playdate.system.getCurrentTimeMilliseconds();
        defer {
            self.coordinator.frameFinished(started_at, self.playdate.system.getCurrentTimeMilliseconds());
        }

        var current: pdapi.PDButtons = 0;
        var pushed: pdapi.PDButtons = 0;
        self.playdate.system.getButtonState(&current, &pushed, null);
        self.coordinator.update(.{
            .buttons = buttonsFromPlaydate(pushed),
            .a_held = current & pdapi.BUTTON_A != 0,
            .crank_change = self.playdate.system.getCrankChange(),
            .crank_docked = self.playdate.system.isCrankDocked() != 0,
        }, started_at);

        self.renderer.beginFrame(self.coordinator.theme, self.coordinator.font);
        self.renderer.draw(self.coordinator.renderModel());
        if (self.coordinator.telemetrySnapshot()) |snapshot| self.renderer.drawTelemetry(snapshot, self.allocator.stats);
        return 1;
    }

    pub fn handleSystemEvent(self: *App, event: pdapi.PDSystemEvent) void {
        switch (event) {
            .EventLock, .EventPause, .EventTerminate, .EventLowPower => self.coordinator.systemPaused(self.playdate.system.getCurrentTimeMilliseconds()),
            .EventUnlock, .EventResume => self.coordinator.systemResumed(),
            else => {},
        }
    }

    fn discoverLibrary(self: *App) void {
        self.coordinator.discoverLibrary();
    }

    fn readerHost(self: *App) reader_host.ReaderHost {
        return .{
            .files = .{ .context = self, .open = openReaderFile, .close = closeReaderFile, .list_epubs = listEpubs },
            .measure = .{ .context = self, .width = measureTextWidth, .font_height = measureFontHeight },
        };
    }

    fn installSystemMenu(self: *App) void {
        _ = self.playdate.system.addMenuItem("Library", libraryMenuSelected, self);
        _ = self.playdate.system.addMenuItem("Settings", settingsMenuSelected, self);
        _ = self.playdate.system.addMenuItem("Chapters", chaptersMenuSelected, self);
        self.telemetry_menu = self.playdate.system.addCheckmarkMenuItem("Telemetry", 0, telemetryMenuSelected, self);
    }

    fn closeOpeningFile(self: *App) void {
        if (self.opening_file) |*file| file.close();
        self.opening_file = null;
    }

    fn textWidth(self: *const App, text: []const u8) c_int {
        return self.renderer.textWidth(text);
    }
};

fn openReaderFile(context: *anyopaque, slot: reader_host.FileSlot, path: [:0]const u8) reader_host.FileError!zip.Reader {
    const app: *App = @ptrCast(@alignCast(context));
    closeReaderFile(context, slot);
    const opened = PlaydateFileReader.open(app.playdate.file, path) catch return error.OpenFailed;
    switch (slot) {
        .opening => app.opening_file = opened,
        .chapter => app.chapter_file = opened,
        .prefetch => app.prefetch_file = opened,
        .progress => app.progress_file = opened,
    }
    return switch (slot) {
        .opening => if (app.opening_file) |*file| file.reader() else unreachable,
        .chapter => if (app.chapter_file) |*file| file.reader() else unreachable,
        .prefetch => if (app.prefetch_file) |*file| file.reader() else unreachable,
        .progress => if (app.progress_file) |*file| file.reader() else unreachable,
    };
}

fn closeReaderFile(context: *anyopaque, slot: reader_host.FileSlot) void {
    const app: *App = @ptrCast(@alignCast(context));
    switch (slot) {
        .opening => app.closeOpeningFile(),
        .chapter => {
            if (app.chapter_file) |*file| file.close();
            app.chapter_file = null;
        },
        .prefetch => {
            if (app.prefetch_file) |*file| file.close();
            app.prefetch_file = null;
        },
        .progress => {
            if (app.progress_file) |*file| file.close();
            app.progress_file = null;
        },
    }
}

fn listEpubs(context: *anyopaque, library: *reader_host.Library) void {
    const app: *App = @ptrCast(@alignCast(context));
    _ = app.playdate.file.listfiles("", collectLibraryPath, library, 0);
}

fn measureTextWidth(context: *anyopaque, text: []const u8) usize {
    const app: *App = @ptrCast(@alignCast(context));
    return @intCast(app.textWidth(text));
}

fn measureFontHeight(context: *anyopaque) usize {
    const app: *App = @ptrCast(@alignCast(context));
    return app.renderer.fontHeight();
}

fn buttonsFromPlaydate(pushed: pdapi.PDButtons) reader_input.Buttons {
    return .{
        .a = pushed & pdapi.BUTTON_A != 0,
        .b = pushed & pdapi.BUTTON_B != 0,
        .up = pushed & pdapi.BUTTON_UP != 0,
        .down = pushed & pdapi.BUTTON_DOWN != 0,
        .left = pushed & pdapi.BUTTON_LEFT != 0,
        .right = pushed & pdapi.BUTTON_RIGHT != 0,
    };
}

fn settingsMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.coordinator.handleSystemAction(.settings, app.playdate.system.getCurrentTimeMilliseconds());
}

fn telemetryMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    const item = app.telemetry_menu orelse return;
    app.coordinator.setTelemetryEnabled(app.playdate.system.getMenuItemValue(item) != 0);
}

fn libraryMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.coordinator.handleSystemAction(.library, app.playdate.system.getCurrentTimeMilliseconds());
}

fn chaptersMenuSelected(userdata: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(userdata orelse return));
    app.coordinator.handleSystemAction(.chapters, app.playdate.system.getCurrentTimeMilliseconds());
}

fn collectLibraryPath(path: ?[*:0]const u8, userdata: ?*anyopaque) callconv(.c) void {
    const library: *reader_host.Library = @ptrCast(@alignCast(userdata orelse return));
    const z_path = path orelse return;
    library.add(std.mem.span(z_path));
}
