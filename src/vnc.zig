const std = @import("std");
const rfb_version = "RFB 003.008\n";

pub fn handshake(host: [4]u8, port: u16, sharing: bool) !struct { std.net.Stream, usize, usize, usize } {
    var stream = try std.net.tcpConnectToAddress(std.net.Address.initIp4(host, port));

    var rfb_buffer = try stream.reader().readBytesNoEof(12);
    std.debug.assert(std.mem.eql(u8, &rfb_buffer, rfb_version));
    try stream.writer().writeAll(rfb_version);

    const number_of_security_types = try stream.reader().readInt(u8, .little);
    std.debug.assert(number_of_security_types == 1);
    try stream.writer().writeAll(&.{1});

    const security_result = try stream.reader().readInt(u32, .little);
    std.debug.assert(security_result == 1);
    try stream.writer().writeAll(&.{if (sharing) 1 else 0});

    const width: usize = @intCast(try stream.reader().readInt(u16, .little));
    const height: usize = @intCast(try stream.reader().readInt(u16, .little));
    const bits_per_pixel: usize = @intCast(try stream.reader().readByte());
    try stream.reader().skipBytes(16, .{});
    const name_length = try stream.reader().readInt(u32, .big);
    try stream.reader().skipBytes(name_length, .{});

    return .{ stream, width, height, bits_per_pixel };
}

pub fn send_framebuffer_update_request(writer: std.net.Stream.Writer, width: usize, height: usize, incremental: bool) !void {
    try writer.writeByte(3);
    try writer.writeByte(if (incremental) 1 else 0);
    try writer.writeInt(u16, 0, std.builtin.Endian.big);
    try writer.writeInt(u16, 0, std.builtin.Endian.big);
    try writer.writeInt(u16, @intCast(width), std.builtin.Endian.big);
    try writer.writeInt(u16, @intCast(height), std.builtin.Endian.big);
}

pub fn read_framebuffer_update(reader: std.net.Stream.Reader, pixels: []u8, pixels_mutex: *std.Thread.Mutex, width: usize, bytes_per_pixel: usize) !void {
    std.debug.assert(try reader.readByte() == 0); // padding

    pixels_mutex.lock();
    for (0..try reader.readInt(u16, std.builtin.Endian.big)) |_| {
        const x: usize = @intCast(try reader.readInt(u16, std.builtin.Endian.big));
        const y: usize = @intCast(try reader.readInt(u16, std.builtin.Endian.big));
        const w: usize = @intCast(try reader.readInt(u16, std.builtin.Endian.big));
        const h: usize = @intCast(try reader.readInt(u16, std.builtin.Endian.big));
        std.debug.assert(try reader.readInt(i32, std.builtin.Endian.big) == 0); // encoding

        for (0..h) |y_| {
            const i = (x + (y + y_) * width) * bytes_per_pixel;
            try reader.readNoEof(pixels[i .. i + w * bytes_per_pixel]);
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

pub fn send_key_event(writer: std.net.Stream.Writer, down: bool, key: u32) !void {
    try writer.writeByte(4);
    try writer.writeByte(if (down) 1 else 0);
    try writer.writeInt(u16, 0, std.builtin.Endian.big);
    try writer.writeInt(u32, key, std.builtin.Endian.big);
}
