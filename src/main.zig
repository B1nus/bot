const std = @import("std");
const assert = std.debug.assert;
const print = std.debug.print;
const Endian = std.builtin.Endian;
const Timer = std.time.Timer;
const c = @cImport({
    @cInclude("tesseract/capi.h");
});
const raylib = @import("raylib");

const ollama_template = "You are roleplaying as a linux user. You can write commands like this <command ls\\n>. Use backspace \\\"\\b\\\" to erase what you just wrote <command \\b\\b\\b>.";
const prompt_template = "This is what you see on the linux machine:\\n<eye>{s}</eye>\\n";
const parent_model = "llama3";
const model_name = "bot";
const ollama_host = "127.0.0.1";
const ollama_port = 11434;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var ollama_stream = try std.net.tcpConnectToHost(allocator, ollama_host, ollama_port);

    try create_model(&ollama_stream, allocator, parent_model, ollama_template);
    print("Successfully created model \"{s}\"\n", .{model_name});

    var response_buffer: [2048]u8 = undefined;
    const prompt = try std.fmt.allocPrint(allocator, prompt_template, .{"Joe mama! HAHAHA gottem."});
    defer allocator.free(prompt);
    try ollama_start_token_stream(&ollama_stream, allocator, &response_buffer, try std.fmt.allocPrint(allocator, prompt_template, .{"Joe mama! HAHAHA gottem."}));
    print("Succesfully started new token stream with prompt: \"{s}\"\n", .{prompt});

    while (try ollama_next_token(&ollama_stream, allocator, &response_buffer)) |token| {
        print("{s}", .{token});
    }
    print("\n", .{});

    var args = std.process.args();
    _ = args.skip();
    const port = 5900 + try std.fmt.parseInt(u16, args.next().?[1..], 10);

    var stream, const width, const height, const bits_per_pixel = try vnc_handshake("127.0.0.1", port, "RFB 003.008\n", true);
    defer stream.close();
    print("Sucessfully connected to vnc server at 127.0.0.1:{d}\n", .{port});

    raylib.initWindow(@intCast(width), @intCast(height), "bot");

    const bytes_per_pixel = @divExact(bits_per_pixel, 8);
    const pixels: []u8 = try allocator.alloc(u8, width * height * bytes_per_pixel);
    defer allocator.free(pixels);

    var text: ?[*:0]u8 = null;

    var pixels_mutex = std.Thread.Mutex{};
    var text_mutex = std.Thread.Mutex{};
    _ = try std.Thread.spawn(.{}, screen_loop, .{ &stream, pixels, &pixels_mutex, width, height, bytes_per_pixel });
    _ = try std.Thread.spawn(.{}, image_to_text_loop, .{ pixels, &pixels_mutex, width, height, bytes_per_pixel, &text, &text_mutex });
    print("Successfully started pixels thread and text thread\n", .{});

    while (!raylib.windowShouldClose()) {
        text_mutex.lock();
        if (text) |s| {
            print("{s}\n", .{s});
        }
        text_mutex.unlock();

        pixels_mutex.lock();
        const image = raylib.Image{
            .data = pixels.ptr,
            .width = @intCast(width),
            .height = @intCast(height),
            .format = raylib.PixelFormat.uncompressed_r8g8b8a8,
            .mipmaps = 1,
        };

        raylib.beginDrawing();
        raylib.clearBackground(raylib.Color.black);
        raylib.drawTexture(try raylib.loadTextureFromImage(image), 0, 0, raylib.Color.white);
        raylib.endDrawing();
        pixels_mutex.unlock();
    }
}

pub fn create_model(stream: *std.net.Stream, allocator: std.mem.Allocator, from: []const u8, template: []const u8) !void {
    const body = try std.fmt.allocPrint(allocator,
        \\{{
        \\"model":"{s}",
        \\"from":"{s}",
        \\"system":"{s}",
        \\"stream":false
        \\}}
    , .{ model_name, from, template });
    defer allocator.free(body);

    const request = try std.fmt.allocPrint(allocator,
        \\POST /api/create HTTP/1.1
        \\Host: {s}
        \\Content-Type: application/json
        \\Content-Length: {d}
        \\
        \\{s}
    , .{ ollama_host, body.len, body });
    defer allocator.free(request);

    try stream.writer().writeAll(request);

    var buffer: [2048]u8 = undefined;
    const n_read = try stream.reader().read(&buffer);
    assert(std.mem.startsWith(u8, buffer[0..n_read], "HTTP/1.1 200 OK"));
    assert(std.mem.endsWith(u8, buffer[0..n_read], "\"status\":\"success\"}"));
}

pub fn ollama_start_token_stream(stream: *std.net.Stream, allocator: std.mem.Allocator, buffer: []u8, prompt: []u8) !void {
    const body = try std.fmt.allocPrint(allocator,
        \\{{
        \\"model":"{s}",
        \\"prompt":"{s}",
        \\"stream":true
        \\}}
    , .{ model_name, prompt });
    defer allocator.free(body);

    const request = try std.fmt.allocPrint(allocator,
        \\POST /api/generate HTTP/1.1
        \\Host: {s}
        \\Content-Type: application/json
        \\Content-Length: {d}
        \\
        \\{s}
    , .{ ollama_host, body.len, body });
    defer allocator.free(request);

    try stream.writer().writeAll(request);
    const n_read = try stream.reader().read(buffer);
    assert(std.mem.startsWith(u8, buffer[0..n_read], "HTTP/1.1 200 OK"));
}

pub fn ollama_next_token(stream: *std.net.Stream, allocator: std.mem.Allocator, buffer: []u8) !?[]u8 {
    const n_read = try stream.reader().read(buffer);
    const i = "\r\n".len + std.mem.indexOf(u8, buffer[0..n_read], "\r\n").?;
    const json_str = std.mem.trimRight(u8, buffer[i..n_read], "\n");

    const Response = struct { response: []u8, done: bool };
    const parsed = try std.json.parseFromSlice(Response, allocator, json_str, .{ .ignore_unknown_fields = true });

    return if (parsed.value.done) null else parsed.value.response;
}

pub fn image_to_text_loop(pixels: []u8, pixels_mutex: *std.Thread.Mutex, width: usize, height: usize, bytes_per_pixel: usize, text: *?[*:0]u8, text_mutex: *std.Thread.Mutex) !void {
    const api = c.TessBaseAPICreate();
    assert(api != null);
    defer c.TessBaseAPIDelete(api);
    assert(c.TessBaseAPIInit3(api, null, "eng") == 0);

    while (true) {
        pixels_mutex.lock();
        c.TessBaseAPISetImage(api, pixels.ptr, @intCast(width), @intCast(height), @intCast(bytes_per_pixel), @intCast(bytes_per_pixel * width));
        pixels_mutex.unlock();
        text_mutex.lock();
        text.* = std.mem.span(c.TessBaseAPIGetUTF8Text(api));
        text_mutex.unlock();
    }
}

pub fn vnc_handshake(host: []const u8, port: u16, rfb_version: []const u8, sharing: bool) !struct { std.net.Stream, usize, usize, usize } {
    const addr = try std.net.Address.parseIp(host, port);
    var stream = try std.net.tcpConnectToAddress(addr);

    var rfb_buffer = try stream.reader().readBytesNoEof(12);
    assert(std.mem.eql(u8, &rfb_buffer, rfb_version));
    try stream.writer().writeAll(rfb_version);

    const number_of_security_types = try stream.reader().readInt(u8, Endian.little);
    assert(number_of_security_types == 1);
    try stream.writer().writeAll(&.{1});

    const security_result = try stream.reader().readInt(u32, Endian.little);
    assert(security_result == 1);
    try stream.writer().writeAll(&.{if (sharing) 1 else 0});

    const width: usize = @intCast(try stream.reader().readInt(u16, Endian.little));
    const height: usize = @intCast(try stream.reader().readInt(u16, Endian.little));
    const bits_per_pixel: usize = @intCast(try stream.reader().readByte());
    try stream.reader().skipBytes(16, .{});
    const name_length = try stream.reader().readInt(u32, Endian.big);
    try stream.reader().skipBytes(name_length, .{});

    return .{ stream, width, height, bits_per_pixel };
}

// Keeps sending framebuffer_update_requests and always keeps the pixels slice updated.
pub fn screen_loop(stream: *std.net.Stream, pixels: []u8, pixels_mutex: *std.Thread.Mutex, width: usize, height: usize, bytes_per_pixel: usize) !void {
    try send_framebuffer_update_request(stream, width, height, false);
    while (true) {
        switch (try stream.reader().readByte()) {
            0 => {
                try send_framebuffer_update_request(stream, width, height, false); // Try using incremental = true
                try read_framebuffer_update(stream, pixels, pixels_mutex, width, bytes_per_pixel);
            },
            else => unreachable,
        }
    }
}

pub fn send_framebuffer_update_request(stream: *std.net.Stream, width: usize, height: usize, incremental: bool) !void {
    try stream.writer().writeByte(3);
    try stream.writer().writeByte(if (incremental) 1 else 0);
    try stream.writer().writeInt(u16, 0, Endian.big);
    try stream.writer().writeInt(u16, 0, Endian.big);
    try stream.writer().writeInt(u16, @intCast(width), Endian.big);
    try stream.writer().writeInt(u16, @intCast(height), Endian.big);
}

pub fn read_framebuffer_update(stream: *std.net.Stream, pixels: []u8, pixels_mutex: *std.Thread.Mutex, width: usize, bytes_per_pixel: usize) !void {
    assert(try stream.reader().readByte() == 0); // padding

    pixels_mutex.lock();
    for (0..try stream.reader().readInt(u16, Endian.big)) |_| {
        const x: usize = @intCast(try stream.reader().readInt(u16, Endian.big));
        const y: usize = @intCast(try stream.reader().readInt(u16, Endian.big));
        const w: usize = @intCast(try stream.reader().readInt(u16, Endian.big));
        const h: usize = @intCast(try stream.reader().readInt(u16, Endian.big));
        assert(try stream.reader().readInt(i32, Endian.big) == 0); // encoding

        for (0..h) |y_| {
            const i = (x + (y + y_) * width) * bytes_per_pixel;
            try stream.reader().readNoEof(pixels[i .. i + w * bytes_per_pixel]);
        }

        // Remove transparency
        for (x..x + w) |x_| {
            for (y..y + h) |y_| {
                pixels[(x_ + y_ * width) * bytes_per_pixel + 3] = 0xFF;
            }
        }
    }
    pixels_mutex.unlock();
}

// https://github.com/D-Programming-Deimos/libX11/blob/master/c/X11/keysymdef.h
const tab = 0xff09;
const enter = 0xff0d;
const backspace = 0xff08;
pub fn write_string(stream: *std.net.Stream, text: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        var code: u32 = undefined;
        switch (text[i]) {
            '\\' => {
                if (i >= text.len - 1) {
                    break;
                }

                i += 1;
                switch (text[i]) {
                    '\\' => code = '\\',
                    'n' => code = enter,
                    't' => code = tab,
                    'b' => code = backspace,
                    else => unreachable,
                }
            },
            ' '...'\\' - 1, '\\' + 1...'~' => code = text[i],
            else => unreachable,
        }

        try send_key_event(stream, true, code);
        try send_key_event(stream, false, code);
    }
    return text[i..];
}

pub fn send_key_event(stream: *std.net.Stream, down: bool, key: u32) !void {
    try stream.writer().writeByte(4);
    try stream.writer().writeByte(if (down) 1 else 0);
    try stream.writer().writeInt(u16, 0, Endian.big);
    try stream.writer().writeInt(u32, key, Endian.big);
}
