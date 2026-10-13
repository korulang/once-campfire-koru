const std = @import("std");
const ast = @import("ast");
const log = @import("log");
const annotation_parser = @import("annotation_parser");

/// Registry for keyword annotations that allow unqualified event invocation.
///
/// Events marked with [keyword] can be invoked without module qualification:
///   ~[keyword]pub event if { condition: bool } | then {} | else {}
///
///   ~if(condition)  // Instead of ~std.control:if(condition)
///
/// Collision tracking: If two imported modules define the same keyword,
/// the registry stores both - error is emitted only at usage time.
pub const KeywordRegistry = struct {
    allocator: std.mem.Allocator,

    /// Maps keyword name -> list of definitions (for collision detection)
    /// Example: "if" -> [KeywordInfo{canonical_path: "std.control:if", module: "std.control"}]
    keywords: std.StringHashMap(KeywordList),

    pub const KeywordInfo = struct {
        canonical_path: []const u8,  // Full path: "std.control:if"
        module_path: []const u8,     // Module that defines it: "std.control"
    };

    pub const KeywordList = struct {
        items: std.ArrayList(KeywordInfo),

        pub fn deinit(self: *KeywordList, allocator: std.mem.Allocator) void {
            // Free the stored strings
            for (self.items.items) |info| {
                allocator.free(info.canonical_path);
                allocator.free(info.module_path);
            }
            self.items.deinit(allocator);
        }

        pub fn hasCollision(self: *const KeywordList) bool {
            return self.items.items.len > 1;
        }
    };

    pub fn init(allocator: std.mem.Allocator) KeywordRegistry {
        return .{
            .allocator = allocator,
            .keywords = std.StringHashMap(KeywordList).init(allocator),
        };
    }

    pub fn deinit(self: *KeywordRegistry) void {
        var it = self.keywords.iterator();
        while (it.next()) |entry| {
            // Free the key (keyword name)
            self.allocator.free(entry.key_ptr.*);
            // Free the value (KeywordList and its contents)
            entry.value_ptr.deinit(self.allocator);
        }
        self.keywords.deinit();
    }

    /// Register a keyword from an event with [keyword] annotation.
    /// May have multiple entries for the same keyword (collision detection).
    pub fn registerKeyword(
        self: *KeywordRegistry,
        keyword_name: []const u8,
        canonical_path: []const u8,
        module_path: []const u8,
    ) !void {
        // Duplicate the strings for storage
        const canonical_copy = try self.allocator.dupe(u8, canonical_path);
        errdefer self.allocator.free(canonical_copy);

        const module_copy = try self.allocator.dupe(u8, module_path);
        errdefer self.allocator.free(module_copy);

        const gop = try self.keywords.getOrPut(keyword_name);
        if (!gop.found_existing) {
            // New keyword - need to dupe the key
            const key_copy = try self.allocator.dupe(u8, keyword_name);
            gop.key_ptr.* = key_copy;
            gop.value_ptr.* = KeywordList{ .items = .{} };
        }

        try gop.value_ptr.items.append(self.allocator, .{
            .canonical_path = canonical_copy,
            .module_path = module_copy,
        });
    }

    /// Resolve a keyword to its canonical path.
    /// Returns the canonical path if exactly one definition exists.
    /// Returns error.KeywordCollision if multiple modules define it.
    /// Returns null if not found.
    pub fn resolveKeyword(self: *const KeywordRegistry, keyword_name: []const u8) error{KeywordCollision}!?[]const u8 {
        if (self.keywords.get(keyword_name)) |list| {
            if (list.items.items.len == 1) {
                return list.items.items[0].canonical_path;
            } else if (list.items.items.len > 1) {
                return error.KeywordCollision;
            }
        }
        return null;
    }

    /// Get all definitions for a keyword (for collision error messages).
    pub fn getCollisionInfo(self: *const KeywordRegistry, keyword_name: []const u8) ?[]const KeywordInfo {
        if (self.keywords.get(keyword_name)) |list| {
            return list.items.items;
        }
        return null;
    }

    /// Check if a keyword exists (regardless of collisions).
    pub fn hasKeyword(self: *const KeywordRegistry, keyword_name: []const u8) bool {
        return self.keywords.contains(keyword_name);
    }

    /// Get count of registered keywords (for debugging/testing).
    pub fn count(self: *const KeywordRegistry) usize {
        return self.keywords.count();
    }
};

/// Build the registry by scanning all events with `[keyword]`. Must run AFTER
/// canonicalization so declaration paths have module qualifiers.
pub fn buildFromItems(
    items: []const ast.Item,
    registry: *KeywordRegistry,
    allocator: std.mem.Allocator,
) !void {
    for (items) |item| {
        switch (item) {
            .event_decl => |event| {
                if (event.is_public and annotation_parser.isKeyword(event.annotations)) {
                    const keyword_name = event.path.segments[event.path.segments.len - 1];

                    var canonical_parts: std.ArrayList(u8) = .{};
                    defer canonical_parts.deinit(allocator);

                    if (event.path.module_qualifier) |qualifier| {
                        try canonical_parts.appendSlice(allocator, qualifier);
                        try canonical_parts.append(allocator, ':');
                    }
                    for (event.path.segments, 0..) |seg, i| {
                        if (i > 0) try canonical_parts.append(allocator, '.');
                        try canonical_parts.appendSlice(allocator, seg);
                    }

                    const canonical_path = try allocator.dupe(u8, canonical_parts.items);
                    const module_path = event.path.module_qualifier orelse "main";

                    try registry.registerKeyword(keyword_name, canonical_path, module_path);
                    log.debug("  Registered keyword '{s}' -> '{s}'\n", .{ keyword_name, canonical_path });

                    // Multi-segment keyword names (`assert.eq`, `assert.ok`):
                    // the dotted path is itself a keyword — `assert.eq(...)`
                    // resolves by its full name, not by a last-segment alias.
                    if (event.path.segments.len > 1) {
                        var dotted: std.ArrayList(u8) = .{};
                        defer dotted.deinit(allocator);
                        for (event.path.segments, 0..) |seg, i| {
                            if (i > 0) try dotted.append(allocator, '.');
                            try dotted.appendSlice(allocator, seg);
                        }
                        try registry.registerKeyword(dotted.items, canonical_path, module_path);
                    }
                }
            },
            .module_decl => |module| {
                try buildFromItems(module.items, registry, allocator);
            },
            else => {},
        }
    }
}

/// Resolve keywords in `items`, using those same items as home and as the
/// whole-program lookup. The compiler's outer pass is this shape.
pub fn resolveInAST(
    items: []ast.Item,
    registry: *const KeywordRegistry,
    allocator: std.mem.Allocator,
    home_module: []const u8,
) !void {
    try resolveInASTWithLookup(items, registry, allocator, home_module, items, items);
}

/// Resolve keywords in `items` while looking up declarations in `all_items`.
/// The `test` transform re-parses a body that has no imported `module_decl`s;
/// its registry and `findEventDecl` walk must use the parent program.
pub fn resolveInASTWithLookup(
    items: []ast.Item,
    registry: *const KeywordRegistry,
    allocator: std.mem.Allocator,
    home_module: []const u8,
    home_items: []const ast.Item,
    all_items: []const ast.Item,
) !void {
    for (items) |*item| {
        try resolveInItem(item, registry, allocator, home_module, home_items, all_items);
    }
}

fn resolveInItem(
    item: *ast.Item,
    registry: *const KeywordRegistry,
    allocator: std.mem.Allocator,
    home_module: []const u8,
    home_items: []const ast.Item,
    all_items: []const ast.Item,
) !void {
    switch (item.*) {
        .flow => |*flow| {
            try resolveInPath(&flow.invMut().path, registry, allocator, home_module, home_items);
            try bindImplicitExpressionArg(flow.invMut(), allocator, all_items);
            for (flow.body.continuations) |*cont| {
                try resolveInContinuation(@constCast(cont), registry, allocator, home_module, home_items, all_items);
            }
        },
        .module_decl => |*module| {
            for (module.items) |*mod_item| {
                try resolveInItem(@constCast(mod_item), registry, allocator, module.logical_name, module.items, all_items);
            }
        },
        else => {},
    }
}

fn bindImplicitExpressionArg(
    invocation: *ast.Invocation,
    allocator: std.mem.Allocator,
    all_items: []const ast.Item,
) !void {
    if (invocation.path.segments.len == 0) return;
    const module_qualifier = invocation.path.module_qualifier orelse return;

    // The event name is the WHOLE dotted path — `assert.eq` binds against
    // the assert.eq decl, not the single-segment `assert` that happens to
    // share its first segment.
    var name_buf: [256]u8 = undefined;
    var name_len: usize = 0;
    for (invocation.path.segments, 0..) |seg, i| {
        if (i > 0) {
            name_buf[name_len] = '.';
            name_len += 1;
        }
        if (name_len + seg.len > name_buf.len) return;
        @memcpy(name_buf[name_len..][0..seg.len], seg);
        name_len += seg.len;
    }
    const event_name = name_buf[0..name_len];

    const event_decl = findEventDecl(all_items, module_qualifier, event_name) orelse return;

    var has_implicit_expr = false;
    for (event_decl.input.fields) |field| {
        if (std.mem.eql(u8, field.name, "expr") and field.is_expression) {
            has_implicit_expr = true;
            break;
        }
    }

    if (has_implicit_expr) {
        const mutable_args = @constCast(invocation.args);
        for (mutable_args) |*arg| {
            if (arg.had_explicit_label) continue;

            var is_source_slot = false;
            for (event_decl.input.fields) |field| {
                if (field.is_source and std.mem.eql(u8, field.name, arg.name)) {
                    is_source_slot = true;
                    break;
                }
            }
            if (is_source_slot) continue;

            const expr_text = if (arg.value.len > 0) arg.value else arg.name;

            if (arg.expression_value == null) {
                const expression_value = try allocator.create(ast.CapturedExpression);
                expression_value.* = ast.CapturedExpression{
                    .text = try allocator.dupe(u8, expr_text),
                    .location = .{ .line = 0, .column = 0, .file = "" },
                    .scope = .{ .bindings = &.{} },
                };
                arg.expression_value = expression_value;
            }

            arg.value = try allocator.dupe(u8, expr_text);
            arg.name = try allocator.dupe(u8, "expr");
            break;
        }
    }

    const mutable_args2 = @constCast(invocation.args);
    for (mutable_args2) |*arg| {
        if (arg.expression_value != null) continue;

        for (event_decl.input.fields) |field| {
            if (std.mem.eql(u8, field.name, arg.name) and field.is_expression) {
                const expression_value = try allocator.create(ast.CapturedExpression);
                expression_value.* = ast.CapturedExpression{
                    .text = try allocator.dupe(u8, arg.value),
                    .location = .{ .line = 0, .column = 0, .file = "" },
                    .scope = .{ .bindings = &.{} },
                };
                arg.expression_value = expression_value;
                break;
            }
        }
    }
}

fn findEventDecl(
    items: []const ast.Item,
    target_module: []const u8,
    target_event: []const u8,
) ?*const ast.EventDecl {
    for (items) |item| {
        switch (item) {
            .module_decl => |module| {
                if (std.mem.eql(u8, module.logical_name, target_module)) {
                    for (0..module.items.len) |idx| {
                        if (module.items[idx] == .event_decl) {
                            const event_decl = &module.items[idx].event_decl;
                            var decl_buf: [256]u8 = undefined;
                            var decl_len: usize = 0;
                            for (event_decl.path.segments, 0..) |seg, si| {
                                if (si > 0) {
                                    if (decl_len >= decl_buf.len) break;
                                    decl_buf[decl_len] = '.';
                                    decl_len += 1;
                                }
                                if (decl_len + seg.len > decl_buf.len) break;
                                @memcpy(decl_buf[decl_len..][0..seg.len], seg);
                                decl_len += seg.len;
                            }
                            if (std.mem.eql(u8, decl_buf[0..decl_len], target_event)) {
                                return event_decl;
                            }
                        }
                    }
                }
                if (findEventDecl(module.items, target_module, target_event)) |found| {
                    return found;
                }
            },
            else => {},
        }
    }
    return null;
}

fn resolveInStep(
    step: *ast.Step,
    registry: *const KeywordRegistry,
    allocator: std.mem.Allocator,
    home_module: []const u8,
    home_items: []const ast.Item,
    all_items: []const ast.Item,
) !void {
    switch (step.*) {
        .invocation => |*inv| {
            try resolveInPath(&inv.path, registry, allocator, home_module, home_items);
            try bindImplicitExpressionArg(@constCast(inv), allocator, all_items);
        },
        .label_with_invocation => |*lwi| {
            try resolveInPath(&lwi.invocation.path, registry, allocator, home_module, home_items);
            try bindImplicitExpressionArg(@constCast(&lwi.invocation), allocator, all_items);
        },
        else => {},
    }
}

fn resolveInContinuation(
    cont: *ast.Continuation,
    registry: *const KeywordRegistry,
    allocator: std.mem.Allocator,
    home_module: []const u8,
    home_items: []const ast.Item,
    all_items: []const ast.Item,
) !void {
    if (cont.node) |*step| {
        try resolveInStep(@constCast(step), registry, allocator, home_module, home_items, all_items);
    }
    for (cont.continuations) |*nested| {
        try resolveInContinuation(@constCast(nested), registry, allocator, home_module, home_items, all_items);
    }
}

fn localEventShadowsKeyword(home_items: []const ast.Item, name: []const u8) bool {
    for (home_items) |item| {
        if (item != .event_decl) continue;
        const decl = item.event_decl;
        if (decl.path.segments.len == 1 and std.mem.eql(u8, decl.path.segments[0], name)) {
            return true;
        }
    }
    return false;
}

fn resolveInPath(
    path: *ast.DottedPath,
    registry: *const KeywordRegistry,
    allocator: std.mem.Allocator,
    home_module: []const u8,
    home_items: []const ast.Item,
) !void {
    // Multi-segment invocation (`assert.eq(...)`): the dotted path is the
    // keyword name — resolve it whole so qualified-only transform dispatch
    // sees the home module. Single-segment handling is below.
    if (path.segments.len == 0) return;
    if (path.segments.len != 1) {
        if (path.module_qualifier) |qualifier| {
            if (!std.mem.eql(u8, qualifier, home_module)) return;
        }
        if (localEventShadowsKeyword(home_items, path.segments[0])) return;
        var dotted: std.ArrayList(u8) = .{};
        defer dotted.deinit(allocator);
        for (path.segments, 0..) |seg, i| {
            if (i > 0) try dotted.append(allocator, '.');
            try dotted.appendSlice(allocator, seg);
        }
        const resolve_result = registry.resolveKeyword(dotted.items) catch |err| switch (err) {
            error.KeywordCollision => {
                const collision_info = registry.getCollisionInfo(dotted.items).?;
                log.err("ERROR: Ambiguous keyword '{s}' - defined in:\n", .{dotted.items});
                for (collision_info) |info| {
                    log.err("  - {s} (from {s})\n", .{ info.canonical_path, info.module_path });
                }
                return error.AmbiguousKeyword;
            },
        };
        if (resolve_result) |canonical| {
            if (std.mem.indexOf(u8, canonical, ":")) |colon_pos| {
                path.module_qualifier = try allocator.dupe(u8, canonical[0..colon_pos]);
                log.debug("  Resolved keyword '{s}' -> module '{s}'\n", .{ dotted.items, path.module_qualifier.? });
            }
        }
        return;
    }

    if (path.module_qualifier) |qualifier| {
        if (!std.mem.eql(u8, qualifier, home_module)) {
            return;
        }
    }

    const potential_keyword = path.segments[0];
    if (localEventShadowsKeyword(home_items, potential_keyword)) return;

    const resolve_result = registry.resolveKeyword(potential_keyword) catch |err| switch (err) {
        error.KeywordCollision => {
            const collision_info = registry.getCollisionInfo(potential_keyword).?;
            log.err("ERROR: Ambiguous keyword '{s}' - defined in:\n", .{potential_keyword});
            for (collision_info) |info| {
                log.err("  - {s} (from {s})\n", .{ info.canonical_path, info.module_path });
            }
            return error.AmbiguousKeyword;
        },
    };

    if (resolve_result) |canonical| {
        if (std.mem.indexOf(u8, canonical, ":")) |colon_pos| {
            path.module_qualifier = try allocator.dupe(u8, canonical[0..colon_pos]);
            log.debug("  Resolved keyword '{s}' -> module '{s}'\n", .{ potential_keyword, path.module_qualifier.? });
        }
    }
}

// Unit tests
test "register and resolve single keyword" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("if", "std.control:if", "std.control");

    const resolved = try registry.resolveKeyword("if");
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("std.control:if", resolved.?);
}

test "resolve unknown keyword returns null" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    const resolved = try registry.resolveKeyword("unknown");
    try std.testing.expect(resolved == null);
}

test "collision detection returns error" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("process", "lib_a:process", "lib_a");
    try registry.registerKeyword("process", "lib_b:process", "lib_b");

    const result = registry.resolveKeyword("process");
    try std.testing.expectError(error.KeywordCollision, result);
}

test "get collision info" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("foo", "mod_a:foo", "mod_a");
    try registry.registerKeyword("foo", "mod_b:foo", "mod_b");

    const info = registry.getCollisionInfo("foo");
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(usize, 2), info.?.len);
    try std.testing.expectEqualStrings("mod_a:foo", info.?[0].canonical_path);
    try std.testing.expectEqualStrings("mod_b:foo", info.?[1].canonical_path);
}

test "multiple different keywords" {
    const allocator = std.testing.allocator;
    var registry = KeywordRegistry.init(allocator);
    defer registry.deinit();

    try registry.registerKeyword("if", "control:if", "control");
    try registry.registerKeyword("while", "control:while", "control");
    try registry.registerKeyword("print", "io:print", "io");

    try std.testing.expectEqual(@as(usize, 3), registry.count());

    const if_resolved = try registry.resolveKeyword("if");
    try std.testing.expectEqualStrings("control:if", if_resolved.?);

    const print_resolved = try registry.resolveKeyword("print");
    try std.testing.expectEqualStrings("io:print", print_resolved.?);
}
