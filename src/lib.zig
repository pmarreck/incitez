const std = @import("std");

// ── Public Zig API ──────────────────────────────────────────────────
// Pure in-memory citation extraction. NO I/O in this module tree —
// all I/O lives in the C CLI behind the FFI boundary.

pub const version = "0.1.0";

pub const reporters = @import("reporters.zig");
pub const extraction = @import("extract.zig");
pub const resolution = @import("resolve.zig");
pub const cleaning = @import("clean.zig");
pub const ffi = @import("ffi.zig");

// ── C FFI exports ───────────────────────────────────────────────────

/// Returns the library version as a static null-terminated string (C ABI).
export fn incitez_version() [*:0]const u8 {
    return version;
}

// ── Tests ───────────────────────────────────────────────────────────

test "version export returns the semver string" {
    const v = incitez_version();
    try std.testing.expectEqualStrings(version, std.mem.span(v));
}

test {
    _ = reporters;
    _ = extraction;
    _ = resolution;
    _ = cleaning;
    _ = ffi;
}

comptime {
    // force analysis of ffi.zig so its `export fn`s are emitted into the
    // static library (imports are lazy; exports in unreferenced files vanish)
    _ = ffi;
}
