//! The Date header, formatted once a second and cached.

const std = @import("std");
const Io = std.Io;

const Date = @This();

/// Always 29 characters: `Sun, 06 Nov 1994 08:49:37 GMT`.
pub const len = 29;

buf: [len]u8 = undefined,
/// Which second the buffer holds. Negative means nothing in it yet.
rendered_for: i64 = -1,

/// The current date. It re-renders at most once a second.
pub fn value(d: *Date, io: Io) []const u8 {
    const now = Io.Timestamp.now(io, .real);
    const secs: i64 = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
    if (secs != d.rendered_for) {
        format(secs, &d.buf);
        d.rendered_for = secs;
    }
    return &d.buf;
}

/// Renders a Unix timestamp as an IMF-fixdate.
pub fn format(unix_seconds: i64, out: *[len]u8) void {
    const days_total = @divFloor(unix_seconds, std.time.s_per_day);
    var rem = unix_seconds - days_total * std.time.s_per_day;

    const hour: u32 = @intCast(@divFloor(rem, 3600));
    rem -= @as(i64, hour) * 3600;
    const minute: u32 = @intCast(@divFloor(rem, 60));
    const second: u32 = @intCast(rem - @as(i64, minute) * 60);

    // 1970-01-01 was a Thursday.
    const weekday: usize = @intCast(@mod(days_total + 4, 7));
    const ymd = civilFromDays(days_total);

    @memcpy(out[0..3], day_names[weekday]);
    out[3] = ',';
    out[4] = ' ';
    twoDigits(out[5..7], ymd.day);
    out[7] = ' ';
    @memcpy(out[8..11], month_names[ymd.month - 1]);
    out[11] = ' ';
    fourDigits(out[12..16], ymd.year);
    out[16] = ' ';
    twoDigits(out[17..19], hour);
    out[19] = ':';
    twoDigits(out[20..22], minute);
    out[22] = ':';
    twoDigits(out[23..25], second);
    @memcpy(out[25..29], " GMT");
}

const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
const month_names = [_][]const u8{
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
};

fn twoDigits(out: *[2]u8, v: u32) void {
    out[0] = '0' + @as(u8, @intCast((v / 10) % 10));
    out[1] = '0' + @as(u8, @intCast(v % 10));
}

fn fourDigits(out: *[4]u8, v: i64) void {
    const n: u32 = @intCast(@mod(v, 10000));
    out[0] = '0' + @as(u8, @intCast(n / 1000));
    out[1] = '0' + @as(u8, @intCast((n / 100) % 10));
    out[2] = '0' + @as(u8, @intCast((n / 10) % 10));
    out[3] = '0' + @as(u8, @intCast(n % 10));
}

const Civil = struct { year: i64, month: u32, day: u32 };

/// Howard Hinnant's days_from_civil, inverted. Doing the leap years by
/// hand goes wrong around March.
fn civilFromDays(z_in: i64) Civil {
    const z = z_in + 719468;
    const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
    const doe: u64 = @intCast(z - era * 146097);
    const yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
    const doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp = (5 * doy + 2) / 153;
    const d = doy - (153 * mp + 2) / 5 + 1;
    const m = if (mp < 10) mp + 3 else mp - 9;
    return .{
        .year = if (m <= 2) y + 1 else y,
        .month = @intCast(m),
        .day = @intCast(d),
    };
}

const testing = std.testing;

fn rendered(unix_seconds: i64) [len]u8 {
    var out: [len]u8 = undefined;
    format(unix_seconds, &out);
    return out;
}

test "the epoch" {
    try testing.expectEqualStrings("Thu, 01 Jan 1970 00:00:00 GMT", &rendered(0));
}

test "the example from the RFC" {
    try testing.expectEqualStrings("Sun, 06 Nov 1994 08:49:37 GMT", &rendered(784111777));
}

test "a leap day" {
    try testing.expectEqualStrings("Sat, 29 Feb 2020 12:00:00 GMT", &rendered(1582977600));
}

test "the day before a leap day, and the day after" {
    try testing.expectEqualStrings("Fri, 28 Feb 2020 00:00:00 GMT", &rendered(1582848000));
    try testing.expectEqualStrings("Sun, 01 Mar 2020 00:00:00 GMT", &rendered(1583020800));
}

test "2000 was a leap year and 1900 was not" {
    try testing.expectEqualStrings("Tue, 29 Feb 2000 00:00:00 GMT", &rendered(951782400));
    // Before the epoch. 1900 is not a leap year, so 1 Mar comes right
    // after 28 Feb here.
    try testing.expectEqualStrings("Wed, 28 Feb 1900 00:00:00 GMT", &rendered(-2203977600));
    try testing.expectEqualStrings("Thu, 01 Mar 1900 00:00:00 GMT", &rendered(-2203891200));
}

test "before the epoch" {
    try testing.expectEqualStrings("Wed, 31 Dec 1969 23:59:59 GMT", &rendered(-1));
}

test "every second of a day round trips through the formatter" {
    // Catches an hour, minute or second wrapping in the wrong place.
    var i: i64 = 0;
    while (i < 86400) : (i += 7) {
        const out = rendered(1700000000 + i);
        try testing.expectEqual(@as(usize, len), out.len);
        try testing.expect(out[3] == ',' and out[19] == ':' and out[22] == ':');
        try testing.expectEqualStrings(" GMT", out[25..29]);
    }
}

test "it only renders once a second" {
    var d: Date = .{};
    const first = d.value(testing.io);
    const second = d.value(testing.io);
    try testing.expectEqualStrings(first, second);
    try testing.expectEqual(@as(usize, len), first.len);
    try testing.expect(d.rendered_for > 1_700_000_000);
}
