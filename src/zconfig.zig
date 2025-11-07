const std = @import("std");
const testing = std.testing;

const Error = error{
    SomethingWentWrong, // A general error occurred
    InvalidName, // Name contains invalid characters
    NotFound, // Node not found
};

/// Represents a configuration node
/// Each node has a name, optional value, and can have child nodes
/// Nodes are organized in a tree structure
const ZConfig = struct {
    container: ZConfiguration = undefined,
    itemName: ?[]u8 = null,
    value: ?[]u8 = null,
    parent: ?*ZConfig = null,
    first_child: ?*ZConfig = null,
    next: ?*ZConfig = null,
    owned: bool = false, // whether this node memory was allocator-created

    pub fn destroy(self: *ZConfig) void {
        // Recursively destroy children
        var child_it = self.first_child;
        while (child_it) |c| {
            const next_sibling = c.next;
            c.destroy(); // Will free itself if owned
            child_it = next_sibling;
        }
        self.first_child = null;

        // Recursively destroy siblings (only when called by parent)
        // Note: Caller should not rely on sibling cleanup here; handled by parent's loop.

        // Free value memory
        if (self.value) |v| {
            self.container.allocator.free(v);
            self.value = null;
        }

        // Free the itemName memory
        if (self.itemName) |n| {
            self.container.allocator.free(n);
            self.itemName = null;
        }

        // Free self if heap-allocated
        if (self.owned) {
            self.container.allocator.destroy(self);
        }
    }

    /// Get the name of this configuration item
    pub fn name(self: *const ZConfig) ?[]const u8 {
        return self.itemName;
    }

    /// Get the value of this configuration item
    pub fn getValue(self: *const ZConfig) ?[]const u8 {
        return self.value;
    }

    /// Set the value of this configuration item
    pub fn setValue(self: *ZConfig, value: []const u8) !void {
        // Free the old value if it exists
        if (self.value) |v| {
            self.container.allocator.free(v);
        }

        // Allocates and duplicates the new value
        self.value = try self.container.allocator.dupe(u8, value);
    }

    /// Get the next sibling configuration item
    pub fn getNext(self: *const ZConfig) ?*ZConfig {
        return self.next;
    }

    /// Get the first child configuration item
    pub fn child(self: *const ZConfig) ?*ZConfig {
        return self.first_child;
    }

    /// Add a child configuration item with the given key
    pub fn add(self: *ZConfig, key: []const u8) !*ZConfig {
        if (!ZConfiguration.isValidName(key)) {
            return Error.InvalidName;
        }
        const new_node = try self.container.allocator.create(ZConfig);
        new_node.* = .{
            .container = self.container,
            .itemName = try self.container.allocator.dupe(u8, key),
            .value = null,
            .parent = self,
            .first_child = null,
            .next = null,
            .owned = true,
        };

        // append to child list
        if (self.first_child) |head| {
            var tail = head;
            while (tail.next) |n| tail = n;
            tail.next = new_node;
        } else {
            self.first_child = new_node;
        }
        return new_node;
    }

    /// Add a child configuration item with the given key and value
    pub fn addWithValue(self: *ZConfig, key: []const u8, value: []const u8) !*ZConfig {
        var node = try self.add(key);
        try node.setValue(value);
        return node;
    }

    /// Locate a direct child node by name
    pub fn childByName(self: *ZConfig, key: []const u8) ?*ZConfig {
        var it = self.first_child;
        while (it) |n| : (it = n.next) {
            if (n.itemName) |nm| {
                if (std.mem.eql(u8, nm, key)) return n;
            }
        }
        return null;
    }

    /// Locate a node by path, e.g. "main/frontend/bind"
    /// Returns error.NotFound if not found
    /// Path components are separated by '/'
    /// Empty components are ignored
    /// Returns pointer to the located node or error.NotFound if not found
    /// Path is relative to this node
    /// Example: root.locate("main/frontend/bind")
    /// will locate the "bind" node under "frontend" under "main"
    pub fn locate(self: *ZConfig, path: []const u8) !*ZConfig {
        var it: *ZConfig = self;
        var iter = std.mem.splitScalar(u8, path, '/');
        while (iter.next()) |part| {
            if (part.len == 0) continue;
            const childn = it.childByName(part) orelse return Error.NotFound;
            it = childn;
        }
        return it;
    }

    /// Iterator for iterating over child nodes
    pub const Iterator = struct {
        current: ?*ZConfig,

        pub fn next(self: *Iterator) ?*ZConfig {
            const node = self.current orelse return null;
            self.current = node.next;
            return node;
        }
    };

    /// Returns an iterator over child nodes
    pub fn iterator(self: *ZConfig) Iterator {
        return Iterator{ .current = self.first_child };
    }
};

pub const ZConfiguration = struct {
    allocator: std.mem.Allocator = undefined,

    const Self = @This();

    /// Init with allocator
    pub fn init(allocator: std.mem.Allocator) !Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Validate name according to ZPL spec: alphanumeric + "$-_@.&+/"
    fn isValidName(name: []const u8) bool {
        if (name.len == 0) return false;
        for (name) |ch| {
            const valid = std.ascii.isAlphanumeric(ch) or
                ch == '$' or ch == '-' or ch == '_' or ch == '@' or
                ch == '.' or ch == '&' or ch == '+' or ch == '/';
            if (!valid) return false;
        }
        return true;
    }

    /// Create a new ZConfig instance (root node on stack)
    pub fn new(self: Self, name: []const u8, parent: ?*ZConfig) !ZConfig {
        if (!isValidName(name)) {
            return Error.InvalidName;
        }

        // Allocates and duplicates the name
        const name_ptr = try self.allocator.dupe(u8, name);

        const config = ZConfig{
            .container = self,
            .itemName = name_ptr,
            .value = null,
            .parent = parent,
            .first_child = null,
            .next = null,
            .owned = false,
        };
        return config;
    }

    fn parseValue(alloc: std.mem.Allocator, src: []const u8) ![]u8 {
        var s = std.mem.trim(u8, src, " \t\r\n");
        if (s.len == 0) return alloc.dupe(u8, s);
        // Strip comments outside quotes
        var in_single = false;
        var in_double = false;
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            const ch = s[i];
            if (ch == '\'' and !in_double) in_single = !in_single else if (ch == '"' and !in_single) in_double = !in_double else if (ch == '#' and !in_single and !in_double) {
                s = std.mem.trimRight(u8, s[0..i], " \t");
                break;
            }
        }
        // Remove surrounding quotes if any
        if ((s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') or (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')) {
            return alloc.dupe(u8, s[1 .. s.len - 1]);
        }
        return alloc.dupe(u8, s);
    }

    /// Load ZPL from string and return root node
    pub fn loadFromString(self: Self, text: []const u8) !*ZConfig {
        // Create an implicit root
        var root = try self.allocator.create(ZConfig);
        root.* = try self.new("root", null);
        root.owned = true; // allocated
        errdefer root.destroy();

        var lines = std.mem.splitScalar(u8, text, '\n');
        var stack: [64]?*ZConfig = undefined;
        var stack_levels: [64]usize = undefined;
        var sp: usize = 0;
        stack[0] = root;
        stack_levels[0] = 0;
        sp = 1;

        var line_no: usize = 0;
        while (lines.next()) |raw_line| : (line_no += 1) {
            var line = raw_line;
            // normalize Windows CRLF
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            // trim trailing comments that are on blank lines
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue; // skip blanks
            if (trimmed[0] == '#') continue; // full-line comment

            // Count indentation (spaces only, per ZPL spec)
            var indent: usize = 0;
            while (indent < line.len and line[indent] == ' ') : (indent += 1) {}
            const content = std.mem.trimLeft(u8, line[indent..], " ");
            if (content.len == 0) continue;

            // Map indent to level: 0 => 0, any >0 => 1 + (indent-1)/4
            var level: usize = 0;
            if (indent > 0) level = 1 + (indent - 1) / 4;

            // Adjust stack
            while (sp > 0 and stack_levels[sp - 1] >= level + 1) {
                sp -= 1;
            }
            const parent = stack[sp - 1] orelse unreachable;

            // Split key and value
            const eq_index = std.mem.indexOfScalar(u8, content, '=');
            if (eq_index) |pos| {
                const key = std.mem.trimRight(u8, std.mem.trimLeft(u8, content[0..pos], " \t"), " \t");
                const val_src = std.mem.trimLeft(u8, content[pos + 1 ..], " \t");
                var node = try parent.add(key);
                const val = try parseValue(self.allocator, val_src);
                node.value = val;
            } else {
                const key = std.mem.trim(u8, content, " \t");
                _ = try parent.add(key);
            }

            // Push new node as parent for deeper levels
            const last_child = parent.first_child orelse unreachable; // at least one added
            var tail = last_child;
            while (tail.next) |n| tail = n;
            // tail is the current node we just added
            if (sp < stack.len) {
                stack[sp] = tail;
                stack_levels[sp] = level + 1;
                sp += 1;
            } else {
                return Error.SomethingWentWrong; // stack overflow
            }
        }

        return root;
    }

    /// Load ZPL from file and return root node
    pub fn load(self: Self, filename: []const u8) !*ZConfig {
        var file = try std.fs.cwd().openFile(filename, .{});
        defer file.close();
        const data = try file.readToEndAlloc(self.allocator, std.math.maxInt(usize));
        defer self.allocator.free(data);
        return try self.loadFromString(data);
    }
};

test "dupe" {
    const a = "test";
    const b = try testing.allocator.dupe(u8, a);
    defer testing.allocator.free(b);
    try testing.expectEqualStrings(a, b);
}

test "basic create destroy" {
    const zc = try ZConfiguration.init(testing.allocator);
    var item = try zc.new("root", null);
    // build simple tree and cleanup
    var child = try item.add("child");
    try child.setValue("42");
    defer item.destroy();
    try testing.expectEqualStrings("root", item.name() orelse unreachable);
    try testing.expectEqualStrings("child", item.child().?.name().?);
    try testing.expectEqualStrings("42", item.child().?.getValue().?);
}

const example_zpl =
    \\context
    \\    iothreads = 1
    \\    verbose = 1      #   Ask for a trace
    \\main
    \\  type = zqueue    #  ZMQ_DEVICE type
    \\  frontend
    \\      option
    \\          hwm = 1000
    \\          swap = 25000000     #  25MB
    \\      bind = 'inproc://addr1'
    \\      bind = 'ipc://addr2'
    \\  backend
    \\      bind = inproc://addr3
;

test "parse example zpl and locate" {
    const zc = try ZConfiguration.init(testing.allocator);
    const root = try zc.loadFromString(example_zpl);
    defer root.destroy();
    const ctx = try root.locate("context");
    try testing.expectEqualStrings("1", ctx.childByName("iothreads").?.getValue().?);
    const main = try root.locate("main");
    try testing.expectEqualStrings("zqueue", main.childByName("type").?.getValue().?);
    const fe = try main.locate("frontend");
    const first_bind = fe.childByName("bind") orelse unreachable;
    try testing.expectEqualStrings("inproc://addr1", first_bind.getValue().?);
}

test "setValue replaces existing value" {
    const zc = try ZConfiguration.init(testing.allocator);
    var item = try zc.new("root", null);
    defer item.destroy();

    var child = try item.add("key");
    try child.setValue("initial");
    try testing.expectEqualStrings("initial", child.getValue().?);

    try child.setValue("updated");
    try testing.expectEqualStrings("updated", child.getValue().?);
}

test "addWithValue creates node with value" {
    const zc = try ZConfiguration.init(testing.allocator);
    var item = try zc.new("root", null);
    defer item.destroy();

    _ = try item.addWithValue("key1", "value1");
    const child = item.childByName("key1").?;
    try testing.expectEqualStrings("value1", child.getValue().?);
}

test "multiple children and getNext" {
    const zc = try ZConfiguration.init(testing.allocator);
    var item = try zc.new("root", null);
    defer item.destroy();

    _ = try item.add("first");
    _ = try item.add("second");
    _ = try item.add("third");

    const first = item.child().?;
    try testing.expectEqualStrings("first", first.name().?);

    const second = first.getNext().?;
    try testing.expectEqualStrings("second", second.name().?);

    const third = second.getNext().?;
    try testing.expectEqualStrings("third", third.name().?);

    try testing.expect(third.getNext() == null);
}

test "childByName with multiple children" {
    const zc = try ZConfiguration.init(testing.allocator);
    var item = try zc.new("root", null);
    defer item.destroy();

    _ = try item.addWithValue("alpha", "1");
    _ = try item.addWithValue("beta", "2");
    _ = try item.addWithValue("gamma", "3");

    try testing.expectEqualStrings("2", item.childByName("beta").?.getValue().?);
    try testing.expectEqualStrings("1", item.childByName("alpha").?.getValue().?);
    try testing.expectEqualStrings("3", item.childByName("gamma").?.getValue().?);
    try testing.expect(item.childByName("delta") == null);
}

test "nested structure" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    var level1 = try root.add("level1");
    var level2 = try level1.add("level2");
    _ = try level2.addWithValue("deep", "value");

    const found = try root.locate("level1/level2");
    try testing.expectEqualStrings("level2", found.name().?);
    try testing.expectEqualStrings("value", found.childByName("deep").?.getValue().?);
}

test "locate with empty path components" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    var child = try root.add("child");
    _ = try child.addWithValue("key", "value");

    const found = try root.locate("child//key");
    try testing.expectEqualStrings("value", found.getValue().?);
}

test "locate returns error for invalid path" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    _ = try root.add("valid");

    const result = root.locate("valid/invalid");
    try testing.expectError(Error.NotFound, result);
}

test "parse value with single quotes" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key = 'value in quotes'";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("value in quotes", node.getValue().?);
}

test "parse value with double quotes" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key = \"value in quotes\"";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("value in quotes", node.getValue().?);
}

test "parse value strips inline comments" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key = value # this is a comment";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("value", node.getValue().?);
}

test "parse ignores full-line comments" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input =
        \\# This is a comment
        \\key = value
        \\# Another comment
    ;
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("value", node.getValue().?);
}

test "parse value with hash in quotes preserves hash" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key = 'value # with hash'";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("value # with hash", node.getValue().?);
}

test "parse empty value" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key = ";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("", node.getValue().?);
}

test "parse key without value" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expect(node.getValue() == null);
}

test "parse handles CRLF line endings" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "key = value\r\nkey2 = value2\r\n";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    try testing.expectEqualStrings("value", root.childByName("key").?.getValue().?);
    try testing.expectEqualStrings("value2", root.childByName("key2").?.getValue().?);
}

test "parse nested indentation levels" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input =
        \\level0
        \\    level1a
        \\        level2
        \\    level1b
    ;
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const l0 = root.childByName("level0").?;
    const l1a = l0.childByName("level1a").?;
    const l1b = l0.childByName("level1b").?;
    const l2 = l1a.childByName("level2").?;

    try testing.expectEqualStrings("level1a", l1a.name().?);
    try testing.expectEqualStrings("level1b", l1b.name().?);
    try testing.expectEqualStrings("level2", l2.name().?);
}

test "parse multiple siblings with same name" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input =
        \\bind = addr1
        \\bind = addr2
        \\bind = addr3
    ;
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const first = root.childByName("bind").?;
    try testing.expectEqualStrings("addr1", first.getValue().?);

    const second = first.getNext().?;
    try testing.expectEqualStrings("addr2", second.getValue().?);

    const third = second.getNext().?;
    try testing.expectEqualStrings("addr3", third.getValue().?);
}

test "parse trims whitespace around keys and values" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "  key  =  value  ";
    const root = try zc.loadFromString(input);
    defer root.destroy();

    const node = root.childByName("key").?;
    try testing.expectEqualStrings("value", node.getValue().?);
}

test "new with empty name returns error" {
    const zc = try ZConfiguration.init(testing.allocator);
    const result = zc.new("", null);
    try testing.expectError(Error.InvalidName, result);
}

test "deep locate path" {
    const zc = try ZConfiguration.init(testing.allocator);
    const root = try zc.loadFromString(example_zpl);
    defer root.destroy();

    const node = try root.locate("main/frontend/option");
    try testing.expectEqualStrings("option", node.name().?);
    try testing.expectEqualStrings("1000", node.childByName("hwm").?.getValue().?);
}

test "valid names according to ZPL spec" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    // Valid characters: alphanumeric + "$-_@.&+/"
    _ = try root.add("simple");
    _ = try root.add("with-dash");
    _ = try root.add("with_underscore");
    _ = try root.add("with.dot");
    _ = try root.add("with$dollar");
    _ = try root.add("with@at");
    _ = try root.add("with&ampersand");
    _ = try root.add("with+plus");
    _ = try root.add("path/separator");
    _ = try root.add("MixedCase123");
}

test "invalid names rejected" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    // Invalid characters
    try testing.expectError(Error.InvalidName, root.add("with space"));
    try testing.expectError(Error.InvalidName, root.add("with\ttab"));
    try testing.expectError(Error.InvalidName, root.add("with*asterisk"));
    try testing.expectError(Error.InvalidName, root.add("with=equals"));
    try testing.expectError(Error.InvalidName, root.add("with#hash"));
}

test "parse rejects invalid names" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input = "invalid name = value";
    const result = zc.loadFromString(input);
    try testing.expectError(Error.InvalidName, result);
}

test "load from file" {
    const zc = try ZConfiguration.init(testing.allocator);
    const root = try zc.load("data/example.zpl");
    defer root.destroy();

    // Test context section
    const ctx = try root.locate("context");
    try testing.expectEqualStrings("1", ctx.childByName("iothreads").?.getValue().?);
    try testing.expectEqualStrings("1", ctx.childByName("verbose").?.getValue().?);

    // Test main section
    const main = try root.locate("main");
    try testing.expectEqualStrings("zqueue", main.childByName("type").?.getValue().?);

    // Test frontend
    const frontend = try main.locate("frontend");
    const first_bind = frontend.childByName("bind").?;
    try testing.expectEqualStrings("inproc://addr1", first_bind.getValue().?);
    try testing.expectEqualStrings("ipc://addr2", first_bind.getNext().?.getValue().?);

    // Test nested option
    const option = try root.locate("main/frontend/option");
    try testing.expectEqualStrings("1000", option.childByName("hwm").?.getValue().?);
    try testing.expectEqualStrings("25000000", option.childByName("swap").?.getValue().?);

    // Test backend
    const backend = try root.locate("main/backend");
    try testing.expectEqualStrings("inproc://addr3", backend.childByName("bind").?.getValue().?);
}

test "iterator over children" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    _ = try root.addWithValue("first", "1");
    _ = try root.addWithValue("second", "2");
    _ = try root.addWithValue("third", "3");

    var it = root.iterator();
    var count: usize = 0;

    const first = it.next().?;
    try testing.expectEqualStrings("first", first.name().?);
    try testing.expectEqualStrings("1", first.getValue().?);
    count += 1;

    const second = it.next().?;
    try testing.expectEqualStrings("second", second.name().?);
    try testing.expectEqualStrings("2", second.getValue().?);
    count += 1;

    const third = it.next().?;
    try testing.expectEqualStrings("third", third.name().?);
    try testing.expectEqualStrings("3", third.getValue().?);
    count += 1;

    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(usize, 3), count);
}

test "iterator on empty node" {
    const zc = try ZConfiguration.init(testing.allocator);
    var root = try zc.new("root", null);
    defer root.destroy();

    var it = root.iterator();
    try testing.expect(it.next() == null);
}

test "iterator with multiple nodes of same name" {
    const zc = try ZConfiguration.init(testing.allocator);
    const input =
        \\bind = addr1
        \\bind = addr2
        \\bind = addr3
    ;
    const root = try zc.loadFromString(input);
    defer root.destroy();

    var it = root.iterator();
    var count: usize = 0;

    while (it.next()) |node| {
        try testing.expectEqualStrings("bind", node.name().?);
        count += 1;
    }

    try testing.expectEqual(@as(usize, 3), count);
}
