//! Optimized drop-in for std.json.Stringify (Zig 0.15.2).
//! Byte-identical output; same Options type; same public surface.
//!
//! NOT part of koruc's own build — no koru module imports this file. The
//! backend reads it at program-build time and installs it as
//! std/json/Stringify.zig inside a --zig-lib-dir overlay (a symlink mirror
//! of zig's real lib dir), so emitted programs' @import("std") resolves
//! this implementation without any source-visible change. The ../std.zig
//! import resolves to real std at its installed position.

const std = @import("../std.zig");
const Allocator = std.mem.Allocator;
const BitStack = std.BitStack;
const Writer = std.io.Writer;
const Stringify = @This();
const assert = std.debug.assert;

pub const Options = struct {
    /// Controls the whitespace emitted.
    /// The default `.minified` is a compact encoding with no whitespace between tokens.
    /// Any setting other than `.minified` will use newlines, indentation, and a space after each ':'.
    /// `.indent_1` means 1 space for each indentation level, `.indent_2` means 2 spaces, etc.
    /// `.indent_tab` uses a tab for each indentation level.
    whitespace: enum {
        minified,
        indent_1,
        indent_2,
        indent_3,
        indent_4,
        indent_8,
        indent_tab,
    } = .minified,

    /// Should optional fields with null value be written?
    emit_null_optional_fields: bool = true,

    /// Arrays/slices of u8 are typically encoded as JSON strings.
    /// This option emits them as arrays of numbers instead.
    /// Does not affect calls to `objectField*()`.
    emit_strings_as_arrays: bool = false,

    /// Should unicode characters be escaped in strings?
    escape_unicode: bool = false,

    /// When true, renders numbers outside the range `+-1<<53` (the precise integer range of f64) as JSON strings in base 10.
    emit_nonportable_numbers_as_strings: bool = false,
};
pub const Error = Writer.Error;

writer: *Writer,
options: Options = .{},
indent_level: usize = 0,
next_punctuation: enum {
    the_beginning,
    none,
    comma,
    colon,
} = .the_beginning,

nesting_stack: switch (safety_checks) {
    .checked_to_fixed_depth => |fixed_buffer_size| [(fixed_buffer_size + 7) >> 3]u8,
    .assumed_correct => void,
} = switch (safety_checks) {
    .checked_to_fixed_depth => @splat(0),
    .assumed_correct => {},
},

raw_streaming_mode: if (build_mode_has_safety)
    enum { none, value, objectField }
else
    void = if (build_mode_has_safety) .none else {},

const build_mode_has_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

const safety_checks_hint: union(enum) {
    checked_to_fixed_depth: usize,
    assumed_correct,
} = .{ .checked_to_fixed_depth = 256 };

const safety_checks: @TypeOf(safety_checks_hint) = if (build_mode_has_safety)
    safety_checks_hint
else
    .assumed_correct;

// ------------------------------------------------------------------
// punctuation / indentation
// ------------------------------------------------------------------

const IndentationMode = enum(u1) {
    object = 0,
    array = 1,
};

fn pushIndentation(self: *Stringify, mode: IndentationMode) void {
    switch (safety_checks) {
        .checked_to_fixed_depth => {
            BitStack.pushWithStateAssumeCapacity(&self.nesting_stack, &self.indent_level, @intFromEnum(mode));
        },
        .assumed_correct => {
            self.indent_level += 1;
        },
    }
}
fn popIndentation(self: *Stringify, expected_mode: IndentationMode) void {
    switch (safety_checks) {
        .checked_to_fixed_depth => {
            assert(BitStack.popWithState(&self.nesting_stack, &self.indent_level) == @intFromEnum(expected_mode));
        },
        .assumed_correct => {
            self.indent_level -= 1;
        },
    }
}

fn indent(self: *Stringify) Error!void {
    var char: u8 = ' ';
    const n_chars = switch (self.options.whitespace) {
        .minified => return,
        .indent_1 => 1 * self.indent_level,
        .indent_2 => 2 * self.indent_level,
        .indent_3 => 3 * self.indent_level,
        .indent_4 => 4 * self.indent_level,
        .indent_8 => 8 * self.indent_level,
        .indent_tab => blk: {
            char = '\t';
            break :blk self.indent_level;
        },
    };
    try self.writer.writeByte('\n');
    try self.writer.splatByteAll(char, n_chars);
}

// comptime-specialized: `min` eliminates the indent dispatch entirely.
fn valueStartAssumeTypeOkImpl(self: *Stringify, comptime min: bool) Error!void {
    assert(!self.isComplete()); // JSON document already complete.
    switch (self.next_punctuation) {
        .the_beginning => {},
        .none => {
            if (!min) try self.indent();
        },
        .comma => {
            try self.writer.writeByte(',');
            if (!min) try self.indent();
        },
        .colon => {
            if (min) {
                try self.writer.writeByte(':');
            } else {
                try self.writer.writeAll(": ");
            }
        },
    }
}

fn valueStartAssumeTypeOk(self: *Stringify) Error!void {
    if (self.options.whitespace == .minified)
        return self.valueStartAssumeTypeOkImpl(true);
    return self.valueStartAssumeTypeOkImpl(false);
}

fn valueStart(self: *Stringify) Error!void {
    if (self.isObjectKeyExpected()) |is_it| assert(!is_it); // Call objectField*(), not write(), for object keys.
    return self.valueStartAssumeTypeOk();
}
fn objectFieldStart(self: *Stringify) Error!void {
    if (self.isObjectKeyExpected()) |is_it| assert(is_it); // Expected write(), not objectField*().
    return self.valueStartAssumeTypeOk();
}
fn valueDone(self: *Stringify) void {
    self.next_punctuation = .comma;
}

fn isObjectKeyExpected(self: *const Stringify) ?bool {
    switch (safety_checks) {
        .checked_to_fixed_depth => return self.indent_level > 0 and
            BitStack.peekWithState(&self.nesting_stack, self.indent_level) == @intFromEnum(IndentationMode.object) and
            self.next_punctuation != .colon,
        .assumed_correct => return null,
    }
}
fn isComplete(self: *const Stringify) bool {
    return self.indent_level == 0 and self.next_punctuation == .comma;
}

// ------------------------------------------------------------------
// public streaming API — identical semantics to std
// ------------------------------------------------------------------

pub fn beginArray(self: *Stringify) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    try self.valueStart();
    try self.writer.writeByte('[');
    self.pushIndentation(.array);
    self.next_punctuation = .none;
}

pub fn beginObject(self: *Stringify) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    try self.valueStart();
    try self.writer.writeByte('{');
    self.pushIndentation(.object);
    self.next_punctuation = .none;
}

pub fn endArray(self: *Stringify) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    self.popIndentation(.array);
    switch (self.next_punctuation) {
        .none => {},
        .comma => {
            try self.indent();
        },
        .the_beginning, .colon => unreachable,
    }
    try self.writer.writeByte(']');
    self.valueDone();
}

pub fn endObject(self: *Stringify) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    self.popIndentation(.object);
    switch (self.next_punctuation) {
        .none => {},
        .comma => {
            try self.indent();
        },
        .the_beginning, .colon => unreachable,
    }
    try self.writer.writeByte('}');
    self.valueDone();
}

pub fn objectField(self: *Stringify, key: []const u8) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    try self.objectFieldStart();
    try encodeJsonString(key, self.options, self.writer);
    self.next_punctuation = .colon;
}

pub fn objectFieldRaw(self: *Stringify, quoted_key: []const u8) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    assert(quoted_key.len >= 2 and quoted_key[0] == '"' and quoted_key[quoted_key.len - 1] == '"');
    try self.objectFieldStart();
    try self.writer.writeAll(quoted_key);
    self.next_punctuation = .colon;
}

pub fn beginObjectFieldRaw(self: *Stringify) Error!void {
    if (build_mode_has_safety) {
        assert(self.raw_streaming_mode == .none);
        self.raw_streaming_mode = .objectField;
    }
    try self.objectFieldStart();
}

pub fn endObjectFieldRaw(self: *Stringify) void {
    if (build_mode_has_safety) {
        assert(self.raw_streaming_mode == .objectField);
        self.raw_streaming_mode = .none;
    }
    self.next_punctuation = .colon;
}

pub fn beginWriteRaw(self: *Stringify) Error!void {
    if (build_mode_has_safety) {
        assert(self.raw_streaming_mode == .none);
        self.raw_streaming_mode = .value;
    }
    try self.valueStart();
}

pub fn endWriteRaw(self: *Stringify) void {
    if (build_mode_has_safety) {
        assert(self.raw_streaming_mode == .value);
        self.raw_streaming_mode = .none;
    }
    self.valueDone();
}

pub fn print(self: *Stringify, comptime fmt: []const u8, args: anytype) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    try self.valueStart();
    try self.writer.print(fmt, args);
    self.valueDone();
}

// ------------------------------------------------------------------
// the value writer — comptime-minified specialization
// ------------------------------------------------------------------

/// Emits `"name":` (minified) or `"name": ` after the correct punctuation,
/// fusing comma + key + colon into a single writeAll when minified.
/// The field name is comptime-known, so its escaping is done at comptime.
fn objectFieldComptime(self: *Stringify, comptime min: bool, comptime name: []const u8) Error!void {
    // The escaped, quoted key — field names are comptime, so the escape
    // scan happens at comptime.
    const qkey = "\"" ++ comptime escapeComptime(name) ++ "\"";
    switch (self.next_punctuation) {
        .the_beginning => {
            try self.writer.writeAll(qkey ++ (if (min) ":" else ": "));
        },
        .none => {
            if (!min) try self.indent();
            try self.writer.writeAll(qkey ++ (if (min) ":" else ": "));
        },
        .comma => {
            if (min) {
                try self.writer.writeAll("," ++ qkey ++ ":");
            } else {
                try self.writer.writeByte(',');
                try self.indent();
                try self.writer.writeAll(qkey ++ ": ");
            }
        },
        // Grammar misuse (objectField where a value is expected); matches
        // what valueStartAssumeTypeOk emits at `.colon` before the key.
        .colon => {
            if (min) {
                try self.writer.writeAll(":" ++ qkey ++ ":");
            } else {
                try self.writer.writeAll(": " ++ qkey ++ ": ");
            }
        },
    }
    // Colon already emitted. `.colon` is also what std's objectField leaves
    // — it keeps isObjectKeyExpected() correct for the following value write
    // in checked builds (the value writes bare and consumes no punctuation).
    self.next_punctuation = .colon;
}

/// The JSON escape of a comptime string, computed at comptime.
/// Returns the escaped bytes without surrounding quotes.
fn escapeComptime(comptime s: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (s) |c| {
            out = out ++ switch (c) {
                '"' => "\\\"",
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0x08 => "\\b",
                0x0C => "\\f",
                else => if (c < 0x20)
                    std.fmt.comptimePrint("\\u{x:0>4}", .{c})
                else
                    &[1]u8{c},
            };
        }
        return out;
    }
}

pub fn write(self: *Stringify, v: anytype) Error!void {
    if (self.options.whitespace == .minified)
        return self.writeImpl(true, v);
    return self.writeImpl(false, v);
}

fn writeImpl(self: *Stringify, comptime min: bool, v: anytype) Error!void {
    return self.writeImplPunct(min, false, v);
}

/// `bare` means the caller already emitted any needed separator — the
/// punctuation switch becomes a no-op and is skipped (asserts retained).
fn writeImplPunct(self: *Stringify, comptime min: bool, comptime bare: bool, v: anytype) Error!void {
    if (build_mode_has_safety) {
        assert(self.raw_streaming_mode == .none);
        if (self.isObjectKeyExpected()) |is_it| assert(!is_it);
        if (bare) assert(!self.isComplete());
    }
    const T = @TypeOf(v);
    switch (@typeInfo(T)) {
        .int => {
            if (!bare) try self.valueStartAssumeTypeOkImpl(min);
            if (self.options.emit_nonportable_numbers_as_strings and
                (v <= -(1 << 53) or v >= (1 << 53)))
            {
                try self.writer.writeByte('"');
                try writeDecimal(self.writer, v);
                try self.writer.writeByte('"');
            } else {
                try writeDecimal(self.writer, v);
            }
            self.valueDone();
            return;
        },
        .comptime_int => {
            return self.writeImplPunct(min, bare, @as(std.math.IntFittingRange(v, v), v));
        },
        .float, .comptime_float => {
            if (@as(f64, @floatCast(v)) == v) {
                if (!bare) try self.valueStartAssumeTypeOkImpl(min);
                try self.writer.print("{}", .{@as(f64, @floatCast(v))});
                self.valueDone();
                return;
            }
            if (!bare) try self.valueStartAssumeTypeOkImpl(min);
            try self.writer.print("\"{}\"", .{v});
            self.valueDone();
            return;
        },

        .bool => {
            if (!bare) try self.valueStartAssumeTypeOkImpl(min);
            try self.writer.writeAll(if (v) "true" else "false");
            self.valueDone();
            return;
        },
        .null => {
            if (!bare) try self.valueStartAssumeTypeOkImpl(min);
            try self.writer.writeAll("null");
            self.valueDone();
            return;
        },
        .optional => {
            if (v) |payload| {
                return try self.writeImplPunct(min, bare, payload);
            } else {
                return try self.writeImplPunct(min, bare, null);
            }
        },
        .@"enum" => |enum_info| {
            if (std.meta.hasFn(T, "jsonStringify")) {
                return v.jsonStringify(self);
            }

            if (!enum_info.is_exhaustive) {
                inline for (enum_info.fields) |field| {
                    if (v == @field(T, field.name)) {
                        break;
                    }
                } else {
                    return self.writeImplPunct(min, bare, @intFromEnum(v));
                }
            }

            return self.stringValueImplPunct(min, bare, @tagName(v));
        },
        .enum_literal => {
            return self.stringValueImplPunct(min, bare, @tagName(v));
        },
        .@"union" => {
            if (std.meta.hasFn(T, "jsonStringify")) {
                return v.jsonStringify(self);
            }

            const info = @typeInfo(T).@"union";
            if (info.tag_type) |UnionTagType| {
                try self.beginObjectImplPunct(min, bare);
                inline for (info.fields) |u_field| {
                    if (v == @field(UnionTagType, u_field.name)) {
                        try self.objectFieldComptime(min, u_field.name);
                        if (u_field.type == void) {
                            // void v is {}
                            try self.beginObjectImplPunct(min, true);
                            try self.endObjectImpl(min);
                        } else {
                            try self.writeImplPunct(min, true, @field(v, u_field.name));
                        }
                        break;
                    }
                } else {
                    unreachable; // No active tag?
                }
                try self.endObjectImpl(min);
                return;
            } else {
                @compileError("Unable to stringify untagged union '" ++ @typeName(T) ++ "'");
            }
        },
        .@"struct" => |S| {
            if (std.meta.hasFn(T, "jsonStringify")) {
                return v.jsonStringify(self);
            }

            if (S.is_tuple) {
                try self.beginArrayImplPunct(min, bare);
            } else {
                try self.beginObjectImplPunct(min, bare);
            }
            // Static field-separator tracking: while no skippable (optional)
            // field has been seen, each field's separator is comptime-known —
            // the first emits `"k":`, the rest `,"k":`, each in ONE writeAll.
            // After an optional field, separators become runtime-dependent and
            // we fall back to the state-machine path. Applies only when
            // minified; pretty mode needs indent()+state anyway.
            const State = enum { none, comma, dynamic };
            comptime var static_state: State = .none;
            // Runtime flag: optional tuple elements can be skipped at runtime
            // when emit_null_optional_fields is false, so element position
            // is not always comptime-known.
            var tuple_emitted = false;
            inline for (S.fields) |Field| {
                // don't include void fields
                if (Field.type == void) continue;

                var emit_field = true;

                // don't include optional fields that are null when emit_null_optional_fields is set to false
                if (@typeInfo(Field.type) == .optional) {
                    if (self.options.emit_null_optional_fields == false) {
                        if (@field(v, Field.name) == null) {
                            emit_field = false;
                        }
                    }
                }

                if (emit_field) {
                    if (S.is_tuple) {
                        // Tuple elements have no names; separators come from
                        // the position, which is comptime-known for non-void
                        // fields under minified.
                        if (min) {
                            if (tuple_emitted) try self.writer.writeByte(',');
                            try self.writeImplPunct(min, true, @field(v, Field.name));
                        } else {
                            try self.writeImplPunct(min, false, @field(v, Field.name));
                        }
                    } else {
                        var value_pending = true;
                        const qkey = "\"" ++ comptime escapeComptime(Field.name) ++ "\"";
                        if (min and static_state != .dynamic) {
                            // String-valued field: fuse `,"k":"v"` — separator,
                            // key, colon and quotes are one comptime literal.
                            if (comptime emitsAsJsonString(Field.type)) {
                                const sval = asU8Slice(@field(v, Field.name));
                                if (!self.options.emit_strings_as_arrays and isJsonSafeAscii(sval)) {
                                    try self.writer.writeAll((if (static_state == .comma) "," ++ qkey ++ ":\"" else qkey ++ ":\""));
                                    try self.writer.writeAll(sval);
                                    try self.writer.writeByte('"');
                                    self.next_punctuation = .comma;
                                    value_pending = false;
                                }
                            }
                            if (value_pending) {
                                if (static_state == .comma) {
                                    try self.writer.writeAll("," ++ qkey ++ ":");
                                } else {
                                    try self.writer.writeAll(qkey ++ ":");
                                }
                                // The colon is already out — `.colon` keeps
                                // isObjectKeyExpected() correct; the value
                                // writes bare and consumes no punctuation.
                                self.next_punctuation = .colon;
                            }
                        } else {
                            try self.objectFieldComptime(min, Field.name);
                        }
                        if (value_pending) {
                            try self.writeImplPunct(min, true, @field(v, Field.name));
                        }
                    }
                }
                if (S.is_tuple and emit_field) tuple_emitted = true;
                // Comptime bookkeeping: a non-optional field always emits, so
                // the next field's separator stays statically known; after an
                // optional field it is runtime-dependent.
                if (@typeInfo(Field.type) == .optional) {
                    static_state = .dynamic;
                } else if (static_state == .none) {
                    static_state = .comma;
                }
            }
            if (S.is_tuple) {
                try self.endArrayImpl(min);
            } else {
                try self.endObjectImpl(min);
            }
            return;
        },
        .error_set => return self.stringValueImplPunct(min, bare, @errorName(v)),
        .pointer => |ptr_info| switch (ptr_info.size) {
            .one => switch (@typeInfo(ptr_info.child)) {
                .array => {
                    // Coerce `*[N]T` to `[]const T`.
                    const Slice = []const std.meta.Elem(ptr_info.child);
                    return self.writeImplPunct(min, bare, @as(Slice, v));
                },
                else => {
                    return self.writeImplPunct(min, bare, v.*);
                },
            },
            .many, .slice => {
                if (ptr_info.size == .many and ptr_info.sentinel() == null)
                    @compileError("unable to stringify type '" ++ @typeName(T) ++ "' without sentinel");
                const slice = if (ptr_info.size == .many) std.mem.span(v) else v;

                if (ptr_info.child == u8) {
                    // This is a []const u8, or some similar Zig string.
                    if (!self.options.emit_strings_as_arrays) {
                        if (isJsonSafeAscii(slice)) {
                            // All-ASCII, no escapable byte — emitted verbatim
                            // under both escape_unicode modes, and pure ASCII
                            // is always valid UTF-8, so the utf8ValidateSlice
                            // pass is provably unneeded.
                            if (!bare) try self.valueStartAssumeTypeOkImpl(min);
                            try writeQuoted(self.writer, slice);
                            self.valueDone();
                            return;
                        }
                        if (std.unicode.utf8ValidateSlice(slice)) {
                            return self.stringValueImplPunct(min, bare, slice);
                        }
                    }
                }

                try self.beginArrayImplPunct(min, bare);
                const ElemTy = std.meta.Elem(@TypeOf(slice));
                if (min and comptime emitsAsJsonString(ElemTy)) {
                    for (slice, 0..) |x, xi| {
                        const sv = asU8Slice(x);
                        if (!self.options.emit_strings_as_arrays and isJsonSafeAscii(sv)) {
                            try self.writer.writeAll(if (xi == 0) "\"" else ",\"");
                            try self.writer.writeAll(sv);
                            try self.writer.writeByte('"');
                            self.next_punctuation = .comma;
                        } else {
                            if (xi > 0) try self.writer.writeByte(',');
                            try self.writeImplPunct(min, true, x);
                        }
                    }
                } else {
                    for (slice, 0..) |x, xi| {
                        if (min) {
                            if (xi > 0) try self.writer.writeByte(',');
                            try self.writeImplPunct(min, true, x);
                        } else {
                            try self.writeImplPunct(min, false, x);
                        }
                    }
                }
                try self.endArrayImpl(min);
                return;
            },
            else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
        },
        .array => {
            // Coerce `[N]T` to `*const [N]T` (and then to `[]const T`).
            return self.writeImplPunct(min, bare, &v);
        },
        .vector => |info| {
            const array: [info.len]info.child = v;
            return self.writeImplPunct(min, bare, &array);
        },
        else => @compileError("Unable to stringify type '" ++ @typeName(T) ++ "'"),
    }
    unreachable;
}

// impl variants of begin/end that know `min` at comptime
fn beginArrayImplPunct(self: *Stringify, comptime min: bool, comptime bare: bool) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    if (bare) {
        try self.writer.writeByte('[');
    } else {
        try self.openPunctuated(min, '[');
    }
    self.pushIndentation(.array);
    self.next_punctuation = .none;
}

fn beginObjectImplPunct(self: *Stringify, comptime min: bool, comptime bare: bool) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    if (bare) {
        try self.writer.writeByte('{');
    } else {
        try self.openPunctuated(min, '{');
    }
    self.pushIndentation(.object);
    self.next_punctuation = .none;
}

/// `valueStartAssumeTypeOkImpl` plus the open bracket, fusing punctuation and
/// bracket into a single writeAll under minified.
fn openPunctuated(self: *Stringify, comptime min: bool, comptime ch: u8) Error!void {
    assert(!self.isComplete());
    switch (self.next_punctuation) {
        .the_beginning => try self.writer.writeByte(ch),
        .none => {
            if (!min) try self.indent();
            try self.writer.writeByte(ch);
        },
        .comma => {
            if (min) {
                try self.writer.writeAll(if (ch == '{') ",{" else ",[");
            } else {
                try self.writer.writeByte(',');
                try self.indent();
                try self.writer.writeByte(ch);
            }
        },
        .colon => {
            if (min) {
                try self.writer.writeAll(if (ch == '{') ":{" else ":[");
            } else {
                try self.writer.writeAll(if (ch == '{') ": {" else ": [");
            }
        },
    }
}

fn endArrayImpl(self: *Stringify, comptime min: bool) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    self.popIndentation(.array);
    switch (self.next_punctuation) {
        .none => {},
        .comma => {
            if (!min) try self.indent();
        },
        .the_beginning, .colon => unreachable,
    }
    try self.writer.writeByte(']');
    self.valueDone();
}

fn endObjectImpl(self: *Stringify, comptime min: bool) Error!void {
    if (build_mode_has_safety) assert(self.raw_streaming_mode == .none);
    self.popIndentation(.object);
    switch (self.next_punctuation) {
        .none => {},
        .comma => {
            if (!min) try self.indent();
        },
        .the_beginning, .colon => unreachable,
    }
    try self.writer.writeByte('}');
    self.valueDone();
}

fn stringValueImplPunct(self: *Stringify, comptime min: bool, comptime bare: bool, s: []const u8) Error!void {
    if (!bare) try self.valueStartAssumeTypeOkImpl(min);
    try encodeJsonString(s, self.options, self.writer);
    self.valueDone();
}

// ------------------------------------------------------------------
// entry points — same signatures as std.json.Stringify
// ------------------------------------------------------------------

pub fn value(v: anytype, options: Options, writer: *Writer) Error!void {
    var s: Stringify = .{ .writer = writer, .options = options };
    try s.write(v);
}

pub fn valueAlloc(gpa: Allocator, v: anytype, options: Options) error{OutOfMemory}![]u8 {
    var aw: std.io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    value(v, options, &aw.writer) catch return error.OutOfMemory;
    return aw.toOwnedSlice();
}

// ------------------------------------------------------------------
// string escaping — vectorized scan, byte-identical escapes
// ------------------------------------------------------------------

fn outputUnicodeEscape(codepoint: u21, w: *Writer) Error!void {
    if (codepoint <= 0xFFFF) {
        try w.writeAll("\\u");
        try w.printInt(codepoint, 16, .lower, .{ .width = 4, .fill = '0' });
    } else {
        assert(codepoint <= 0x10FFFF);
        const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
        const low = @as(u16, @intCast(codepoint & 0x3FF)) + 0xDC00;
        try w.writeAll("\\u");
        try w.printInt(high, 16, .lower, .{ .width = 4, .fill = '0' });
        try w.writeAll("\\u");
        try w.printInt(low, 16, .lower, .{ .width = 4, .fill = '0' });
    }
}

fn outputSpecialEscape(c: u8, writer: *Writer) Error!void {
    switch (c) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => try outputUnicodeEscape(c, writer),
    }
}

pub fn encodeJsonString(string: []const u8, options: Options, writer: *Writer) Error!void {
    try writer.writeByte('"');
    try encodeJsonStringChars(string, options, writer);
    try writer.writeByte('"');
}

/// `"` + s + `"` in a single bounds check + memcpy — same bytes out as
/// writeByte('"'), writeAll(s), writeByte('"').
fn writeQuoted(w: *Writer, s: []const u8) Error!void {
    if (w.buffer.len - w.end >= s.len + 2) {
        @branchHint(.likely);
        w.buffer[w.end] = '"';
        @memcpy(w.buffer[w.end + 1 ..][0..s.len], s);
        w.buffer[w.end + 1 + s.len] = '"';
        w.end += s.len + 2;
        return;
    }
    try w.writeByte('"');
    try w.writeAll(s);
    try w.writeByte('"');
}

/// Decimal digits written straight into the writer's buffer — one bounds
/// check, no stack-buffer round-trip. Same bytes as printInt(v,10,.lower,.{}).
/// Ints wider than 64 bits take the printInt path — identical output.
fn writeDecimal(w: *Writer, v: anytype) Error!void {
    const T = @TypeOf(v);
    const info = @typeInfo(T).int;
    if (comptime info.bits > 64) return w.printInt(v, 10, .lower, .{});

    const a0: u64 = @intCast(@abs(v));

    // Digit count by halving compares — each division constant is a
    // multiply-shift, no real divides.
    var a = a0;
    var n: usize = 1;
    if (a >= 10000000000000000) {
        n += 16;
        a /= 10000000000000000;
    }
    if (a >= 100000000) {
        n += 8;
        a /= 100000000;
    }
    if (a >= 10000) {
        n += 4;
        a /= 10000;
    }
    if (a >= 100) {
        n += 2;
        a /= 100;
    }
    if (a >= 10) n += 1;
    if (info.signedness == .signed and v < 0) n += 1;

    if (w.buffer.len - w.end >= n) {
        @branchHint(.likely);
        var i = w.end + n;
        a = a0;
        while (a >= 100) : (a /= 100) {
            i -= 2;
            w.buffer[i..][0..2].* = std.fmt.digits2(@intCast(a % 100));
        }
        if (a < 10) {
            i -= 1;
            w.buffer[i] = '0' + @as(u8, @intCast(a));
        } else {
            i -= 2;
            w.buffer[i..][0..2].* = std.fmt.digits2(@intCast(a));
        }
        if (info.signedness == .signed and v < 0) {
            i -= 1;
            w.buffer[i] = '-';
        }
        w.end += n;
        return;
    }
    return w.printInt(v, 10, .lower, .{});
}

const needs_escape_table: [256]bool = blk: {
    var t = [_]bool{false} ** 256;
    for (0..0x20) |c| t[c] = true;
    t['"'] = true;
    t['\\'] = true;
    break :blk t;
};

/// True iff every byte needs no JSON escaping under either `escape_unicode`
/// mode AND is ASCII (hence trivially valid UTF-8): c in 0x20...0x7F minus
/// '"' and '\\'. One vectorized pass; replaces both the utf8ValidateSlice
/// pass and the escape scan for the common all-ASCII case.
fn isJsonSafeAscii(s: []const u8) bool {
    var i: usize = 0;
    while (i + 32 <= s.len) : (i += 32) {
        if (jsonUnsafeInBlock(32, s[i..][0..32].*)) return false;
    }
    // 8-byte chunks plus one overlapping tail chunk — no scalar loop for
    // strings of length >= 8.
    while (i + 8 <= s.len) : (i += 8) {
        if (jsonUnsafeInBlock(8, s[i..][0..8].*)) return false;
    }
    if (i < s.len) {
        if (s.len >= 8) {
            if (jsonUnsafeInBlock(8, s[s.len - 8 ..][0..8].*)) return false;
        } else {
            while (i < s.len) : (i += 1) {
                const c = s[i];
                if (c < 0x20 or c > 0x7E or c == '"' or c == '\\') return false;
            }
        }
    }
    return true;
}

fn jsonUnsafeInBlock(comptime B: usize, v: @Vector(B, u8)) bool {
    // 0x7E is the ceiling: 0x7F is emitted verbatim in minified mode but is
    // escaped (\u007f) under escape_unicode, so it must take the slow path.
    const bad = (v < @as(@Vector(B, u8), @splat(0x20))) |
        (v > @as(@Vector(B, u8), @splat(0x7E))) |
        (v == @as(@Vector(B, u8), @splat('"'))) |
        (v == @as(@Vector(B, u8), @splat('\\')));
    return @reduce(.Or, bad);
}

/// Comptime: does this type take the `[]const u8` → JSON string branch in
/// `writeImpl`? Restricted to the cases the fused fast path can deconstruct.
fn emitsAsJsonString(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .many => p.child == u8 and p.sentinel() != null,
            .one => @typeInfo(p.child) == .array and
                std.meta.Elem(p.child) == u8,
            else => false,
        },
        .array => |a| a.child == u8,
        else => false,
    };
}

/// Comptime: does this element type always open with `{` or `[` when
/// written? Used to pick the punctuated (fused `,{`) path over bare writes.
/// Optionals are excluded — they may emit `null` or the payload.
fn emitsContainer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => blk: {
            if (std.meta.hasFn(T, "jsonStringify")) break :blk false;
            break :blk true; // both tuple ([) and struct ({)
        },
        .@"union" => |u| u.tag_type != null and !std.meta.hasFn(T, "jsonStringify"),
        .array, .vector => true,
        .pointer => |p| switch (p.size) {
            .slice => p.child != u8, // u8 slices take the string-elem path
            .many => p.sentinel() != null and p.child != u8,
            .one => @typeInfo(p.child) == .array,
            else => false,
        },
        else => false,
    };
}

/// The `[]const u8` view of a value whose type satisfies emitsAsJsonString.
fn asU8Slice(v: anytype) []const u8 {
    const T = @TypeOf(v);
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => v,
            .many => std.mem.span(v),
            .one => @as([]const u8, v),
            else => unreachable,
        },
        .array => @as([]const u8, &v),
        else => unreachable,
    };
}

/// Write `chars` to `writer` as JSON encoded string characters.
/// Same bytes out as std.json.Stringify.encodeJsonStringChars.
pub fn encodeJsonStringChars(chars: []const u8, options: Options, writer: *Writer) Error!void {
    var write_cursor: usize = 0;
    var i: usize = 0;
    if (options.escape_unicode) {
        while (i < chars.len) : (i += 1) {
            switch (chars[i]) {
                // normal ascii character
                0x20...0x21, 0x23...0x5B, 0x5D...0x7E => {},
                0x00...0x1F, '\\', '"' => {
                    // Always must escape these.
                    try writer.writeAll(chars[write_cursor..i]);
                    try outputSpecialEscape(chars[i], writer);
                    write_cursor = i + 1;
                },
                0x7F...0xFF => {
                    try writer.writeAll(chars[write_cursor..i]);
                    const ulen = std.unicode.utf8ByteSequenceLength(chars[i]) catch unreachable;
                    const codepoint = std.unicode.utf8Decode(chars[i..][0..ulen]) catch unreachable;
                    try outputUnicodeEscape(codepoint, writer);
                    i += ulen - 1;
                    write_cursor = i + 1;
                },
            }
        }
    } else {
        // SIMD block scan: skip 32-byte blocks containing no escapable byte.
        const B = 32;
        outer: while (i + B <= chars.len) {
            const v: @Vector(B, u8) = chars[i..][0..B].*;
            const lo: @Vector(B, u8) = @splat(0x20);
            const esc = (v < lo) |
                (v == @as(@Vector(B, u8), @splat('"'))) |
                (v == @as(@Vector(B, u8), @splat('\\')));
            const mask: u32 = @bitCast(esc);
            if (mask == 0) {
                i += B;
                continue :outer;
            }
            const j = i + @ctz(mask);
            try writer.writeAll(chars[write_cursor..j]);
            try outputSpecialEscape(chars[j], writer);
            i = j + 1;
            write_cursor = i;
        }
        // scalar tail (<16 bytes remaining)
        while (i < chars.len) : (i += 1) {
            if (needs_escape_table[chars[i]]) {
                try writer.writeAll(chars[write_cursor..i]);
                try outputSpecialEscape(chars[i], writer);
                write_cursor = i + 1;
            }
        }
    }
    try writer.writeAll(chars[write_cursor..chars.len]);
}
