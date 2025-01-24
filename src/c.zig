//! The C API.

const std = @import("std");
const testing = std.testing;
const root = @import("root.zig");
const StanzaParser = root.StanzaParser;
const FieldParser = root.FieldParser;

/// Initialize a StanzaParser. Lifetime of source must exceed
/// lifetime of the parser.
pub export fn dcf_stanza_parser_init(source: [*]const u8, source_len: usize) StanzaParser {
    return StanzaParser.initPtr(source, source_len);
}

/// Lifetime of returned field: name shares lifetime with source.
/// value is valid only until the next call to `next`, and shares
/// lifetime with this instance of `FieldParser`. `error_info` will
/// only be valid if a non-allocator `Error` is returned.
pub export fn dcf_stanza_parser_next(
    parser: *StanzaParser,
    out: *[*]const u8,
    out_len: *usize,
    error_info: *StanzaParser.ErrorInfo.C,
) c_int {
    var zig_error_info: StanzaParser.ErrorInfo = undefined;

    const res = parser.next(&zig_error_info) catch |err| {
        error_info.* = zig_error_info.toC();
        return stanzaParserErrorToCInt(err);
    };
    out.* = res.ptr;
    out_len.* = res.len;
    return 0;
}

fn stanzaParserErrorToCInt(err: StanzaParser.Error) c_int {
    return switch (err) {
        error.Eof => 1,
        error.InvalidFieldName => 2,
    };
}

/// Initialize a `FieldParser`. Lifetime of `source` and `buf` must
/// exceed FieldParser lifetime. `buf` should be large enough to
/// contain the largest possible field value in the input source, or
/// else an OutOfMemory error will be returned by `next`.
pub export fn dcf_field_parser_init(
    source: [*]const u8,
    source_len: usize,
    buf: [*]u8,
    buf_len: usize,
) FieldParser {
    return FieldParser.initPtr(source, source_len, buf, buf_len);
}

/// Lifetime of returned field: name shares lifetime with source.
/// value is valid only until the next call to `next`, and shares
/// lifetime with this instance of `FieldParser`. `error_info`
/// will only be valid if a non-allocator `Error` is returned.
pub export fn dcf_field_parser_next(
    parser: *FieldParser,
    out: *FieldParser.Field.C,
    error_info: *FieldParser.ErrorInfo.C,
) c_int {
    var zig_error_info: FieldParser.ErrorInfo = undefined;

    const res = parser.next(&zig_error_info) catch |err| {
        error_info.* = zig_error_info.toC();
        return fieldParserErrorToCInt(err);
    };
    out.* = res.toC();
    return 0;
}

/// Reset parser state and initialize with new source string.
/// Use this interface to avoid creating a new FieldParser (and
/// its heap-allocated temporary buffer) when parsing multiple
/// stanzas.
pub export fn dcf_field_parser_reset(
    parser: *FieldParser,
    source: [*]const u8,
    source_len: usize,
) void {
    parser.resetPtr(source, source_len);
}

fn fieldParserErrorToCInt(err: (FieldParser.Error || error{OutOfMemory})) c_int {
    return switch (err) {
        error.OutOfMemory => 1,
        error.Eof => 2,
        error.InvalidName => 3,
        error.InvalidDefinition => 4,
    };
}

test "c-dcf stanza basic" {
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

    var c_parser = dcf_stanza_parser_init(in.ptr, in.len);
    var c_error_info: StanzaParser.ErrorInfo.C = undefined;

    var out_ptr: [*]const u8 = undefined;
    var out_len: usize = undefined;
    const c_s1_res = dcf_stanza_parser_next(&c_parser, &out_ptr, &out_len, &c_error_info);
    try testing.expectEqual(0, c_s1_res);
    try testing.expectEqualStrings(in1, out_ptr[0..out_len]);

    const c_s2_res = dcf_stanza_parser_next(&c_parser, &out_ptr, &out_len, &c_error_info);
    try testing.expectEqual(0, c_s2_res);
    try testing.expectEqualStrings(in2, out_ptr[0..out_len]);

    const c_expect_eof_res = dcf_stanza_parser_next(&c_parser, &out_ptr, &out_len, &c_error_info);
    try testing.expectEqual(stanzaParserErrorToCInt(error.Eof), c_expect_eof_res);
}

test "c-dcf field basic" {
    const input =
        \\Stanza: one
        \\Field1: value1
    ;

    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);

    var c_parser = dcf_field_parser_init(input.ptr, input.len, buf.ptr, buf.len);
    var c_error_info: FieldParser.ErrorInfo.C = undefined;
    var c_f1_field: FieldParser.Field.C = undefined;
    const c_f1_res = dcf_field_parser_next(&c_parser, &c_f1_field, &c_error_info);
    try testing.expectEqual(0, c_f1_res);
    try testing.expectEqualStrings("Stanza", c_f1_field.name[0..c_f1_field.name_len]);
    try testing.expectEqualStrings("one", c_f1_field.value[0..c_f1_field.value_len]);

    var c_f2_field: FieldParser.Field.C = undefined;
    const c_f2_res = dcf_field_parser_next(&c_parser, &c_f2_field, &c_error_info);
    try testing.expectEqual(0, c_f2_res);
    try testing.expectEqualStrings("Field1", c_f2_field.name[0..c_f2_field.name_len]);
    try testing.expectEqualStrings("value1", c_f2_field.value[0..c_f2_field.value_len]);

    const c_f3_res = dcf_field_parser_next(&c_parser, &c_f2_field, &c_error_info);
    try testing.expectEqual(fieldParserErrorToCInt(error.Eof), c_f3_res);
}
