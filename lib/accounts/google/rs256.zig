const std = @import("std");

const testing = @import("../testing.zig");

const modulus_bits_min = 2048;
const modulus_bits_max = 4096;
const Modulus = std.crypto.ff.Modulus(modulus_bits_max);

const pem_begin = "-----BEGIN PRIVATE KEY-----";
const pem_end = "-----END PRIVATE KEY-----";

const rsa_encryption_oid = [_]u8{ 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };

const sha256_digest_info = [_]u8{
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01,
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
};

pub const PrivateKey = struct {
    modulus: []const u8,
    exponent: []const u8,

    pub fn deinit(self: *const PrivateKey, gpa: std.mem.Allocator) void {
        std.crypto.secureZero(u8, @constCast(self.exponent));
        gpa.free(self.exponent);
        gpa.free(self.modulus);
    }

    pub fn signatureLength(self: *const PrivateKey) usize {
        return self.modulus.len;
    }
};

const Element = struct {
    tag: u8,
    start: usize,
    end: usize,

    const sequence = 0x30;
    const integer = 0x02;
    const octet_string = 0x04;
    const object_identifier = 0x06;

    fn parse(bytes: []const u8, index: usize) error{BadPrivateKey}!Element {
        if (index + 2 > bytes.len) return error.BadPrivateKey;
        const tag = bytes[index];
        const size_byte = bytes[index + 1];
        var start = index + 2;
        var length: usize = size_byte;
        if (size_byte & 0x80 != 0) {
            const size_length = size_byte & 0x7f;
            if (size_length == 0 or size_length > 4) return error.BadPrivateKey;
            if (start + size_length > bytes.len) return error.BadPrivateKey;
            length = 0;
            for (bytes[start..][0..size_length]) |byte| length = (length << 8) | byte;
            start += size_length;
        }
        if (length > bytes.len - start) return error.BadPrivateKey;
        return .{ .tag = tag, .start = start, .end = start + length };
    }

    fn expect(bytes: []const u8, index: usize, tag: u8) error{BadPrivateKey}!Element {
        const found = try parse(bytes, index);
        if (found.tag != tag) return error.BadPrivateKey;
        return found;
    }

    fn content(self: *const Element, bytes: []const u8) []const u8 {
        return bytes[self.start..self.end];
    }
};

pub fn parsePem(gpa: std.mem.Allocator, pem: []const u8) !PrivateKey {
    const begin = std.mem.indexOf(u8, pem, pem_begin) orelse return error.BadPrivateKey;
    const body_start = begin + pem_begin.len;
    const end = std.mem.indexOfPos(u8, pem, body_start, pem_end) orelse return error.BadPrivateKey;
    const body = pem[body_start..end];

    const decoder = std.base64.standard.decoderWithIgnore("\r\n");
    const der = try gpa.alloc(u8, decoder.calcSizeUpperBound(body.len));
    defer {
        std.crypto.secureZero(u8, der);
        gpa.free(der);
    }
    const der_length = decoder.decode(der, body) catch return error.BadPrivateKey;
    return parseDer(gpa, der[0..der_length]);
}

pub fn sign(key: *const PrivateKey, message: []const u8, out: []u8) !void {
    const length = key.signatureLength();
    std.debug.assert(out.len == length);
    var encoded_buffer: [@divExact(modulus_bits_max, 8)]u8 = undefined;
    const encoded = encoded_buffer[0..length];
    const digest_start = length - std.crypto.hash.sha2.Sha256.digest_length;
    const info_start = digest_start - sha256_digest_info.len;
    encoded[0] = 0x00;
    encoded[1] = 0x01;
    @memset(encoded[2 .. info_start - 1], 0xff);
    encoded[info_start - 1] = 0x00;
    @memcpy(encoded[info_start..digest_start], &sha256_digest_info);
    const digest = encoded[digest_start..][0..std.crypto.hash.sha2.Sha256.digest_length];
    std.crypto.hash.sha2.Sha256.hash(message, digest, .{});

    const modulus = Modulus.fromBytes(key.modulus, .big) catch return error.BadPrivateKey;
    const base = Modulus.Fe.fromBytes(modulus, encoded, .big) catch return error.BadPrivateKey;
    const signature = modulus.powWithEncodedExponent(base, key.exponent, .big) catch
        return error.BadPrivateKey;
    signature.toBytes(out, .big) catch return error.BadPrivateKey;
}

fn parseDer(gpa: std.mem.Allocator, der: []const u8) !PrivateKey {
    const info = try Element.expect(der, 0, Element.sequence);
    const version = try Element.expect(der, info.start, Element.integer);
    const algorithm = try Element.expect(der, version.end, Element.sequence);
    const oid = try Element.expect(der, algorithm.start, Element.object_identifier);
    if (!std.mem.eql(u8, oid.content(der), &rsa_encryption_oid)) return error.BadPrivateKey;
    const wrapped = try Element.expect(der, algorithm.end, Element.octet_string);

    const key = wrapped.content(der);
    const rsa = try Element.expect(key, 0, Element.sequence);
    const rsa_version = try Element.expect(key, rsa.start, Element.integer);
    const modulus_element = try Element.expect(key, rsa_version.end, Element.integer);
    const public_exponent = try Element.expect(key, modulus_element.end, Element.integer);
    const private_exponent = try Element.expect(key, public_exponent.end, Element.integer);

    const modulus = unsignedBytes(modulus_element.content(key));
    const bits = modulus.len * 8 - @clz(modulus[0]);
    if (bits < modulus_bits_min or bits > modulus_bits_max) return error.BadPrivateKey;
    const exponent = unsignedBytes(private_exponent.content(key));

    const modulus_copy = try gpa.dupe(u8, modulus);
    errdefer gpa.free(modulus_copy);
    const exponent_copy = try gpa.dupe(u8, exponent);
    return .{ .modulus = modulus_copy, .exponent = exponent_copy };
}

fn unsignedBytes(integer: []const u8) []const u8 {
    if (integer.len == 0) return &.{0};
    var start: usize = 0;
    while (start + 1 < integer.len and integer[start] == 0) start += 1;
    return integer[start..];
}

test "parsePem reads the modulus and the private exponent of a PKCS#8 key" {
    const gpa = std.testing.allocator;
    const key = try parsePem(gpa, testing.private_key_pem);
    defer key.deinit(gpa);

    var modulus: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&modulus, fixture_modulus_hex);
    try std.testing.expectEqualSlices(u8, &modulus, key.modulus);
    try std.testing.expectEqual(@as(usize, 256), key.signatureLength());
    try std.testing.expectEqual(@as(usize, 255), key.exponent.len);
}

const fixture_body = body: {
    const pem = testing.private_key_pem;
    break :body pem[pem_begin.len + 1 .. pem.len - pem_end.len - 1];
};

const fixture_modulus_hex =
    "8928EED36B49A3F8BBADB75DFF110FCC8844E80ADE5DDDD518E5508EE4A81849" ++
    "E3F7C5CA481A233F998950BB3B24E248BC15AA531205B077674EE74A59154023" ++
    "2308343AAE823D2FBAD5BEAD1B0A34DC9270869DAA34A39969A6D20268C75F12" ++
    "AEC2B1BEC9F24C6C2759CB1CC6BD9435771497043908EDE57E925258BB801952" ++
    "CDABC9E61813B915D99AA422B0C7E5A74025ED4BE35F9046B604D39C18FA98D9" ++
    "F4AC9537751A87B592904301700F7C8BB64EA9226768FDE95168AD81460CB762" ++
    "BF977FB4A227FB8C5F1FAE0394401A92FC29CB82DD6BC8A306075BEEBEFB33B1" ++
    "D5EDF67A0E337852EFF82CE8B04FBA3E93FA8A17AEC8E4E7C0C320BE63FAF3B9";

const fixture_message = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJhIn0";

const fixture_signature_hex =
    "880677e1aa20d14cb6bc90fbf3bc5076c9c874881e262f09998ec0ae747eff13" ++
    "9389d173660412396d229bf6ba8341cb06c53afb04612af8b9e995407d145ad1" ++
    "8cb1933bfbe87d7a36c684738faf3ff29a1144e7831d786cb8bedc501961e335" ++
    "0b7fd074db8328294a27721ca6714f739546d2f001753c62fe2999962ef2a6cf" ++
    "77eb4600ea4c6dd430c35de4ed29209433aba0bad2ffe6ced6209dc4dd3a6431" ++
    "c42a6c5ae36fd86817d534315ea3800cdb6f43aca53a8a0d6ca6860b4dfdd523" ++
    "7efe25823c9a8c5f2e85b4bac3e721a041ba02a8f520b1c448ef5e2f75ee2887" ++
    "2e3f20503b069e15046c5aa520792257f484437b6c02ca04e5c60604aac2a072";

test "sign matches the OpenSSL vector and verifies against the public key" {
    const gpa = std.testing.allocator;
    const key = try parsePem(gpa, testing.private_key_pem);
    defer key.deinit(gpa);

    var signature: [256]u8 = undefined;
    try sign(&key, fixture_message, &signature);
    var expected: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, fixture_signature_hex);
    try std.testing.expectEqualSlices(u8, &expected, &signature);

    const public_key = try std.crypto.Certificate.rsa.PublicKey.fromBytes(
        &.{ 0x01, 0x00, 0x01 },
        key.modulus,
    );
    try std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(
        256,
        signature,
        fixture_message,
        public_key,
        std.crypto.hash.sha2.Sha256,
    );
    signature[0] ^= 1;
    try std.testing.expectError(
        error.InvalidSignature,
        std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(
            256,
            signature,
            fixture_message,
            public_key,
            std.crypto.hash.sha2.Sha256,
        ),
    );
}

test "parsePem accepts CRLF line ends and text around the block" {
    const gpa = std.testing.allocator;
    const size = std.mem.replacementSize(u8, testing.private_key_pem, "\n", "\r\n");
    const crlf = try gpa.alloc(u8, size);
    defer gpa.free(crlf);
    _ = std.mem.replace(u8, testing.private_key_pem, "\n", "\r\n", crlf);
    const key = try parsePem(gpa, crlf);
    defer key.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 256), key.signatureLength());

    const framed = "junk\n" ++ testing.private_key_pem ++ "\nmore";
    const framed_key = try parsePem(gpa, framed);
    defer framed_key.deinit(gpa);
    try std.testing.expectEqualSlices(u8, key.exponent, framed_key.exponent);
}

test "parsePem rejects a missing marker, bad base64, and a truncated body" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.BadPrivateKey, parsePem(gpa, fixture_body));
    try std.testing.expectError(error.BadPrivateKey, parsePem(gpa, pem_begin ++ "\n" ++ pem_end));
    try std.testing.expectError(
        error.BadPrivateKey,
        parsePem(gpa, pem_begin ++ "\n!!!!\n" ++ pem_end),
    );
    const cut = pem_begin ++ "\n" ++ fixture_body[0..400] ++ "\n" ++ pem_end;
    try std.testing.expectError(error.BadPrivateKey, parsePem(gpa, cut));
}

fn wrapPkcs8(gpa: std.mem.Allocator, oid: []const u8, key_der: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const algorithm_length = 2 + oid.len + 2;
    const info_length = 3 + 2 + algorithm_length + 4 + key_der.len;
    try out.appendSlice(gpa, &.{ Element.sequence, 0x82 });
    try out.append(gpa, @intCast(info_length >> 8));
    try out.append(gpa, @intCast(info_length & 0xff));
    try out.appendSlice(gpa, &.{ Element.integer, 0x01, 0x00 });
    try out.appendSlice(gpa, &.{ Element.sequence, @intCast(algorithm_length) });
    try out.appendSlice(gpa, &.{ Element.object_identifier, @intCast(oid.len) });
    try out.appendSlice(gpa, oid);
    try out.appendSlice(gpa, &.{ 0x05, 0x00 });
    try out.appendSlice(gpa, &.{ Element.octet_string, 0x82 });
    try out.append(gpa, @intCast(key_der.len >> 8));
    try out.append(gpa, @intCast(key_der.len & 0xff));
    try out.appendSlice(gpa, key_der);
    return out.toOwnedSlice(gpa);
}

fn rsaKeyDer(gpa: std.mem.Allocator, modulus_bytes: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const content_length = 3 + 4 + modulus_bytes + 3 + 3;
    try out.appendSlice(gpa, &.{ Element.sequence, 0x82 });
    try out.append(gpa, @intCast(content_length >> 8));
    try out.append(gpa, @intCast(content_length & 0xff));
    try out.appendSlice(gpa, &.{ Element.integer, 0x01, 0x00 });
    try out.appendSlice(gpa, &.{ Element.integer, 0x82 });
    try out.append(gpa, @intCast(modulus_bytes >> 8));
    try out.append(gpa, @intCast(modulus_bytes & 0xff));
    try out.append(gpa, 0x81);
    try out.appendNTimes(gpa, 0x01, modulus_bytes - 1);
    try out.appendSlice(gpa, &.{ Element.integer, 0x01, 0x03 });
    try out.appendSlice(gpa, &.{ Element.integer, 0x01, 0x05 });
    return out.toOwnedSlice(gpa);
}

test "parseDer rejects a foreign algorithm and a modulus outside the range" {
    const gpa = std.testing.allocator;
    const ecdsa_oid = [_]u8{ 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
    const key_2048 = try rsaKeyDer(gpa, 256);
    defer gpa.free(key_2048);
    const foreign = try wrapPkcs8(gpa, &ecdsa_oid, key_2048);
    defer gpa.free(foreign);
    try std.testing.expectError(error.BadPrivateKey, parseDer(gpa, foreign));

    const accepted = try wrapPkcs8(gpa, &rsa_encryption_oid, key_2048);
    defer gpa.free(accepted);
    const key = try parseDer(gpa, accepted);
    defer key.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 256), key.modulus.len);
    try std.testing.expectEqualSlices(u8, &.{0x05}, key.exponent);

    const key_1024 = try rsaKeyDer(gpa, 128);
    defer gpa.free(key_1024);
    const small = try wrapPkcs8(gpa, &rsa_encryption_oid, key_1024);
    defer gpa.free(small);
    try std.testing.expectError(error.BadPrivateKey, parseDer(gpa, small));

    const key_8192 = try rsaKeyDer(gpa, 1024);
    defer gpa.free(key_8192);
    const large = try wrapPkcs8(gpa, &rsa_encryption_oid, key_8192);
    defer gpa.free(large);
    try std.testing.expectError(error.BadPrivateKey, parseDer(gpa, large));
}

test "Element.parse refuses every element that reaches past the input" {
    try std.testing.expectError(error.BadPrivateKey, Element.parse(&.{ 0x02, 0x05, 0x01 }, 0));
    try std.testing.expectError(error.BadPrivateKey, Element.parse(&.{ 0x30, 0x82, 0x01 }, 0));
    try std.testing.expectError(
        error.BadPrivateKey,
        Element.parse(&.{ 0x30, 0x85, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00 }, 0),
    );
    try std.testing.expectError(error.BadPrivateKey, Element.parse(&.{0x02}, 0));
    try std.testing.expectError(error.BadPrivateKey, Element.parse(&.{ 0x02, 0x00 }, 2));

    const short = try Element.parse(&.{ 0x02, 0x01, 0x07 }, 0);
    try std.testing.expectEqual(@as(usize, 2), short.start);
    try std.testing.expectEqual(@as(usize, 3), short.end);
    const long = try Element.parse(&.{ 0x04, 0x81, 0x02, 0xaa, 0xbb }, 0);
    try std.testing.expectEqual(@as(usize, 3), long.start);
    try std.testing.expectEqual(@as(usize, 5), long.end);
}

test "a zero exponent is a bad key rather than a crash" {
    var modulus: [256]u8 = undefined;
    _ = try std.fmt.hexToBytes(&modulus, fixture_modulus_hex);
    const key: PrivateKey = .{ .modulus = &modulus, .exponent = &.{0x00} };
    var signature: [256]u8 = undefined;
    try std.testing.expectError(error.BadPrivateKey, sign(&key, "m", &signature));
}

test unsignedBytes {
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02 }, unsignedBytes(&.{ 0x00, 0x01, 0x02 }));
    try std.testing.expectEqualSlices(u8, &.{0x80}, unsignedBytes(&.{ 0x00, 0x80 }));
    try std.testing.expectEqualSlices(u8, &.{0x00}, unsignedBytes(&.{ 0x00, 0x00 }));
    try std.testing.expectEqualSlices(u8, &.{0x7f}, unsignedBytes(&.{0x7f}));
    try std.testing.expectEqualSlices(u8, &.{0x00}, unsignedBytes(&.{}));
}
