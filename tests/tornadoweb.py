#!/usr/bin/env python

import tornado.httpserver
import tornado.ioloop
import tornado.options
import tornado.web

from tornado.options import define, options

define("port", default=8888, help="run on the given port", type=int)

with open('example/templates/cover.html') as f:
    template = f.read()


class MainHandler(tornado.web.RequestHandler):
    def get(self):
        self.write("Hello, world")


class TemplateHandler(tornado.web.RequestHandler):
    def get(self):
        self.write(template)


def main():
    tornado.options.parse_command_line()
    application = tornado.web.Application([
        (r"/", TemplateHandler),
        (r"/hello", MainHandler),
    ])
    http_server = tornado.httpserver.HTTPServer(application)
    http_server.listen(options.port)
    tornado.ioloop.IOLoop.current().start()


if __name__ == "__main__":
    try:
        import uvloop
        uvloop.install()
    except ImportError as e:
        print(e)
    main()
