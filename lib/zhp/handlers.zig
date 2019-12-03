
const web = @import("web.zig");
const responses = @import("status.zig");


pub const ServerErrorHandler = struct {
    handler: web.RequestHandler,

    pub fn init(application: *web.Application, response: *web.HttpResponse) *web.RequestHandler {
        var self = ServerErrorHandler{
            .handler = web.RequestHandler{
                .application = application,
                .request = response.request,
                .response = response,
                .dispatch = ServerErrorHandler.dispatch,
            }
        };
        return &self.handler;
    }

    pub fn dispatch(handler: *web.RequestHandler) anyerror!void {
        handler.response.status = responses.INTERNAL_SERVER_ERROR;
    }

};

pub const NotFoundHandler = struct {
    handler: web.RequestHandler,

    pub fn init(application: *web.Application, response: *web.HttpResponse) *web.RequestHandler {
        var self = NotFoundHandler{
            .handler = web.RequestHandler{
                .application = application,
                .request = response.request,
                .response = response,
                .dispatch = NotFoundHandler.dispatch,
            }
        };
        return &self.handler;
    }

    pub fn dispatch(handler: *web.RequestHandler) anyerror!void {
        handler.response.status = responses.NOT_FOUND;
    }

};

