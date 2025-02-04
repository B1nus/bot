pub const std = @import("std");
pub const print = std.debug.print;
pub const assert = std.debug.assert;

// I really should be using the std.http instead of raw
// doggin a tcp connection.
//
// But I'm gonna replace these api calls with my own
// inference code soon anyway so I can't be bothered.

pub const Response = struct {
    model: []u8,
    response: []u8,
    done: bool,
};

pub fn read_response(reader: std.net.Stream.Reader, buffer: []u8, allocator: std.mem.Allocator) !?std.json.Parsed(Response) {
    const len = try read_until_sequence(buffer, reader, "\r\n") - 2;
    if (len == 1 and buffer[0] == '0') {
        _ = try reader.readBytesNoEof(2);
        return null;
    } else {
        const chunk_size = try std.fmt.parseInt(usize, buffer[0..len], 16) + 2;
        try reader.readNoEof(buffer[0..chunk_size]);
        return try std.json.parseFromSlice(Response, allocator, buffer[0..chunk_size], .{ .ignore_unknown_fields = true });
    }
}

pub fn send_request(allocator: std.mem.Allocator, buffer: []u8, stream: std.net.Stream, api: []const u8, content: anytype) !void {
    const body = try std.json.stringifyAlloc(allocator, content, .{});
    const request = try std.fmt.allocPrint(allocator,
        \\POST /api/{s} HTTP/1.1
        \\Host:
        \\Content-Type: application/json
        \\Content-Length: {d}
        \\
        \\{s}
    , .{ api, body.len, body });
    try stream.writer().writeAll(request);

    const len1 = try read_until_sequence(buffer, stream.reader(), "\r\n\r\n");
    assert(std.mem.startsWith(u8, buffer[0..len1], "HTTP/1.1 200 OK"));

    if (std.mem.eql(u8, api, "create")) {
        const len2 = try read_until_sequence(buffer, stream.reader(), "}");
        assert(std.mem.endsWith(u8, buffer[0..len2], "{\"status\":\"success\"}"));
    }
}

pub fn read_until_sequence(buffer: []u8, reader: std.net.Stream.Reader, sequence: []const u8) !usize {
    var i: usize = 0;
    while (i < sequence.len or !std.mem.eql(u8, buffer[i - sequence.len .. i], sequence)) : (i += 1) {
        buffer[i] = try reader.readByte();
    }
    return i;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var buffer: [2048]u8 = undefined;
    const stream = try std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 11434));
    try send_request(allocator, &buffer, stream, "generate", .{ .model = "llama3", .prompt = "Hello my friend!", .stream = true });
    while (true) {
        if (try read_response(stream.reader(), &buffer, allocator)) |response| {
            defer response.deinit();
            print("model:{s} response:{s} done:{any}\n", .{ response.value.model, response.value.response, response.value.done });
        }
    }
}
