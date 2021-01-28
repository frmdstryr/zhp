const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zhttpd", "example/main.zig");

    exe.setBuildMode(mode);
    exe.addPackagePath("zhp", "src/zhp.zig");
    exe.valgrind_support = true;
    exe.strip = false;
    const run_cmd = exe.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
