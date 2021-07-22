const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zhttpd", "example/main.zig");

    exe.setBuildMode(mode);
    const zhp = std.build.Pkg{
        .name = "zhp",
        .path = "src/zhp.zig",
        .dependencies = &[_]std.build.Pkg{
            std.build.Pkg{
                .name = "ctregex",
                .path = "src/bundled_depends/ctregex/ctregex.zig",
            },
            std.build.Pkg{
                .name = "datetime",
                .path = "src/bundled_depends/datetime/datetime.zig",
            },
        },
    };

    exe.addPackage(zhp);
    exe.valgrind_support = true;
    exe.strip = false;
    const run_cmd = exe.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
