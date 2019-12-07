const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const mode = b.standardReleaseOptions();
    const exe = b.addExecutable("zhttpd", "src/main.zig");

    exe.setBuildMode(mode);
    //exe.addPackagePath("re", "lib/re/regex.zig");
    exe.addPackagePath("zhp", "lib/zhp/zhp.zig");
    exe.valgrind_support = true;
    exe.strip = false;
    const run_cmd = exe.run();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    b.default_step.dependOn(&exe.step);
    b.installArtifact(exe);
}
