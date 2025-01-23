//! Debian control file parser.
//!
//! Usage: see test "dcf integration" for example usage.
//!
//! Grammar:
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
//! - whitespace before or after ':' separating a field name and value
//!   is ignored
//!
//! See:
//!   https://www.debian.org/doc/debian-policy/ch-controlfields.html
//!
//! Formal grammar supported by this parser:
//!    ```
//!    (* Top level structure *)
//!    Document = Stanza*
//!
//!    (* Stanza structure *)
//!    Stanza = (EmptyLine | Comment)* Field+ BlankLine
//!    BlankLine = NewLine NewLine
//!    EmptyLine = NewLine
//!    NewLine = "\n"
//!
//!    (* Comments *)
//!    Comment = "#" AnyChar* NewLine
//!
//!    (* Fields *)
//!    Field = FieldName ":" ValuePart
//!    FieldName = FieldStartChar FieldChar*
//!    FieldStartChar = [!-9] | [;~]  (* ASCII 0x21-0x39, 0x3B-0x7E, excluding "#" and "-" *)
//!    FieldChar = [!-9] | [;~]       (* ASCII 0x21-0x39, 0x3B-0x7E *)
//!
//!    (* Values *)
//!    ValuePart = (SimpleValue | MultilineValue)
//!    SimpleValue = WhiteSpace* Value? NewLine
//!    MultilineValue = WhiteSpace* Value? NewLine (ValueContinuation | CommentContinuation)*
//!    ValueContinuation = WhiteSpace+ Value NewLine
//!    CommentContinuation = "#" AnyChar* NewLine ValueContinuation
//!
//!    (* Basic elements *)
//!    Value = NonNewline+
//!    WhiteSpace = " " | "\t"
//!    NonNewline = <any character except newline>
//!    AnyChar = <any character>
//!    ```
//!

/// Parse complete stanzas, with minimal syntax checking. See also
/// `FieldParser`.
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
    pub fn next(self: *Self, errorInfo: *ErrorInfo) Error![]const u8 {
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

    /// Extended `StanzaParser` error information if `next` returns an error.
    pub const ErrorInfo = struct {
        /// Slice into SOURCE provided to init.
        offender: []const u8,

        line: usize,
        col: usize,

        /// An undefined ErrorInfo struct, suitable to provide to a
        /// call to `next`.
        pub const empty: @This() = undefined;
    };

    pub const Error = error{ Eof, InvalidFieldName };

    fn invalidFieldName(self: Self, errorInfo: *ErrorInfo) Error {
        errorInfo.* = .{
            .offender = self.source[self.index .. self.index + 1],
            .line = self.line_no,
            .col = self.col_no,
        };
        return error.InvalidFieldName;
    }

    const Self = @This();
};

// -- FieldParser --------------------------------------------------

/// Parse one field/value pair at a time. Pre-allocates temporary
/// buffer at initialisation, and potentially allocates at each call
/// to `next` if parsed values exceed pre-allocated size. Does not
/// release buffer until `FieldParser` goes out of scope.
pub const FieldParser = struct {
    source: []const u8,
    allocator: std.mem.Allocator,

    // the following are mutated during parsing calls to `next()`
    buf: std.ArrayList(u8),
    index: usize,
    line_no: usize,
    col_no: usize,

    /// Optional configuration to supply to `init`.
    pub const Options = struct {
        initial_buffer_size: usize = 4096,
    };

    /// Field information returned by `next`.
    pub const Field = struct {
        /// shares lifetime with source
        name: []const u8,
        /// only valid until next call to next()
        value: []const u8,
    };

    /// Extended `FieldParser` error information if `next` returns an error.
    pub const ErrorInfo = struct {
        /// Slice into SOURCE provided to init.
        offender: []const u8,

        line: usize,
        col: usize,

        /// An undefined ErrorInfo struct, suitable to provide to a
        /// call to `next()`.
        pub const empty: @This() = undefined;
    };

    pub const Error = error{
        Eof,
        InvalidName,
        InvalidDefinition,
    };

    /// Create a `FieldParser`.
    pub fn init(allocator: std.mem.Allocator, source: []const u8, opts: Options) !FieldParser {
        const buf = try std.ArrayList(u8).initCapacity(allocator, opts.initial_buffer_size);
        return FieldParser{
            .source = source,
            .index = 0,
            .line_no = 1,
            .col_no = 0,
            .buf = buf,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buf.deinit();
    }

    /// Lifetime of returned field: name shares lifetime with source.
    /// value is valid only until the next call to `next`, and shares
    /// lifetime with this instance of `FieldParser`.
    pub fn next(self: *Self, errorInfo: *ErrorInfo) !Field {
        const State = enum {
            start,
            field,
            value_start,
            value_start_newline,
            value,
            value_newline,
            value_continuation,
            value_continuation_comment,
            comment,
            done,
        };

        var state: State = .start;
        var field_start: usize = 0;
        var field_end: usize = 0;
        self.buf.clearRetainingCapacity();

        while (self.index < self.source.len) : ({
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
                    if (isFieldStart(c)) {
                        field_start = self.index;
                        state = .field;
                        continue;
                    }
                    switch (c) {
                        '#' => state = .comment,
                        '-' => return self.invalidName(errorInfo),
                        else => {},
                    }
                },

                .field => {
                    if (isFieldContinue(c)) {
                        field_end = self.index;
                    } else if (c == ':') {
                        state = .value_start;
                    } else if (c == '\n') {
                        return self.invalidDefinition(errorInfo);
                    } else if (isWhitespace(c)) {
                        // allow whitespace other than newline after field name and before colon
                    } else {
                        return self.invalidDefinition(errorInfo);
                    }
                },

                .value_start => {
                    if (c == '\n') {
                        // possible field with empty value
                        state = .value_start_newline;
                        continue;
                    }
                    if (isWhitespace(c)) continue;
                    try self.buf.append(c);
                    state = .value;
                },

                .value_start_newline => {
                    if (isWhitespace(c)) {
                        // a continuation line
                        state = .value_start;
                        continue;
                    }
                    // the beginning of a new field, so backtrack to previous empty field
                    self.index -= 1;
                    state = .done;
                },

                .value => {
                    switch (c) {
                        '\n' => state = .value_newline,
                        else => try self.buf.append(c),
                    }
                },

                .value_newline => {
                    switch (c) {
                        '\n' => state = .done,
                        ' ', '\t' => state = .value_continuation,
                        '#' => state = .value_continuation_comment,
                        else => {
                            self.index -= 1; // backtrack
                            state = .done;
                        },
                    }
                },

                .value_continuation => {
                    switch (c) {
                        ' ', '\t' => {},
                        else => {
                            // TODO: does spec require a space to be inserted? It seems logical to do so.
                            try self.buf.append(' ');
                            try self.buf.append(c);
                            state = .value;
                        },
                    }
                },

                .value_continuation_comment => {
                    switch (c) {
                        '\n' => state = .value_newline,
                        else => {},
                    }
                },

                .comment => {
                    switch (c) {
                        '\n' => state = .start,
                        else => {},
                    }
                },

                .done => {
                    return Field{
                        .name = self.source[field_start .. field_end + 1],
                        .value = self.buf.items,
                    };
                },
            }
        }

        // Handle end of source
        switch (state) {
            .value, .value_start, .value_start_newline, .value_newline, .value_continuation, .value_continuation_comment, .done => {
                return Field{
                    .name = self.source[field_start .. field_end + 1],
                    .value = self.buf.items,
                };
            },
            .field => return self.invalidDefinition(errorInfo),
            .start, .comment => {},
        }
        return error.Eof;
    }

    /// Reset parser state and initialize with new source. Use this
    /// interface to avoid creating a new FieldParser when parsing a
    /// large number of stanzas.
    pub fn reset(self: *Self, new_source: []const u8) void {
        self.source = new_source;
        self.index = 0;
        self.line_no = 0;
        self.col_no = 0;
        self.buf.clearRetainingCapacity();
    }

    fn invalidName(self: Self, errorInfo: *ErrorInfo) Error {
        const index = self.safeIndex();
        errorInfo.* = .{
            .offender = self.source[index .. index + 1],
            .line = self.line_no,
            .col = self.col_no,
        };
        return error.InvalidName;
    }

    fn invalidDefinition(self: Self, errorInfo: *ErrorInfo) Error {
        const index = self.safeIndex();
        errorInfo.* = .{
            .offender = self.source[index .. index + 1],
            .line = self.line_no,
            .col = self.col_no,
        };
        return error.InvalidDefinition;
    }

    fn safeIndex(self: Self) usize {
        var index = self.index;
        if (self.source.len == 0) {
            index = 0;
        } else if (index >= self.source.len) {
            index = self.source.len - 1;
        }
        return index;
    }

    const Self = @This();
};

fn isFieldStart(c: u8) bool {
    // - field names must not start with U+0023 (#) and U+002D (-).
    if (c == '#' or c == '-')
        return false;
    return isFieldContinue(c);
}

fn isFieldContinue(c: u8) bool {
    // - field names composed of U+0021 (!) through U+0039 (9), and U+003B
    //   (;) through U+007E (~), inclusive.
    if (c >= '!' and c <= '9')
        return true;
    if (c >= ';' and c <= '~')
        return true;
    return false;
}

fn isWhitespace(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n' => true,
        else => false,
    };
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
    var errorInfo = StanzaParser.ErrorInfo.empty;
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
    var errorInfo = StanzaParser.ErrorInfo.empty;
    try testing.expectError(StanzaParser.Error.Eof, parser.next(&errorInfo));
}

test "dcf one space only" {
    const in = " ";
    var parser = StanzaParser.init(in);
    var errorInfo = StanzaParser.ErrorInfo.empty;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in, s1);
}

test "dcf one newline only" {
    const in = "\n";
    var parser = StanzaParser.init(in);
    var errorInfo = StanzaParser.ErrorInfo.empty;
    try testing.expectError(StanzaParser.Error.Eof, parser.next(&errorInfo));
}

test "dcf newlines-only input" {
    const in = "\n\n\n";
    var parser = StanzaParser.init(in);
    var errorInfo = StanzaParser.ErrorInfo.empty;
    try testing.expectError(StanzaParser.Error.Eof, parser.next(&errorInfo));
}

test "dcf stanza invalid field - dash start" {
    const in =
        \\-Stanza: one
        \\
    ;
    var parser = StanzaParser.init(in);
    var errorInfo = StanzaParser.ErrorInfo.empty;
    const s1 = parser.next(&errorInfo);
    try testing.expectError(StanzaParser.Error.InvalidFieldName, s1);
    try testing.expectEqualStrings("-", errorInfo.offender);
    try testing.expectEqual(1, errorInfo.line);
    try testing.expectEqual(0, errorInfo.col);
}

test "dcf stanza invalid field - dash in the middle is ok" {
    const in = "S-tanza: one";
    var parser = StanzaParser.init(in);
    var errorInfo = StanzaParser.ErrorInfo.empty;
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
    var errorInfo = StanzaParser.ErrorInfo.empty;
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
    var errorInfo = StanzaParser.ErrorInfo.empty;
    const s1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings(in1, s1);
}

//

test "dcf field basic" {
    const input =
        \\Stanza: one
        \\Field1: value1
    ;

    const allocator = testing.allocator;

    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    // First field
    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Stanza", f1.name);
    try testing.expectEqualStrings("one", f1.value);

    // Second field
    const f2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field1", f2.name);
    try testing.expectEqualStrings("value1", f2.value);

    // Should be end of input
    const f3 = parser.next(&errorInfo);
    try testing.expectError(FieldParser.Error.Eof, f3);
}

test "dcf field continuation - simple continue" {
    const input =
        \\Field: line 1
        \\       line 2
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("line 1 line 2", f1.value);
}

test "dcf field continuation - with comment ignored" {
    const input =
        \\Field: line 1
        \\  line 2
        \\# comment
        \\  line 3
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("line 1 line 2 line 3", f1.value);
}

test "dcf field continuation - indented comment is part of value" {
    const input =
        \\Field: line 1
        \\  line 2
        \\  # comment
        \\  line 3
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("line 1 line 2 # comment line 3", f1.value);
}

test "dcf field continuation - unindented line after comment is not part of value" {
    const input =
        \\Field: line 1
        \\  line 2
        \\# comment
        \\line 3
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("line 1 line 2", f1.value);
}

test "dcf field continuation - unindented line after comment begins next field" {
    const input =
        \\Field: line 1
        \\  line 2
        \\# comment
        \\Field2: value2
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("line 1 line 2", f1.value);

    const f2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field2", f2.name);
    try testing.expectEqualStrings("value2", f2.value);
}

test "dcf field continuation - unindented line after continuation begins next field" {
    const input =
        \\Field: line 1
        \\  line 2
        \\     line 3
        \\Field2: value2
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("line 1 line 2 line 3", f1.value);

    const f2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field2", f2.name);
    try testing.expectEqualStrings("value2", f2.value);
}

test "dcf field invalid - bad name" {
    const input = "-BadName: foo";
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    try testing.expectError(error.InvalidName, parser.next(&errorInfo));
}

test "dcf field invalid - field without value at eof" {
    const input = "Empty foo";
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    try testing.expectError(error.InvalidDefinition, parser.next(&errorInfo));
}

test "dcf field invalid - field without value in the middle" {
    const input =
        \\Field1: value1
        \\Empty foo
        \\Field3: value3
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field1", f1.name);
    try testing.expectEqualStrings("value1", f1.value);

    try testing.expectError(error.InvalidDefinition, parser.next(&errorInfo));

    const f3 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field3", f3.name);
    try testing.expectEqualStrings("value3", f3.value);
}

test "dcf field whitespace - before colon" {
    const input = "Field    :value1";
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("value1", f1.value);
}

test "dcf field whitespace - after colon" {
    const input = "Field    :         value1";
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("value1", f1.value);
}

test "dcf field whitespace - before and after first name" {
    const input =
        \\
        \\
        \\Field: value1
        \\
        \\
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field", f1.name);
    try testing.expectEqualStrings("value1", f1.value);
}

test "dcf stanza fields - base" {
    const input =
        \\Stanza: one
        \\Field1: value 1
        \\Field2: value 2
        \\
        \\Stanza: two
        \\Field1: value 3
        \\Field2: value 4
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Stanza", f1.name);
    try testing.expectEqualStrings("one", f1.value);

    const f2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field1", f2.name);
    try testing.expectEqualStrings("value 1", f2.value);

    const f3 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field2", f3.name);
    try testing.expectEqualStrings("value 2", f3.value);

    const f4 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Stanza", f4.name);
    try testing.expectEqualStrings("two", f4.value);

    const f5 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field1", f5.name);
    try testing.expectEqualStrings("value 3", f5.value);

    const f6 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Field2", f6.name);
    try testing.expectEqualStrings("value 4", f6.value);

    try testing.expectError(error.Eof, parser.next(&errorInfo));
}

test "dcf field with no value" {
    const input =
        \\Package: foo
        \\Suggests:
        \\Imports: bar
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Package", f1.name);
    try testing.expectEqualStrings("foo", f1.value);

    const f2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Suggests", f2.name);
    try testing.expectEqualStrings("", f2.value);

    const f3 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Imports", f3.name);
    try testing.expectEqualStrings("bar", f3.value);
}

test "dcf regression - field with newline value" {
    const input =
        \\StartsWithNewline:
        \\  continue 1
        \\           continue 2
        \\Normal: foo
    ;
    const allocator = testing.allocator;
    var parser = try FieldParser.init(allocator, input, .{});
    defer parser.deinit();
    var errorInfo = FieldParser.ErrorInfo.empty;

    const f1 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("StartsWithNewline", f1.name);
    try testing.expectEqualStrings("continue 1 continue 2", f1.value);

    const f2 = try parser.next(&errorInfo);
    try testing.expectEqualStrings("Normal", f2.name);
    try testing.expectEqualStrings("foo", f2.value);
}

test "dcf integration" {
    const in =
        \\Stanza: one
        \\Field: field-one
        \\
        \\Stanza: two
        \\Field: field-two
        \\
    ;

    const expected: [4]FieldParser.Field = .{
        .{ .name = "Stanza", .value = "one" },
        .{ .name = "Field", .value = "field-one" },
        .{ .name = "Stanza", .value = "two" },
        .{ .name = "Field", .value = "field-two" },
    };
    var exIdx: usize = 0;

    const allocator = testing.allocator;

    var stanzas = StanzaParser.init(in);
    var stanzaError = StanzaParser.ErrorInfo.empty;
    var fields = try FieldParser.init(allocator, "", .{});
    defer fields.deinit();
    var fieldError = FieldParser.ErrorInfo.empty;

    while (true) {
        const stanza = stanzas.next(&stanzaError) catch |err| switch (err) {
            error.Eof => break,
            else => |e| {
                std.debug.print("unexpected stanza error: {}", .{e});
                unreachable;
            },
        };

        fields.reset(stanza);

        while (true) {
            const field = fields.next(&fieldError) catch |err| switch (err) {
                error.Eof => break,
                else => |e| {
                    std.debug.print("unexpected field error: {}", .{e});
                    unreachable;
                },
            };
            try testing.expectEqualStrings(expected[exIdx].name, field.name);
            try testing.expectEqualStrings(expected[exIdx].value, field.value);
            exIdx += 1;
        }
    }
}
