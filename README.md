This is a fork of Raylib, packaged for Zig. Unnecessary files have been deleted

```
// build.zig

const raylib_dep = b.dependency("raylib", .{
  .target = target,
  .optimize = optimize,
});

exe.linkLibrary(raylib_dep.artifact("raylib"));
```

```
// build.zig.zon

.dependencies = .{
  .raylib = .{
    .url = "https://github.com/nonya123456/raylib/archive/refs/heads/master.tar.gz",
    .hash = "12202ea595ca1a9bac75947a3d49a4978a25a6a04d673e6b2ce48906a9fddaa89d23",
  },
},
```
