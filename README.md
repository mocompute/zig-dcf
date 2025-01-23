# dcf

A simple pre-allocating parser for Debian Control File
formatted strings.

## Build

```zig
zig build
```

## Documentation

```zig
zig build docs
```

## Usage

```zig
    var stanzas = StanzaParser.init(in);
    var stanza_error = StanzaParser.ErrorInfo.empty;

    // make a FieldParser with default options, providing an allocator
    var fields = try FieldParser.init(allocator, "", .{});
    defer fields.deinit();
    var field_error = FieldParser.ErrorInfo.empty;

    while (true) {
        const stanza = stanzas.next(&stanza_error) catch |err| switch (err) {
            error.Eof => break,
            else => |e| {
                std.debug.print("unexpected stanza error: {}", .{e});
                unreachable;
            },
        };

        // init FieldParser for this stanza
        fields.reset(stanza);

        while (true) {
            const field = fields.next(&field_error) catch |err| switch (err) {
                error.Eof => break,
                else => |e| {
                    std.debug.print("unexpected field error: {}", .{e});
                    unreachable;
                },
            };

            // Do something with field.name and field.value here.
            // field.value will be overwritten at the next call to `next`.

        }
    }
```
