const std = @import("std");
const builtin = @import("builtin");

/// Minimum supported version of Zig
const min_ver: std.SemanticVersion = .{ .major = 0, .minor = 16, .patch = 0 };

comptime {
    // Note: pre-release versions (e.g., 0.16.0-dev) are acceptable for 0.16.0
    if (builtin.zig_version.major < min_ver.major or
        (builtin.zig_version.major == min_ver.major and builtin.zig_version.minor < min_ver.minor))
        @compileError("Raylib requires zig version 0.16.0 or later");
}

fn setDesktopPlatform(raylib_mod: *std.Build.Module, platform: PlatformBackend) void {
    raylib_mod.addCMacro("PLATFORM_DESKTOP", "");

    switch (platform) {
        .glfw => raylib_mod.addCMacro("PLATFORM_DESKTOP_GLFW", ""),
        .rgfw => raylib_mod.addCMacro("PLATFORM_DESKTOP_RGFW", ""),
        .sdl => raylib_mod.addCMacro("PLATFORM_DESKTOP_SDL", ""),
        else => {},
    }
}

fn createEmsdkStep(b: *std.Build, emsdk: *std.Build.Dependency) *std.Build.Step.Run {
    if (builtin.os.tag == .windows) {
        return b.addSystemCommand(&.{emsdk.path("emsdk.bat").getPath(b)});
    } else {
        return b.addSystemCommand(&.{emsdk.path("emsdk").getPath(b)});
    }
}

fn emSdkSetupStep(b: *std.Build, emsdk: *std.Build.Dependency) !?*std.Build.Step.Run {
    const dot_emsc_path = emsdk.path(".emscripten").getPath(b);

    // Use Threaded IO for blocking file access check
    var threaded_io = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = .empty });
    const io = threaded_io.io();
    const dot_emsc_exists = !std.meta.isError(std.Io.Dir.accessAbsolute(io, dot_emsc_path, .{}));

    if (!dot_emsc_exists) {
        const emsdk_install = createEmsdkStep(b, emsdk);
        emsdk_install.addArgs(&.{ "install", "latest" });
        const emsdk_activate = createEmsdkStep(b, emsdk);
        emsdk_activate.addArgs(&.{ "activate", "latest" });
        emsdk_activate.step.dependOn(&emsdk_install.step);
        return emsdk_activate;
    } else {
        return null;
    }
}

/// A list of all flags from `src/config.h` that one may override
const config_h_flags = outer: {
    // Set this value higher if compile errors happen as `src/config.h` gets larger
    @setEvalBranchQuota(1 << 20);

    const config_h = @embedFile("src/config.h");
    var flags: [std.mem.count(u8, config_h, "\n") + 1][]const u8 = undefined;

    var i = 0;
    var lines = std.mem.tokenizeScalar(u8, config_h, '\n');
    while (lines.next()) |line| {
        if (!std.mem.containsAtLeast(u8, line, 1, "SUPPORT")) continue;
        if (std.mem.startsWith(u8, line, "//")) continue;
        if (std.mem.startsWith(u8, line, "#if")) continue;

        var flag = std.mem.trimStart(u8, line, " \t"); // Trim whitespace
        flag = flag["#define ".len - 1 ..]; // Remove #define
        flag = std.mem.trimStart(u8, flag, " \t"); // Trim whitespace
        flag = flag[0 .. std.mem.indexOf(u8, flag, " ") orelse continue]; // Flag is only one word, so capture till space
        flag = "-D" ++ flag; // Prepend with -D

        flags[i] = flag;
        i += 1;
    }

    // Uncomment this to check what flags normally get passed
    //@compileLog(flags[0..i].*);
    break :outer flags[0..i].*;
};

fn compileRaylib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, options: Options) !*std.Build.Step.Compile {
    var raylib_flags_arr: std.ArrayList([]const u8) = .empty;
    defer raylib_flags_arr.deinit(b.allocator);

    try raylib_flags_arr.appendSlice(b.allocator, &[_][]const u8{
        "-std=gnu99",
        "-D_GNU_SOURCE",
        "-DGL_SILENCE_DEPRECATION=199309L",
        "-fno-sanitize=undefined", // https://github.com/raysan5/raylib/issues/3674
    });

    if (options.shared) {
        try raylib_flags_arr.appendSlice(b.allocator, &[_][]const u8{
            "-fPIC",
            "-DBUILD_LIBTYPE_SHARED",
        });
    }

    if (options.config.len > 0) {
        // Sets a flag indiciating the use of a custom `config.h`
        try raylib_flags_arr.append(b.allocator, "-DEXTERNAL_CONFIG_FLAGS");

        // Splits a space-separated list of config flags into multiple flags
        //
        // Note: This means certain flags like `-x c++` won't be processed properly.
        // `-xc++` or similar should be used when possible
        var config_iter = std.mem.tokenizeScalar(u8, options.config, ' ');

        // Apply config flags supplied by the user
        while (config_iter.next()) |config_flag|
            try raylib_flags_arr.append(b.allocator, config_flag);

        // Apply all relevant configs from `src/config.h` *except* the user-specified ones
        //
        // Note: Currently using a suboptimal `O(m*n)` time algorithm where:
        // `m` corresponds roughly to the number of lines in `src/config.h`
        // `n` corresponds to the number of user-specified flags
        outer: for (config_h_flags) |flag| {
            // If a user already specified the flag, skip it
            config_iter.reset();
            while (config_iter.next()) |config_flag| {
                // For a user-specified flag to match, it must share the same prefix and have the
                // same length or be followed by an equals sign
                if (!std.mem.startsWith(u8, config_flag, flag)) continue;
                if (config_flag.len == flag.len or config_flag[flag.len] == '=') continue :outer;
            }

            // Otherwise, append default value from config.h to compile flags
            try raylib_flags_arr.append(b.allocator, flag);
        }
    }

    const raylib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const raylib = b.addLibrary(.{
        .name = "raylib",
        .root_module = raylib_mod,
        .linkage = if (options.shared) .dynamic else .static,
    });

    // No GLFW required on PLATFORM_DRM
    if (options.platform != .drm) {
        raylib_mod.addIncludePath(b.path("src/external/glfw/include"));
    }

    var c_source_files: std.ArrayList([]const u8) = .empty;
    try c_source_files.appendSlice(b.allocator, &.{ "src/rcore.c", "src/utils.c" });

    if (options.raudio) {
        try c_source_files.append(b.allocator, "src/raudio.c");
    }
    if (options.rmodels) {
        try c_source_files.append(b.allocator, "src/rmodels.c");
    }
    if (options.rshapes) {
        try c_source_files.append(b.allocator, "src/rshapes.c");
    }
    if (options.rtext) {
        try c_source_files.append(b.allocator, "src/rtext.c");
    }
    if (options.rtextures) {
        try c_source_files.append(b.allocator, "src/rtextures.c");
    }

    if (options.opengl_version != .auto) {
        raylib_mod.addCMacro(options.opengl_version.toCMacroStr(), "");
    }

    switch (target.result.os.tag) {
        .windows => {
            try c_source_files.append(b.allocator, "src/rglfw.c");
            raylib_mod.linkSystemLibrary("winmm", .{});
            raylib_mod.linkSystemLibrary("gdi32", .{});
            raylib_mod.linkSystemLibrary("opengl32", .{});

            setDesktopPlatform(raylib_mod, options.platform);
        },
        .linux => {
            if (options.platform != .drm) {
                try c_source_files.append(b.allocator, "src/rglfw.c");

                if (options.linux_display_backend == .X11 or options.linux_display_backend == .Both) {
                    raylib_mod.addCMacro("_GLFW_X11", "");
                    raylib_mod.linkSystemLibrary("GLX", .{});
                    raylib_mod.linkSystemLibrary("X11", .{});
                    raylib_mod.linkSystemLibrary("Xcursor", .{});
                    raylib_mod.linkSystemLibrary("Xext", .{});
                    raylib_mod.linkSystemLibrary("Xfixes", .{});
                    raylib_mod.linkSystemLibrary("Xi", .{});
                    raylib_mod.linkSystemLibrary("Xinerama", .{});
                    raylib_mod.linkSystemLibrary("Xrandr", .{});
                    raylib_mod.linkSystemLibrary("Xrender", .{});
                }

                if (options.linux_display_backend == .Wayland or options.linux_display_backend == .Both) {
                    _ = b.findProgram(&.{"wayland-scanner"}, &.{}) catch {
                        std.log.err(
                            \\ `wayland-scanner` may not be installed on the system.
                            \\ You can switch to X11 in your `build.zig` by changing `Options.linux_display_backend`
                        , .{});
                        @panic("`wayland-scanner` not found");
                    };
                    raylib_mod.addCMacro("_GLFW_WAYLAND", "");
                    raylib_mod.linkSystemLibrary("EGL", .{});
                    raylib_mod.linkSystemLibrary("wayland-client", .{});
                    raylib_mod.linkSystemLibrary("xkbcommon", .{});
                    waylandGenerate(b, raylib_mod, "wayland.xml", "wayland-client-protocol");
                    waylandGenerate(b, raylib_mod, "xdg-shell.xml", "xdg-shell-client-protocol");
                    waylandGenerate(b, raylib_mod, "xdg-decoration-unstable-v1.xml", "xdg-decoration-unstable-v1-client-protocol");
                    waylandGenerate(b, raylib_mod, "viewporter.xml", "viewporter-client-protocol");
                    waylandGenerate(b, raylib_mod, "relative-pointer-unstable-v1.xml", "relative-pointer-unstable-v1-client-protocol");
                    waylandGenerate(b, raylib_mod, "pointer-constraints-unstable-v1.xml", "pointer-constraints-unstable-v1-client-protocol");
                    waylandGenerate(b, raylib_mod, "fractional-scale-v1.xml", "fractional-scale-v1-client-protocol");
                    waylandGenerate(b, raylib_mod, "xdg-activation-v1.xml", "xdg-activation-v1-client-protocol");
                    waylandGenerate(b, raylib_mod, "idle-inhibit-unstable-v1.xml", "idle-inhibit-unstable-v1-client-protocol");
                }

                setDesktopPlatform(raylib_mod, options.platform);
            } else {
                if (options.opengl_version == .auto) {
                    raylib_mod.linkSystemLibrary("GLESv2", .{});
                    raylib_mod.addCMacro("GRAPHICS_API_OPENGL_ES2", "");
                }

                raylib_mod.linkSystemLibrary("EGL", .{});
                raylib_mod.linkSystemLibrary("gbm", .{});
                raylib_mod.linkSystemLibrary("libdrm", .{ .use_pkg_config = .force });

                raylib_mod.addCMacro("PLATFORM_DRM", "");
                raylib_mod.addCMacro("EGL_NO_X11", "");
                raylib_mod.addCMacro("DEFAULT_BATCH_BUFFER_ELEMENT", "2048");
            }
        },
        .freebsd, .openbsd, .netbsd, .dragonfly => {
            try c_source_files.append(b.allocator, "rglfw.c");
            raylib_mod.linkSystemLibrary("GL", .{});
            raylib_mod.linkSystemLibrary("rt", .{});
            raylib_mod.linkSystemLibrary("dl", .{});
            raylib_mod.linkSystemLibrary("m", .{});
            raylib_mod.linkSystemLibrary("X11", .{});
            raylib_mod.linkSystemLibrary("Xrandr", .{});
            raylib_mod.linkSystemLibrary("Xinerama", .{});
            raylib_mod.linkSystemLibrary("Xi", .{});
            raylib_mod.linkSystemLibrary("Xxf86vm", .{});
            raylib_mod.linkSystemLibrary("Xcursor", .{});

            setDesktopPlatform(raylib_mod, options.platform);
        },
        .macos => {
            // Include xcode_frameworks for cross compilation (only when not building natively)
            if (builtin.os.tag != .macos) {
                if (b.lazyDependency("xcode_frameworks", .{})) |dep| {
                    raylib_mod.addSystemFrameworkPath(dep.path("Frameworks"));
                    raylib_mod.addSystemIncludePath(dep.path("include"));
                    raylib_mod.addLibraryPath(dep.path("lib"));
                }
            }

            // On macos rglfw.c include Objective-C files.
            try raylib_flags_arr.append(b.allocator, "-ObjC");
            raylib_mod.addCSourceFile(.{
                .file = b.path("src/rglfw.c"),
                .flags = raylib_flags_arr.items,
            });
            _ = raylib_flags_arr.pop();
            raylib_mod.linkFramework("Foundation", .{});
            raylib_mod.linkFramework("CoreServices", .{});
            raylib_mod.linkFramework("CoreGraphics", .{});
            raylib_mod.linkFramework("AppKit", .{});
            raylib_mod.linkFramework("IOKit", .{});

            setDesktopPlatform(raylib_mod, options.platform);
        },
        .emscripten => {
            // Include emscripten for cross compilation
            if (b.lazyDependency("emsdk", .{})) |dep| {
                if (try emSdkSetupStep(b, dep)) |emSdkStep| {
                    raylib.step.dependOn(&emSdkStep.step);
                }

                raylib_mod.addIncludePath(dep.path("upstream/emscripten/cache/sysroot/include"));
            }

            raylib_mod.addCMacro("PLATFORM_WEB", "");
            if (options.opengl_version == .auto) {
                raylib_mod.addCMacro("GRAPHICS_API_OPENGL_ES2", "");
            }
        },
        else => {
            @panic("Unsupported OS");
        },
    }

    raylib_mod.addCSourceFiles(.{
        .files = c_source_files.items,
        .flags = raylib_flags_arr.items,
    });

    return raylib;
}

pub fn addRaygui(b: *std.Build, raylib: *std.Build.Step.Compile, raygui_dep: *std.Build.Dependency) void {
    var gen_step = b.addWriteFiles();
    raylib.step.dependOn(&gen_step.step);

    const raygui_c_path = gen_step.add("raygui.c", "#define RAYGUI_IMPLEMENTATION\n#include \"raygui.h\"\n");
    raylib.root_module.addCSourceFile(.{ .file = raygui_c_path });
    raylib.root_module.addIncludePath(raygui_dep.path("src"));

    raylib.installHeader(raygui_dep.path("src/raygui.h"), "raygui.h");
}

pub const Options = struct {
    raudio: bool = true,
    rmodels: bool = true,
    rshapes: bool = true,
    rtext: bool = true,
    rtextures: bool = true,
    platform: PlatformBackend = .glfw,
    shared: bool = false,
    linux_display_backend: LinuxDisplayBackend = .Both,
    opengl_version: OpenglVersion = .auto,
    /// config should be a list of space-separated cflags, eg, "-DSUPPORT_CUSTOM_FRAME_CONTROL"
    config: []const u8 = &.{},

    const defaults = Options{};

    fn getOptions(b: *std.Build) Options {
        return .{
            .platform = b.option(PlatformBackend, "platform", "Choose the platform backedn for desktop target") orelse defaults.platform,
            .raudio = b.option(bool, "raudio", "Compile with audio support") orelse defaults.raudio,
            .rmodels = b.option(bool, "rmodels", "Compile with models support") orelse defaults.rmodels,
            .rtext = b.option(bool, "rtext", "Compile with text support") orelse defaults.rtext,
            .rtextures = b.option(bool, "rtextures", "Compile with textures support") orelse defaults.rtextures,
            .rshapes = b.option(bool, "rshapes", "Compile with shapes support") orelse defaults.rshapes,
            .shared = b.option(bool, "shared", "Compile as shared library") orelse defaults.shared,
            .linux_display_backend = b.option(LinuxDisplayBackend, "linux_display_backend", "Linux display backend to use") orelse defaults.linux_display_backend,
            .opengl_version = b.option(OpenglVersion, "opengl_version", "OpenGL version to use") orelse defaults.opengl_version,
            .config = b.option([]const u8, "config", "Compile with custom define macros overriding config.h") orelse &.{},
        };
    }
};

pub const OpenglVersion = enum {
    auto,
    gl_1_1,
    gl_2_1,
    gl_3_3,
    gl_4_3,
    gles_2,
    gles_3,

    pub fn toCMacroStr(self: @This()) []const u8 {
        switch (self) {
            .auto => @panic("OpenglVersion.auto cannot be turned into a C macro string"),
            .gl_1_1 => return "GRAPHICS_API_OPENGL_11",
            .gl_2_1 => return "GRAPHICS_API_OPENGL_21",
            .gl_3_3 => return "GRAPHICS_API_OPENGL_33",
            .gl_4_3 => return "GRAPHICS_API_OPENGL_43",
            .gles_2 => return "GRAPHICS_API_OPENGL_ES2",
            .gles_3 => return "GRAPHICS_API_OPENGL_ES3",
        }
    }
};

pub const LinuxDisplayBackend = enum {
    X11,
    Wayland,
    Both,
};

pub const PlatformBackend = enum {
    glfw,
    rgfw,
    sdl,
    drm,
};

pub fn build(b: *std.Build) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const lib = try compileRaylib(b, target, optimize, Options.getOptions(b));

    lib.installHeader(b.path("src/raylib.h"), "raylib.h");
    lib.installHeader(b.path("src/raymath.h"), "raymath.h");
    lib.installHeader(b.path("src/rlgl.h"), "rlgl.h");

    b.installArtifact(lib);
}

fn waylandGenerate(
    b: *std.Build,
    raylib_mod: *std.Build.Module,
    comptime protocol: []const u8,
    comptime basename: []const u8,
) void {
    const waylandDir = "src/external/glfw/deps/wayland";
    const protocolDir = b.pathJoin(&.{ waylandDir, protocol });
    const clientHeader = basename ++ ".h";
    const privateCode = basename ++ "-code.h";

    const client_step = b.addSystemCommand(&.{ "wayland-scanner", "client-header" });
    client_step.addFileArg(b.path(protocolDir));
    raylib_mod.addIncludePath(client_step.addOutputFileArg(clientHeader).dirname());

    const private_step = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
    private_step.addFileArg(b.path(protocolDir));
    raylib_mod.addIncludePath(private_step.addOutputFileArg(privateCode).dirname());
}
