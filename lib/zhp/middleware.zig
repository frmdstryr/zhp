const web = @import("web.zig");

const ProxyMiddleware = struct {

    pub fn process(middleware: *web.Middleware, request: *web.HttpRequest) !web.HttpResponse {
        var response = middleware.process(request);
        return response;
    }

}
