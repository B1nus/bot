const std = @import("std");
const assert = std.debug.assert;
const Timer = std.time.Timer;
const ollama = @import("ollama.zig");
const vnc = @import("vnc.zig");
const c = @cImport(@cInclude("tesseract/capi.h"));

const ollama_brain_model = "dolphin-mistral";

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const stdout = std.io.getStdOut().writer();

    var ollama_buffer: [4096 * 8]u8 = undefined;
    const ollama_stream = try std.net.tcpConnectToAddress(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 11434));
    try ollama.send_request(allocator, &ollama_buffer, ollama_stream, "create", .{
        .model = "bot",
        .from = ollama_brain_model,
        .system = "You are a linux user and you write commands like this <write>ls\\n</write>. You have the username and password \"bot\"",
        // \\You speak like this <speak>I am listing the files</speak>.
        // \\You only offer short responses. About one sentence each.
        // \\The <eye> tags are mine and you are not allowed to use them ):<
        // \\You can erase a mistake with backspace <write>\b</write>
        // \\You can speak by using <speak>I'm going to write some python now</speak>
        .stream = false,
    });

    const vnc_stream, const width, const height, const bits_per_pixel = try vnc.handshake(.{ 127, 0, 0, 1 }, 5900, true);

    const bytes_per_pixel = @divExact(bits_per_pixel, 8);
    const pixels: []u8 = try allocator.alloc(u8, width * height * bytes_per_pixel);
    var pixels_mutex = std.Thread.Mutex{};

    var text: []u8 = "";
    // var prev: []u8 = "";
    var text_mutex = std.Thread.Mutex{};

    _ = try std.Thread.spawn(.{}, screen_loop, .{ vnc_stream, pixels, &pixels_mutex, width, height, bytes_per_pixel });
    _ = try std.Thread.spawn(.{}, image_to_text_loop, .{ pixels, &pixels_mutex, width, height, bytes_per_pixel, &text, &text_mutex });

    const State = enum {
        waiting,
        thought,
        keyboard_start_tag,
        keyboard_end_tag,
        keyboard,
        keyboard_backslash,
    };
    var tok_start: usize = 0;
    var tok_i: usize = 0;
    var state: State = .waiting;
    var prompt = try std.ArrayList(u8).initCapacity(allocator, 1_000_000);
    var written = try std.ArrayList(u8).initCapacity(allocator, 1_000);

    var wait_timer = try Timer.start();
    const wait_time = 5_000_000_000;

    // const diff_min = 10;
    const write_start = "<write>";
    const write_end = "</write>";
    const eye_start = "<eye>";
    const eye_end = "</eye>";

    while (true) {
        // text_mutex.lock();
        // const diff = text_difference(text, prev);
        //if (diff > diff_min or
        if (state == .waiting and wait_timer.read() > wait_time) {
            // if (state != .waiting) {
            //     // Skip rest of response
            //     while (try ollama.read_response(ollama_stream.reader(), &ollama_buffer, allocator)) |_| {}
            //
            //     // Finish their tags
            //     //
            //     // TODO: Check if this actually works.
            //     switch (state) {
            //         .keyboard, .keyboard_backslash => try prompt.writer().print(write_end, .{}),
            //         .keyboard_end_tag => try prompt.writer().print("{s}", .{write_end[tok_i - tok_start ..]}),
            //         .keyboard_start_tag => try prompt.writer().print("{s}{s}", .{ write_start[tok_i - tok_start ..], write_end }),
            //         .thought => {},
            //         .waiting => unreachable,
            //     }
            //
            //     // try prompt.writer().print("</bot>", .{});
            // }

            text_mutex.lock();
            try prompt.writer().print("\x1b[1m{s}{s}{s}\x1b[0m", .{ eye_start, text, eye_end });
            text_mutex.unlock();

            try ollama.send_request(allocator, &ollama_buffer, ollama_stream, "generate", .{
                .model = "bot",
                .prompt = prompt.items,
                .stream = true,
            });

            tok_i = prompt.items.len;
            tok_start = tok_i;

            state = .thought;
        }
        // prev = try allocator.alloc(u8, text.len);
        // std.mem.copyForwards(u8, prev, text);
        // text_mutex.unlock();

        if (state != .waiting) {
            if (try ollama.read_response(ollama_stream.reader(), &ollama_buffer, allocator)) |response| {
                try prompt.writer().writeAll(response.value.response);
                response.deinit();

                while (tok_i < prompt.items.len) {
                    switch (state) {
                        .thought => switch (prompt.items[tok_i]) {
                            '<' => {
                                state = .keyboard_start_tag;
                            },
                            else => {
                                tok_i += 1;
                                tok_start = tok_i;
                            },
                        },
                        .keyboard_start_tag => {
                            if (tok_i - tok_start == write_start.len) {
                                tok_start = tok_i;
                                state = .keyboard;
                            } else if (prompt.items[tok_i] == write_start[tok_i - tok_start]) {
                                tok_i += 1;
                            } else {
                                tok_i += 1;
                                state = .thought;
                            }
                        },
                        .keyboard_end_tag => {
                            if (tok_i - tok_start == write_end.len) {
                                tok_start = tok_i;
                                state = .thought;
                            } else if (prompt.items[tok_i] == write_end[tok_i - tok_start]) {
                                tok_i += 1;
                            } else {
                                try written.append('<');
                                try vnc.send_key_event(vnc_stream.writer(), true, '<');
                                try vnc.send_key_event(vnc_stream.writer(), false, '<');

                                tok_i = tok_start + 1;
                                tok_start = tok_start;
                                state = .keyboard;
                            }
                        },
                        .keyboard => {
                            switch (prompt.items[tok_i]) {
                                '\\' => {
                                    tok_i += 1;
                                    state = .keyboard_backslash;
                                },
                                '<' => {
                                    tok_i += 1;
                                    state = .keyboard_end_tag;
                                },
                                else => |char| {
                                    if (char < ' ' or char > '~') {
                                        continue;
                                    }

                                    try written.append(char);
                                    try vnc.send_key_event(vnc_stream.writer(), true, char);
                                    try vnc.send_key_event(vnc_stream.writer(), false, char);

                                    tok_i += 1;
                                    tok_start = tok_i;
                                },
                            }
                        },
                        .keyboard_backslash => {
                            // https://github.com/D-Programming-Deimos/libX11/blob/master/c/X11/keysymdef.h
                            var key: u32 = undefined;
                            key = switch (prompt.items[tok_i]) {
                                'n' => 0xff0d,
                                'b' => 0xff08,
                                't' => 0xff09,
                                else => unreachable,
                            };

                            try written.append('\\');
                            try written.append(prompt.items[tok_i]);
                            try vnc.send_key_event(vnc_stream.writer(), true, key);
                            try vnc.send_key_event(vnc_stream.writer(), false, key);

                            tok_i += 1;
                            tok_start = tok_i;
                            state = .keyboard;
                        },
                        else => unreachable,
                    }
                }
            } else {
                // Maybe we should keep outputing tokens?
                state = .waiting;
                wait_timer.reset();
                // try prompt.writer().print("\n", .{});
                // try prompt.writer().print("\n</bot>\n", .{});
            }
        }
        try stdout.print("\x1b[2J\x1b[H{s}\n", .{prompt.items});
        try stdout.print("\n{any}\n", .{state});
        try stdout.print("\"{s}\"\n", .{written.items});
        while (state == .waiting and wait_timer.read() <= wait_time) {
            try stdout.print("\x1b[?25l{d}\r", .{(wait_time - wait_timer.read()) / 1_000_000_000});
        }
    }
    try stdout.print("\x1b[?25h", .{});
}

// Try using a smarter ai
// Custom tokens
// Fine tuning
// RL

pub fn text_difference(prev: []u8, text: []u8) usize {
    var diff_count: usize = 0;
    for (0..@min(prev.len, text.len)) |i| {
        const prev_c = prev[i];
        const text_c = text[i];

        if (prev_c != text_c) {
            const prev_c_printable = prev_c >= ' ' and prev_c <= '~';
            const text_c_printable = text_c >= ' ' and text_c <= '~';
            if (prev_c_printable and text_c_printable) {
                diff_count += 1;
            }
        }
    }
    return diff_count + @max(prev.len, text.len) - @min(prev.len, text.len);
}

pub fn image_to_text_loop(pixels: []u8, pixels_mutex: *std.Thread.Mutex, width: usize, height: usize, bytes_per_pixel: usize, text: *[]u8, text_mutex: *std.Thread.Mutex) !void {
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

// Keeps sending framebuffer_update_requests and always keeps the pixels slice updated.
pub fn screen_loop(stream: std.net.Stream, pixels: []u8, pixels_mutex: *std.Thread.Mutex, width: usize, height: usize, bytes_per_pixel: usize) !void {
    try vnc.send_framebuffer_update_request(stream.writer(), width, height, false);
    while (true) {
        switch (try stream.reader().readByte()) {
            0 => {
                try vnc.send_framebuffer_update_request(stream.writer(), width, height, true); // incremental might cause worse performance.
                try vnc.read_framebuffer_update(stream.reader(), pixels, pixels_mutex, width, bytes_per_pixel);
            },
            else => unreachable,
        }
    }
}
