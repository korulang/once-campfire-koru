// Compiler environment — per-invocation data (flags, lang, paths) loaded at
// backend startup from `compiler_env.json`, beside `program.ast.json`.
//
// Previously this module was GENERATED per invocation with comptime-baked
// consts; unbaked so the backend binary is reusable across flag combinations —
// a flag flip no longer forces a backend rebuild. Same API names as before
// (`CompilerEnv.lang`, `.hasFlag(…)`, …): the only semantic change is that
// `hasFlag`/`getEnv` take runtime params (their comptime contracts had no
// type-level customers) and the fields are write-once startup state.
const std = @import("std");

pub const CompilerEnv = struct {
    pub var lang: []const u8 = "zig";
    pub var library: bool = false;
    pub var flags: []const []const u8 = &.{};
    pub var entry_file: []const u8 = "";
    pub var entry_dir: []const u8 = "";
    pub var project_root: []const u8 = "";
    pub var koru_home: []const u8 = "";
    pub var env_vars: []const EnvVar = &.{};

    pub const EnvVar = struct {
        key: []const u8,
        value: []const u8,
    };

    /// Check if a compiler flag is set. Runtime query over the loaded flags.
    pub fn hasFlag(name: []const u8) bool {
        for (flags) |flag| {
            if (std.mem.eql(u8, name, flag)) return true;
        }
        return false;
    }

    /// Historical alias — identical to hasFlag since the unbake.
    pub fn hasFlagRuntime(name: []const u8) bool {
        return hasFlag(name);
    }

    /// Get environment variable value (was comptime-keyed when baked).
    pub fn getEnv(key: []const u8) ?[]const u8 {
        for (env_vars) |kv| {
            if (std.mem.eql(u8, key, kv.key)) return kv.value;
        }
        return null;
    }

    /// Load from `compiler_env.json` in CWD. Fail-loud; call once at backend
    /// startup before any pass reads the env (same discipline as program.ast.json).
    pub fn load() !void {
        const file = std.fs.cwd().openFile("compiler_env.json", .{}) catch |err| {
            std.debug.print("❌ Backend: cannot open compiler_env.json: {s}\n", .{@errorName(err)});
            return err;
        };
        defer file.close();
        const bytes = try file.readToEndAlloc(std.heap.page_allocator, 16 * 1024 * 1024);
        try loadFromSlice(bytes);
    }

    pub fn loadFromSlice(json_text: []const u8) !void {
        // Backend-lifetime data; intentionally never freed (same precedent as
        // other startup-loaded compiler state).
        const alloc = std.heap.page_allocator;
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidEnvJson;
        const root = parsed.value.object;

        if (root.get("lang")) |v| {
            if (v == .string) {
                lang = try alloc.dupe(u8, v.string);
            }
        }
        if (root.get("library")) |v| {
            if (v == .bool) {
                library = v.bool;
            }
        }
        if (root.get("flags")) |v| {
            if (v == .array) {
                const arr = try alloc.alloc([]const u8, v.array.items.len);
                for (v.array.items, 0..) |item, i| {
                    arr[i] = if (item == .string) try alloc.dupe(u8, item.string) else "";
                }
                flags = arr;
            }
        }
        const path_slots = [_]struct { json_key: []const u8, target: *[]const u8 }{
            .{ .json_key = "entry_file", .target = &entry_file },
            .{ .json_key = "entry_dir", .target = &entry_dir },
            .{ .json_key = "project_root", .target = &project_root },
            .{ .json_key = "koru_home", .target = &koru_home },
        };
        for (path_slots) |slot| {
            if (root.get(slot.json_key)) |v| {
                if (v == .string) {
                    slot.target.* = try alloc.dupe(u8, v.string);
                }
            }
        }
        if (root.get("env")) |v| {
            if (v == .object) {
            var list = try std.ArrayList(EnvVar).initCapacity(alloc, v.object.count());
            var it = v.object.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* != .string) continue;
                try list.append(alloc, .{
                    .key = try alloc.dupe(u8, entry.key_ptr.*),
                    .value = try alloc.dupe(u8, entry.value_ptr.string),
                });
            }
            env_vars = try list.toOwnedSlice(alloc);
            }
        }
    }
};
