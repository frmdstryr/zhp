// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const web = @import("zhp.zig");
const log = std.log;
const Handler = web.Handler;
const Application = web.Application;
const ServerRequest = web.ServerRequest;


pub const LoggingMiddleware = struct {
    // If you want storage use it statically

    pub fn processRequest(app: *Application, server_request: *ServerRequest) !void {}

    pub fn processResponse(app: *Application, server_request: *ServerRequest) !void {
        const request = &server_request.request;
        const response = &server_request.response;
        if (request.method == .Unknown) return;
        log.info("{} {} {} ({}) {}", .{
            response.status.code,
            @tagName(request.method),
            request.path,
            request.client,
            response.body.items.len});
    }
};
