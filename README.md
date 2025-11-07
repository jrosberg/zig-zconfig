# zig-zconfig

A ZeroMQ ZConfig implementation in Zig.

Implements [rfc.zeromq.org/spec:4/ZPL](https://rfc.zeromq.org/spec:4/ZPL).

## Features

This is currently a read-only version. No saving implemented yet.

## Status

**Stable** - All ZPL specification requirements implemented and tested.

## Usage

```zig
const std = @import("std");
const zconfig = @import("zconfig");

// Initialize with allocator
const zc = try zconfig.ZConfiguration.init(std.heap.page_allocator);

// Load from file
const root = try zc.load("config.zpl");
defer root.destroy();

// Or load from string
const config_text =
    \\context
    \\    iothreads = 1
    \\    verbose = 1
    \\main
    \\    type = zqueue
    \\    frontend
    \\        bind = 'inproc://addr1'
    \\        bind = 'ipc://addr2'
;
const root = try zc.loadFromString(config_text);
defer root.destroy();

// Navigate the tree
const ctx = try root.locate("context");
const iothreads = ctx.childByName("iothreads").?.getValue().?; // "1"

const node_name = ctx.name();

// Build configuration programmatically
var config = try zc.new("root", null);
defer config.destroy();

var child = try config.add("server");
try child.setValue("localhost");
_ = try config.addWithValue("port", "8080");
```

## License

MIT License - see [LICENSE](LICENSE) file for details.
