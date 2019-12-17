const std = @import("std");
const os = std.os;
const Application = @import("web.zig").Application;


pub extern fn handleSigintLinux(sig: i32, info: *const os.siginfo_t, ctx_ptr: *const c_void) noreturn {
    if (Application.instance) |app| {
        app.deinit();
    }
    // Reset default handler
    var act = os.Sigaction{
        .sigaction = os.SIG_DFL,
        .mask = os.empty_sigset,
        .flags = 0,
    };
    os.sigaction(os.SIGINT, &act, null);
    os.raise(os.SIGINT) catch {};
    os.exit(0);
}

pub extern fn handleSegfaultLinux(sig: i32, info: *const os.siginfo_t, ctx_ptr: *const c_void) noreturn {
    if (Application.instance) |app| {
        app.deinit();
    }
    std.debug.handleSegfaultLinux(sig, info, ctx_ptr);
}


pub fn setupSignalHandlers() void {
    var act = os.Sigaction{
        .sigaction = handleSigintLinux,
        .mask = os.empty_sigset,
        .flags = (os.SA_SIGINFO | os.SA_RESTART | os.SA_RESETHAND),
    };
    os.sigaction(os.SIGINT, &act, null);

    // Cleanup for segfaults
    act = os.Sigaction{
        .sigaction = handleSegfaultLinux,
        .mask = os.empty_sigset,
        .flags = (os.SA_SIGINFO | os.SA_RESTART | os.SA_RESETHAND),
    };
    os.sigaction(os.SIGSEGV, &act, null);
}
