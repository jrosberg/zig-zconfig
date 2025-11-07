const std = @import("std");
const log = std.log;
const zc = @import("zconfig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const config = try zc.ZConfiguration.init(allocator);
    const root = try config.load("data/example.zpl");
    defer root.destroy();

    // print all top-level nodes in the configuration using iterator
    var it = root.iterator();
    while (it.next()) |node| {
        log.info("Node: {s}", .{node.name().?});
    }

    // find specific node
    const bind = root.locate("main/frontend/bind") catch {
        log.err("Failed to locate 'main/frontend/bind' in configuration", .{});
        return;
    };

    log.info("bind= {s}", .{bind.getValue().?});
}
