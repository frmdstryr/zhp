// -------------------------------------------------------------------------- //
// Copyright (c) 2019-2020, Jairus Martin.                                    //
// Distributed under the terms of the MIT License.                            //
// The full license is in the file LICENSE, distributed with this software.   //
// -------------------------------------------------------------------------- //
const std = @import("std");
const testing = std.testing;

// Supported, IANA-registered status codes available
// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status
pub const Status = struct {
    code: u16,
    phrase: []const u8,
    description: []const u8,

    pub fn create(code: u16, phrase: []const u8, desc: []const u8) Status {
        return Status{
            .code = code,
            .phrase = phrase,
            .description = desc,
        };
    }
};

pub const create = Status.create;

// Informational
pub const CONTINUE = create(100, "Continue", "Request received, please continue");
pub const SWITCHING_PROTOCOLS = create(101, "Switching Protocols",
        "Switching to new protocol; obey Upgrade header");
pub const PROCESSING = create(102, "Processing", "");
pub const EARLY_HINTS = create(103, "Early Hints", "");

// Success
pub const OK = create(200, "OK", "Request fulfilled, document follows");
pub const CREATED = create(201, "Created", "Document created, URL follows");
pub const ACCEPTED = create(202, "Accepted", "Request accepted, processing continues off-line");
pub const NON_AUTHORITATIVE_INFORMATION = create(203, "Non-Authoritative Information", "Request fulfilled from cache");
pub const NO_CONTENT = create(204, "No Content", "Request fulfilled, nothing follows");
pub const RESET_CONTENT = create(205, "Reset Content", "Clear input form for further input");
pub const PARTIAL_CONTENT = create(206, "Partial Content", "Partial content follows");
pub const MULTI_STATUS = create(207, "Multi-Status", "");
pub const ALREADY_REPORTED = create(208, "Already Reported", "");
pub const IM_USED = create(226, "IM Used", "");

// Redirection
pub const MULTIPLE_CHOICES = create(300, "Multiple Choices", "Object has several resources -- see URI list");
pub const MOVED_PERMANENTLY = create(301, "Moved Permanently", "Object moved permanently -- see URI list");
pub const FOUND = create(302, "Found", "Object moved temporarily -- see URI list");
pub const SEE_OTHER = create(303, "See Other", "Object moved -- see Method and URL list");
pub const NOT_MODIFIED = create(304, "Not Modified", "Document has not changed since given time");
pub const USE_PROXY = create(305, "Use Proxy", "You must use proxy specified in Location to access this resource");
pub const TEMPORARY_REDIRECT = create(307, "Temporary Redirect", "Object moved temporarily -- see URI list");
pub const PERMANENT_REDIRECT = create(308, "Permanent Redirect", "Object moved permanently -- see URI list");

// Client error
pub const BAD_REQUEST = create(400, "Bad Request", "Bad request syntax or unsupported method");
pub const UNAUTHORIZED = create(401, "Unauthorized", "No permission -- see authorization schemes");
pub const PAYMENT_REQUIRED = create(402, "Payment Required", "No payment -- see charging schemes");
pub const FORBIDDEN = create(403, "Forbidden", "Request forbidden -- authorization will not help");
pub const NOT_FOUND = create(404, "Not Found", "Nothing matches the given URI");
pub const METHOD_NOT_ALLOWED = create(405, "Method Not Allowed", "Specified method is invalid for this resource");
pub const NOT_ACCEPTABLE = create(406, "Not Acceptable", "URI not available in preferred format");
pub const PROXY_AUTHENTICATION_REQUIRED = create(407, "Proxy Authentication Required", "You must authenticate with this proxy before proceeding");
pub const REQUEST_TIMEOUT = create(408, "Request Timeout", "Request timed out; try again later");
pub const CONFLICT = create(409, "Conflict", "Request conflict");
pub const GONE = create(410, "Gone", "URI no longer exists and has been permanently removed");
pub const LENGTH_REQUIRED = create(411, "Length Required", "Client must specify Content-Length");
pub const PRECONDITION_FAILED = create(412, "Precondition Failed", "Precondition in headers is false");
pub const REQUEST_ENTITY_TOO_LARGE = create(413, "Request Entity Too Large", "Entity is too large");
pub const REQUEST_URI_TOO_LONG = create(414, "Request-URI Too Long", "URI is too long");
pub const UNSUPPORTED_MEDIA_TYPE = create(415, "Unsupported Media Type", "Entity body in unsupported format");
pub const REQUESTED_RANGE_NOT_SATISFIABLE = create(416, "Requested Range Not Satisfiable", "Cannot satisfy request range");
pub const EXPECTATION_FAILED = create(417, "Expectation Failed", "Expect condition could not be satisfied");
pub const MISDIRECTED_REQUEST = create(421, "Misdirected Request", "Server is not able to produce a response");
pub const UNPROCESSABLE_ENTITY = create(422, "Unprocessable Entity", "");
pub const LOCKED = create(423, "Locked", "");
pub const FAILED_DEPENDENCY = create(424, "Failed Dependency", "");
pub const TOO_EARLY = create(425, "Too Early", "");
pub const UPGRADE_REQUIRED = create(426, "Upgrade Required", "");
pub const PRECONDITION_REQUIRED = create(428, "Precondition Required", "The origin server requires the request to be conditional");
pub const TOO_MANY_REQUESTS = create(429, "Too Many Requests", "The user has sent too many requests in a given amount of time (\"rate limiting\")");
pub const REQUEST_HEADER_FIELDS_TOO_LARGE = create(431, "Request Header Fields Too Large", "The server is unwilling to process the request because its header fields are too large");
pub const UNAVAILABLE_FOR_LEGAL_REASONS = create(451, "Unavailable For Legal Reasons", "The server is denying access to the resource as a consequence of a legal demand");

// server errors
pub const INTERNAL_SERVER_ERROR = create(500, "Internal Server Error", "Server got itself in trouble");
pub const NOT_IMPLEMENTED = create(501, "Not Implemented", "Server does not support this operation");
pub const BAD_GATEWAY = create(502, "Bad Gateway", "Invalid responses from another server/proxy");
pub const SERVICE_UNAVAILABLE = create(503, "Service Unavailable", "The server cannot process the request due to a high load");
pub const GATEWAY_TIMEOUT = create(504, "Gateway Timeout", "The gateway server did not receive a timely response");
pub const HTTP_VERSION_NOT_SUPPORTED = create(505, "HTTP Version Not Supported", "Cannot fulfill request");
pub const VARIANT_ALSO_NEGOTIATES = create(506, "Variant Also Negotiates", "");
pub const INSUFFICIENT_STORAGE = create(507, "Insufficient Storage", "");
pub const LOOP_DETECTED = create(508, "Loop Detected", "");
pub const NOT_EXTENDED = create(510, "Not Extended", "");
pub const NETWORK_AUTHENTICATION_REQUIRED = create(511, "Network Authentication Required", "The client needs to authenticate to gain network access");


/// Lookup the status for the given code
pub fn get(status_code: u16) ?Status {
    return switch (status_code) {
        100 => CONTINUE,
        101 => SWITCHING_PROTOCOLS,
        102 => PROCESSING,
        103 => EARLY_HINTS,
        200 => OK,
        201 => CREATED,
        202 => ACCEPTED,
        203 => NON_AUTHORITATIVE_INFORMATION,
        204 => NO_CONTENT,
        205 => RESET_CONTENT,
        206 => PARTIAL_CONTENT,
        207 => MULTI_STATUS,
        208 => ALREADY_REPORTED,
        226 => IM_USED,
        300 => MULTIPLE_CHOICES,
        301 => MOVED_PERMANENTLY,
        302 => FOUND,
        303 => SEE_OTHER,
        304 => NOT_MODIFIED,
        305 => USE_PROXY,
        307 => TEMPORARY_REDIRECT,
        308 => PERMANENT_REDIRECT,
        400 => BAD_REQUEST,
        401 => UNAUTHORIZED,
        402 => PAYMENT_REQUIRED,
        403 => FORBIDDEN,
        404 => NOT_FOUND,
        405 => METHOD_NOT_ALLOWED,
        406 => NOT_ACCEPTABLE,
        407 => PROXY_AUTHENTICATION_REQUIRED,
        408 => REQUEST_TIMEOUT,
        409 => CONFLICT,
        410 => GONE,
        411 => LENGTH_REQUIRED,
        412 => PRECONDITION_FAILED,
        413 => REQUEST_ENTITY_TOO_LARGE,
        414 => REQUEST_URI_TOO_LONG,
        415 => UNSUPPORTED_MEDIA_TYPE,
        416 => REQUESTED_RANGE_NOT_SATISFIABLE,
        417 => EXPECTATION_FAILED,
        422 => UNPROCESSABLE_ENTITY,
        423 => LOCKED,
        424 => FAILED_DEPENDENCY,
        425 => TOO_EARLY,
        426 => UPGRADE_REQUIRED,
        428 => PRECONDITION_REQUIRED,
        429 => TOO_MANY_REQUESTS,
        431 => REQUEST_HEADER_FIELDS_TOO_LARGE,
        500 => INTERNAL_SERVER_ERROR,
        501 => NOT_IMPLEMENTED,
        502 => BAD_GATEWAY,
        503 => SERVICE_UNAVAILABLE,
        504 => GATEWAY_TIMEOUT,
        505 => HTTP_VERSION_NOT_SUPPORTED,
        506 => VARIANT_ALSO_NEGOTIATES,
        507 => INSUFFICIENT_STORAGE,
        508 => LOOP_DETECTED,
        510 => NOT_EXTENDED,
        511 => NETWORK_AUTHENTICATION_REQUIRED,
        else => null,
    };
}


/// Lookup the status for the given code or create one with the given phrase
pub fn getOrCreate(status_code: u16, phrase: []const u8) Status {
    return get(status_code) orelse create(status_code, phrase, "");
}


test "Status.create" {
    const status = create(200, "OK",  "Request fulfilled, document follows");
    try testing.expectEqual(status.code, OK.code);
    try testing.expectEqualSlices(u8, status.phrase, OK.phrase);
    try testing.expectEqualSlices(u8, status.description, OK.description);
}

test "Status.get" {
    try testing.expectEqual(get(200).?, OK);
    try testing.expectEqual(get(600), null);
    const status = getOrCreate(600, "Unknown");
    try testing.expectEqual(status.code, 600);
    try testing.expectEqualSlices(u8, status.phrase, "Unknown");
}
