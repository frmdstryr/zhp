const std = @import("std");
const mem = std.mem;
const ascii = std.ascii;

// TODO: Read from these
pub const known_files = &[_][]const u8{
    "/etc/mime.types",
    "/etc/httpd/mime.types",                    // Mac OS X
    "/etc/httpd/conf/mime.types",               // Apache
    "/etc/apache/mime.types",                   // Apache 1
    "/etc/apache2/mime.types",                  // Apache 2
    "/usr/local/etc/httpd/conf/mime.types",
    "/usr/local/lib/netscape/mime.types",
    "/usr/local/etc/httpd/conf/mime.types",     // Apache 1.2
    "/usr/local/etc/mime.types",                // Apache 1.3
};


pub const suffix_map  = &[_][2][]const u8 {
    .{".svgz", ".svg.gz"},
    .{".tgz" , ".tar.gz"},
    .{".taz" , ".tar.gz"},
    .{".tz"  , ".tar.gz"},
    .{".tbz2", ".tar.bz2"},
    .{".txz" , ".tar.xz"},
};

pub const encodings_map = &[_][2][]const u8 {
    .{".gz" , "gzip"},
    .{".Z"  , "compress"},
    .{".bz2", "bzip2"},
    .{".xz" , "xz"},
};


// Before adding new types, make sure they are either registered with IANA,
// at http://www.isi.edu/in-notes/iana/assignments/media-types
// or extensions, i.e. using the x- prefix
// If you add to these, please keep them sorted!
pub const extension_map = &[_][2][]const u8 {
    .{".a"      , "application/octet-stream"},
    .{".ai"     , "application/postscript"},
    .{".aif"    , "audio/x-aiff"},
    .{".aifc"   , "audio/x-aiff"},
    .{".aiff"   , "audio/x-aiff"},
    .{".au"     , "audio/basic"},
    .{".avi"    , "video/x-msvideo"},
    .{".bat"    , "text/plain"},
    .{".bcpio"  , "application/x-bcpio"},
    .{".bin"    , "application/octet-stream"},
    .{".bmp"    , "image/x-ms-bmp"},
    .{".c"      , "text/plain"},
    .{".cdf"    , "application/x-cdf"}, // Dup
    .{".cdf"    , "application/x-netcdf"},
    .{".cpio"   , "application/x-cpio"},
    .{".csh"    , "application/x-csh"},
    .{".css"    , "text/css"},
    .{".csv"    , "text/csv"},
    .{".dll"    , "application/octet-stream"},
    .{".doc"    , "application/msword"},
    .{".dot"    , "application/msword"},
    .{".dvi"    , "application/x-dvi"},
    .{".eml"    , "message/rfc822"},
    .{".eps"    , "application/postscript"},
    .{".etx"    , "text/x-setext"},
    .{".exe"    , "application/octet-stream"},
    .{".gif"    , "image/gif"},
    .{".gtar"   , "application/x-gtar"},
    .{".h"      , "text/plain"},
    .{".hdf"    , "application/x-hdf"},
    .{".htm"    , "text/html"},
    .{".html"   , "text/html"},
    .{".ico"    , "image/vnd.microsoft.icon"},
    .{".ief"    , "image/ief"},
    .{".jpe"    , "image/jpeg"},
    .{".jpeg"   , "image/jpeg"},
    .{".jpg"    , "image/jpeg"},
    .{".js"     , "application/javascript"},
    .{".json"   , "application/json"},
    .{".ksh"    , "text/plain"},
    .{".latex"  , "application/x-latex"},
    .{".m1v"    , "video/mpeg"},
    .{".man"    , "application/x-troff-man"},
    .{".me"     , "application/x-troff-me"},
    .{".mht"    , "message/rfc822"},
    .{".mhtml"  , "message/rfc822"},
    .{".mid"    , "audio/midi"},
    .{".midi"   , "audio/midi"},
    .{".mif"    , "application/x-mif"},
    .{".mjs"    , "application/javascript"},
    .{".mov"    , "video/quicktime"},
    .{".movie"  , "video/x-sgi-movie"},
    .{".mp2"    , "audio/mpeg"},
    .{".mp3"    , "audio/mpeg"},
    .{".mp4"    , "video/mp4"},
    .{".mpa"    , "video/mpeg"},
    .{".mpe"    , "video/mpeg"},
    .{".mpeg"   , "video/mpeg"},
    .{".mpg"    , "video/mpeg"},
    .{".ms"     , "application/x-troff-ms"},
    .{".nc"     , "application/x-netcdf"},
    .{".nws"    , "message/rfc822"},
    .{".o"      , "application/octet-stream"},
    .{".obj"    , "application/octet-stream"},
    .{".oda"    , "application/oda"},
    .{".p12"    , "application/x-pkcs12"},
    .{".p7c"    , "application/pkcs7-mime"},
    .{".pbm"    , "image/x-portable-bitmap"},
    .{".pdf"    , "application/pdf"},
    .{".pfx"    , "application/x-pkcs12"},
    .{".pgm"    , "image/x-portable-graymap"},
    .{".pct"    , "image/pict"},
    .{".pic"    , "image/pict"},
    .{".pict"   , "image/pict"},
    .{".pl"     , "text/plain"},
    .{".png"    , "image/png"},
    .{".pnm"    , "image/x-portable-anymap"},
    .{".pot"    , "application/vnd.ms-powerpoint"},
    .{".ppa"    , "application/vnd.ms-powerpoint"},
    .{".ppm"    , "image/x-portable-pixmap"},
    .{".pps"    , "application/vnd.ms-powerpoint"},
    .{".ppt"    , "application/vnd.ms-powerpoint"},
    .{".ps"     , "application/postscript"},
    .{".pwz"    , "application/vnd.ms-powerpoint"},
    .{".py"     , "text/x-python"},
    .{".pyc"    , "application/x-python-code"},
    .{".pyo"    , "application/x-python-code"},
    .{".qt"     , "video/quicktime"},
    .{".ra"     , "audio/x-pn-realaudio"},
    .{".ram"    , "application/x-pn-realaudio"},
    .{".ras"    , "image/x-cmu-raster"},
    .{".rdf"    , "application/xml"},
    .{".rgb"    , "image/x-rgb"},
    .{".roff"   , "application/x-troff"},
    .{".rtf"    , "application/rtf"},
    .{".rtx"    , "text/richtext"},
    .{".sgm"    , "text/x-sgml"},
    .{".sgml"   , "text/x-sgml"},
    .{".sh"     , "application/x-sh"},
    .{".shar"   , "application/x-shar"},
    .{".snd"    , "audio/basic"},
    .{".so"     , "application/octet-stream"},
    .{".src"    , "application/x-wais-source"},
    .{".sv4cpio", "application/x-sv4cpio"},
    .{".sv4crc" , "application/x-sv4crc"},
    .{".svg"    , "image/svg+xml"},
    .{".swf"    , "application/x-shockwave-flash"},
    .{".t"      , "application/x-troff"},
    .{".tar"    , "application/x-tar"},
    .{".tcl"    , "application/x-tcl"},
    .{".tex"    , "application/x-tex"},
    .{".texi"   , "application/x-texinfo"},
    .{".texinfo", "application/x-texinfo"},
    .{".tif"    , "image/tiff"},
    .{".tiff"   , "image/tiff"},
    .{".tr"     , "application/x-troff"},
    .{".tsv"    , "text/tab-separated-values"},
    .{".txt"    , "text/plain"},
    .{".ustar"  , "application/x-ustar"},
    .{".vcf"    , "text/x-vcard"},
    .{".wav"    , "audio/x-wav"},
    .{".webm"   , "video/webm"},
    .{".wiz"    , "application/msword"},
    .{".wsdl"   , "application/xml"},
    .{".xbm"    , "image/x-xbitmap"},
    .{".xlb"    , "application/vnd.ms-excel"},
    .{".xls"    , "application/excel"},
    .{".xls"    , "application/vnd.ms-excel"}, // Dup
    .{".xml"    , "text/xml"},
    .{".xpdl"   , "application/xml"},
    .{".xpm"    , "image/x-xpixmap"},
    .{".xsl"    , "application/xml"},
    .{".xwd"    , "image/x-xwindowdump"},
    .{".xul"    , "text/xul"},
    .{".zip"    , "application/zip"},
};


pub fn guessFromFilename(filename: []const u8) ?[]const u8 {
    const last_dot = mem.lastIndexOf(u8, filename, ".");
    if (last_dot) |i| return guessFromExtension(filename[i..]);
    return null;
}

// Guess the mimetype from the extension
pub fn guessFromExtension(ext: []const u8) ?[]const u8 {
    if (ext.len < 2 or ext[0] != '.') return null;
    for (extension_map) |t| {
        if (ascii.eqlIgnoreCase(t[0][1..], ext[1..])) return t[1];
    }
    return null;
}


test "guess-ext" {
    const testing = std.testing;
    testing.expectEqualSlices(u8,
        "image/png", guessFromFilename("an-image.png").?);
    testing.expectEqualSlices(u8,
        "application/javascript", guessFromFilename("wavascript.js").?);

}
