const std = @import("std");
const builtin = @import("builtin");

const name = "epubdate";
pub fn build(b: *std.Build) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();

    const pdx_file_name = name ++ ".pdx";
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run host unit tests");
    // Zig only discovers tests that are reachable from each test root.  A
    // throwaway import in one aggregator file does not reliably retain the
    // imported module's declarations, so give every independently testable
    // layer its own root.  This makes `zig build test` cover the same suite
    // developers run directly while keeping Playdate bindings out of tests
    // that do not need them.
    const test_roots = [_][]const u8{
        "src/app.zig",
        "src/opening_session.zig",
        "src/reader_input.zig",
        "src/reader_transitions.zig",
        "src/scroll_geometry.zig",
        "src/page_transition.zig",
        "src/screen_transition.zig",
        "src/paged_reader.zig",
        "src/rsvp_reader.zig",
        "src/reader_coordinator.zig",
        "src/telemetry.zig",
        "src/settings_menu.zig",
        "src/reading_statistics.zig",
        "src/progress_rail.zig",
        "src/decode_workspace.zig",
        "src/prefetch_session.zig",
        "src/progress_indexer.zig",
        "src/chapter_browser.zig",
        "src/archive/deflate.zig",
        "src/archive/zip.zig",
        "src/content/navigation.zig",
        "src/content/cache_policy.zig",
        "src/content/pagination.zig",
        "src/content/xhtml.zig",
        "src/content/word_index.zig",
        "src/content/rsvp.zig",
        "src/integration.zig",
        "src/rsvp_integration.zig",
        "src/limits.zig",
        "src/publication/epub.zig",
        "src/publication/navigation.zig",
        "src/storage/library.zig",
        "src/storage/pace.zig",
        "src/storage/progress.zig",
        "src/storage/persistence.zig",
        "src/storage/reading_state.zig",
        "src/storage/resume.zig",
        "src/storage/settings.zig",
        "src/storage/write_schedule.zig",
    };
    for (test_roots) |root| {
        const limits_module = b.createModule(.{
            .root_source_file = b.path("src/limits.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        });
        const root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = b.graph.host,
            .optimize = optimize,
        });
        root_module.addImport("limits", limits_module);
        const unit_tests = b.addTest(.{
            .root_module = root_module,
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }

    const writer = b.addWriteFiles();
    const source_dir = writer.getDirectory();
    writer.step.name = "write source directory";

    const FORCE_COMPILE_M1_MAC = false;
    const supported_targets = [_]std.Build.ResolvedTarget{
        host_or_cross_target(
            b,
            .{
                .abi = .msvc,
                .os_tag = .windows,
                .cpu_arch = .x86_64,
            },
            false,
        ),
        host_or_cross_target(
            b,
            .{
                .abi = .none,
                .os_tag = .macos,
                .cpu_arch = .aarch64,
            },
            FORCE_COMPILE_M1_MAC,
        ),
        host_or_cross_target(
            b,
            .{
                .abi = .gnu,
                .os_tag = .linux,
                .cpu_arch = .x86_64,
            },
            false,
        ),
    };
    for (supported_targets) |target| {
        try compile_simulator_binary(b, optimize, target, writer);
    }

    const playdate_target = b.resolveTargetQuery(try std.Target.Query.parse(.{
        .arch_os_abi = "thumb-freestanding-eabihf",
        .cpu_features = "cortex_m7+vfp4d16sp",
    }));
    const playdate_mod = b.addModule("pdex", .{
        .root_source_file = b.path("src/main.zig"),
        .target = playdate_target,
        .optimize = optimize,
        .pic = true,
        .single_threaded = true,
    });
    playdate_mod.addImport("limits", b.createModule(.{
        .root_source_file = b.path("src/limits.zig"),
        .target = playdate_target,
        .optimize = optimize,
    }));
    const elf = b.addExecutable(.{
        .name = "pdex.elf",
        .root_module = playdate_mod,
    });
    elf.link_emit_relocs = true;
    elf.entry = .{ .symbol_name = "eventHandler" };

    elf.setLinkerScript(b.path("link_map.ld"));
    if (optimize == .ReleaseFast) {
        elf.root_module.omit_frame_pointer = true;
    }
    _ = writer.addCopyFile(elf.getEmittedBin(), "pdex.elf");
    _ = writer.addCopyFile(b.path("pdxinfo"), "pdxinfo");

    try addCopyDirectory(writer, "assets", "./assets", io);

    const playdate_sdk_path = b.graph.environ_map.get("PLAYDATE_SDK_PATH") orelse return error.PLAYDATE_SDK_PATH_NOT_SET;
    const pdc_path = b.pathJoin(&.{ playdate_sdk_path, "bin", if (builtin.os.tag == .windows) "pdc.exe" else "pdc" });
    const pd_simulator_path = switch (builtin.os.tag) {
        .linux => b.pathJoin(&.{ playdate_sdk_path, "bin", "PlaydateSimulator" }),
        .macos => "open", // `open` focuses the window, while running the simulator directry doesn't.
        .windows => b.pathJoin(&.{ playdate_sdk_path, "bin", "PlaydateSimulator.exe" }),
        else => @panic("Unsupported OS"),
    };

    const pdc = b.addSystemCommand(&.{pdc_path});
    pdc.addDirectoryArg(source_dir);
    pdc.setName("pdc");
    const pdx = pdc.addOutputFileArg(pdx_file_name);

    b.installDirectory(.{
        .source_dir = pdx,
        .install_dir = .prefix,
        .install_subdir = pdx_file_name,
    });
    b.installDirectory(.{
        .source_dir = source_dir,
        .install_dir = .prefix,
        .install_subdir = "pdx_source_dir",
    });

    const run_cmd = b.addSystemCommand(&.{pd_simulator_path});
    run_cmd.addDirectoryArg(pdx);
    run_cmd.setName("PlaydateSimulator");
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    run_step.dependOn(b.getInstallStep());
}

//The purpose of this function is a result of:
// 1) This script supports cross-compiling PDX's that work on Mac, Windows or Linux without having
//    to compile on those OS's.
//
// 2) Inside of a PDX, there can only be 1 pdex executable per OS regardless of the CPU architecture.
//    This has unexpected consequences where, say, a given PDX file can only work on M1 Macs,
//    but not Intel ones. Or, vice versa.
//
//    So, in the build() function above, I hardcoded ".cpu_arch = .aarch64", which is for M1 Macs.
//    What this means is that if you compiling your game on, say, Windows, it will generate a .pdx
//    that will only work on M1 Macs, but not Intel Macs.
//    BUT, cruicially, if you compiling your game on an Intel Mac, the resulting PDX will work
//    on Intel Macs, but not M1 Macs.  Without this function, the game would fail
//    to run on the machine your compiling the code on (Intel Mac), which I'd like to avoid.
fn host_or_cross_target(
    b: *std.Build,
    cross_target: std.Target.Query,
    force_use_cross_target: bool,
) std.Build.ResolvedTarget {
    const result =
        if (!force_use_cross_target and b.graph.host.result.os.tag == cross_target.os_tag.?)
            b.graph.host
        else
            b.resolveTargetQuery(cross_target);
    return result;
}

fn compile_simulator_binary(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    target: std.Build.ResolvedTarget,
    writer: *std.Build.Step.WriteFile,
) !void {
    const os_tag = target.result.os.tag;
    const strip_symbols = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const mod = b.addModule("pdex", .{
        .root_source_file = b.path("src/main.zig"),
        .optimize = optimize,
        .target = target,
        // ReleaseFast does not strip shared libraries by default.  Keeping
        // DWARF/PDB data makes the simulator binaries dominate PDX size.
        .strip = strip_symbols,
    });
    mod.addImport("limits", b.createModule(.{
        .root_source_file = b.path("src/limits.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const lib = b.addLibrary(.{
        .name = "pdex",
        .linkage = .dynamic,
        .root_module = mod,
    });
    const pdex_extension = switch (os_tag) {
        .windows => "dll",
        .macos => "dylib",
        .linux => "so",
        else => @panic("Unsupported OS"),
    };
    const pdex_filename = try std.fmt.allocPrint(b.allocator, "pdex.{s}", .{pdex_extension});
    _ = writer.addCopyFile(lib.getEmittedBin(), pdex_filename);

    if (os_tag == .windows) {
        const c_source_code =
            \\#include <stdarg.h>
        ;

        const c_source_file_step = b.addWriteFiles();
        const c_source_path = c_source_file_step.add("c.c", c_source_code);

        const translate_c = b.addTranslateC(.{
            .root_source_file = c_source_path,
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        mod.addImport("win_stdarg", translate_c.createModule());
        if (!strip_symbols) {
            _ = writer.addCopyFile(lib.getEmittedPdb(), "pdex.pdb");
        }
    }
}

fn addCopyDirectory(
    wf: *std.Build.Step.WriteFile,
    src_path: []const u8,
    dest_path: []const u8,
    io: std.Io,
) !void {
    const b = wf.step.owner;
    var dir = try b.build_root.handle.openDir(
        io,
        src_path,
        .{ .iterate = true },
    );
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const new_src_path = b.pathJoin(&.{ src_path, entry.name });
        const new_dest_path = b.pathJoin(&.{ dest_path, entry.name });
        const new_src = b.path(new_src_path);
        switch (entry.kind) {
            .file => {
                _ = wf.addCopyFile(new_src, new_dest_path);
            },
            .directory => {
                try addCopyDirectory(
                    wf,
                    new_src_path,
                    new_dest_path,
                    io,
                );
            },
            //TODO: possible support for sym links?
            else => {},
        }
    }
}
