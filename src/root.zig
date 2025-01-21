//! Debian control file parser.
//!
//! - field names are case-insensitive.
//!
//! - field names composed of U+0021 (!) through U+0039 (9), and U+003B
//!   (;) through U+007E (~), inclusive.
//!
//! - field names must not start with U+0023 (#) and U+002D (-).
//!
//! - continuation lines begin with space or tab
//!
//! - lines starting with # indicates a comment until end of line
//!
//! https://www.debian.org/doc/debian-policy/ch-controlfields.html

pub const StanzaParser = struct {
    source: []const u8,

    // the following are mutated during parsing calls to `next()`
    index: usize,
    line_no: usize,
    col_no: usize,

    /// Initialize a stanza parser. Lifetime of source must exceed all
    /// calls to StanzaParser.next().
    pub fn init(source: []const u8) StanzaParser {
        return .{
            .source = source,
            .index = 0,
            .line_no = 1,
            .col_no = 0,
        };
    }

    /// Return the next stanza as a slice into SOURCE provided to
    /// `init()`. `errorInfo` will be filled in only if this function
    /// returns an error.
    pub fn next(self: *StanzaParser, errorInfo: *ErrorInfo) Error![]const u8 {
        const State = enum {
            start,
            field,
            value_start,
            value_continue,
            comment,
            newline,
            newline_two,
            done,
        };

        var state: State = .start;
        var start_index = self.index;
        var result: ?[]const u8 = null;
        const len = self.source.len;

        while (self.index < len) : ({
            self.index += 1;
            self.col_no += 1;
        }) {
            const c = self.source[self.index];
            if (c == '\n') {
                self.line_no += 1;
                self.col_no = 0;
            }

            switch (state) {
                .start => {
                    switch (c) {
                        // skip leading newlines
                        '\n' => start_index = self.index + 1, // see comment #1 below
                        '#' => state = .comment,
                        '-' => return self.invalidFieldName(errorInfo),
                        else => state = .field,
                    }
                },
                .field => {
                    switch (c) {
                        '\n' => state = .newline,
                        ':' => state = .value_start,
                        else => {},
                    }
                },
                .value_start => {
                    switch (c) {
                        ' ', '\t' => {},
                        '\n' => state = .newline,
                        else => state = .value_continue,
                    }
                },
                .value_continue => {
                    switch (c) {
                        '\n' => state = .newline,
                        else => {},
                    }
                },
                .comment => {
                    switch (c) {
                        '\n' => state = .start,
                        else => {},
                    }
                },
                .newline => {
                    switch (c) {
                        '\n' => state = .done,
                        else => {
                            state = .start;
                            self.index -= 1; // backtrack
                        },
                    }
                },
                .newline_two => {
                    std.debug.print("newline two: {}", .{c});
                    switch (c) {
                        '\n' => continue,
                        else => {
                            state = .done;
                            self.index -= 1; // backtrack
                        },
                    }
                },
                .done => {
                    result = self.source[start_index .. self.index - 1];
                    break;
                },
            }
        }

        if (result == null) {
            // #1: avoid potential bounds error
            if (start_index > self.index) start_index = self.index;
            result = self.source[start_index..self.index];
        }

        if (result) |res| {
            if (res.len == 0) return error.Eof;
            return res;
        } else unreachable;
    }

    pub const ErrorInfo = struct {
        /// Slice into SOURCE provided to init.
        offender: []const u8,

        line: usize,
        col: usize,
    };

    pub const Error = error{ Eof, InvalidFieldName };

    fn invalidFieldName(self: StanzaParser, errorInfo: *ErrorInfo) Error {
        errorInfo.* = .{
            .offender = self.source[self.index .. self.index + 1],
            .line = self.line_no,
            .col = self.col_no,
        };
        return error.InvalidFieldName;
    }
};

//

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
}

fn isFieldContinue(c: u8) bool {
    // Field names composed of U+0021 (!) through U+0039 (9), and U+003B
    // (;) through U+007E (~), inclusive.
    if (c >= '!' and c <= '9') return true;
    if (c >= ';' and c <= '~') return true;
    return false;
}

fn isFieldStart(c: u8) bool {
    // Field names must not start with U+0023 (#) and U+002D (-)
    if (c == '#' or c == '-') return false;
    return isFieldContinue(c);
}

//

const std = @import("std");
const testing = std.testing;

test "dcf stanza basic" {
    const in1 =
        \\Stanza: one
        \\Field1: data1
        \\Field2: data2
        \\
    ;
    const in2 =
        \\Stanza: two
        \\Field1: data3
        \\Field2: data4
        \\
    ;
    const in = in1 ++ "\n" ++ in2;

    var parser = StanzaParser.init(in);

    var errorInfo: StanzaParser.ErrorInfo = undefined;

    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in1, s1);

    const s2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in2, s2);

    const expect_eof = parser.next(&errorInfo);
    try testing.expectError(StanzaParser.Error.Eof, expect_eof);
}

test "dcf ignore multiple blank lines" {
    const in =
        \\
        \\
        \\Stanza:one
        \\
        \\
        \\
        \\Stanza: two
        \\
    ;

    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Stanza:one\n", s1);

    const s2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Stanza: two\n", s2);

    const expect_eof = parser.next(&errorInfo);
    try testing.expectError(StanzaParser.Error.Eof, expect_eof);
}

test "dcf empty input" {
    const in = "";
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    try testing.expectError(StanzaParser.Error.Eof, parser.next(&errorInfo));
}

test "dcf one space only" {
    const in = " ";
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in, s1);
}

test "dcf one newline only" {
    const in = "\n";
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    try testing.expectError(StanzaParser.Error.Eof, parser.next(&errorInfo));
}

test "dcf newlines-only input" {
    const in = "\n\n\n";
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    try testing.expectError(StanzaParser.Error.Eof, parser.next(&errorInfo));
}

test "dcf stanza invalid field - dash start" {
    const in =
        \\-Stanza: one
        \\
    ;
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    const s1 = parser.next(&errorInfo);
    try testing.expectError(StanzaParser.Error.InvalidFieldName, s1);
    try testing.expectEqualStrings("-", errorInfo.offender);
    try testing.expectEqual(1, errorInfo.line);
    try testing.expectEqual(0, errorInfo.col);
}

test "dcf stanza invalid field - dash in the middle is ok" {
    const in = "S-tanza: one";
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in, s1);
}

test "dcf stanza comment - between fields" {
    const in =
        \\Stanza: one
        \\# comment
        \\Field1: value1
        \\
    ;
    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in, s1);
}

test "dcf stanza comment - in continuation" {
    const in1 =
        \\Stanza: one
        \\Field1: data1
        \\  continue
        \\Field2: data2
        \\
    ;
    const in2 = "Stanza:   two";
    const in = in1 ++ "\n" ++ in2;

    var parser = StanzaParser.init(in);
    var errorInfo: StanzaParser.ErrorInfo = undefined;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in1, s1);
}
