//! site_hash — fuzzy hierarchical addresses for program sites.
//!
//! A site hash is a transient, prefix-navigable coordinate over the semantic
//! path to a node: module → item → site → detail. Each level contributes one
//! 3-char segment of a chained digest, so the hash is its own trie key:
//! chomping the tail zooms OUT (right neighborhood, coarser cell), never off
//! the map. A drifted tail still resolves — `resolve` descends to the longest
//! prefix that still lands on something.
//!
//! Nothing is registered and nothing is maintained: the hash is a pure
//! function of the tree, minted fresh at report time. Drift across edits is
//! absorbed by ordinal-in-context keys (inserting an unrelated flow does not
//! shift a sibling's address) and by fuzzy resolution at read time.

const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

// 32-char alphabet without i/l/o/u — five bits per char.
const ALPHABET = "0123456789abcdefghjkmnpqrstvwxyz";
const SEG_CHARS = 3; // 15 bits per level
const MAX_DEPTH = 8; // module, item, then up to six nesting levels → 24 chars

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x100000001b3;

fn fnvContinue(h: u64, bytes: []const u8) u64 {
    var x = h;
    for (bytes) |b| x = (x ^ b) *% FNV_PRIME;
    return x;
}

/// Chained path digest: each key folds into the running hash and emits its own
/// 3-char segment. seg_k depends on all keys ≤ k — no cross-parent collisions —
/// while the string remains a strict prefix trie of the path.
pub fn hashPath(alloc: std.mem.Allocator, keys: []const []const u8) ![]u8 {
    const out = try alloc.alloc(u8, keys.len * SEG_CHARS);
    var h: u64 = FNV_OFFSET;
    for (keys, 0..) |key, i| {
        h = fnvContinue(h, key);
        var v = h & 0x7fff;
        out[i * SEG_CHARS + 0] = ALPHABET[v & 31];
        v >>= 5;
        out[i * SEG_CHARS + 1] = ALPHABET[v & 31];
        v >>= 5;
        out[i * SEG_CHARS + 2] = ALPHABET[v];
    }
    return out;
}

/// One addressable node in the program. `ptr` is `@intFromPtr` of the node the
/// hash addresses — the `Invocation` for flow-heads and nested sites, the
/// `EventDecl`/`ProcDecl` for decls — so a transform holding the AST pointer
/// finds its own hash without re-walking.
pub const Site = struct {
    hash: []const u8, // canonical, 3 chars per level of depth
    ptr: usize,
    kind: Kind,
    spelling: []const u8, // door spelling, e.g. "std/store:insert"
    module: []const u8,
    location: errors.SourceLocation,

    pub const Kind = enum { decl, flow, site };
};

fn spellPath(alloc: std.mem.Allocator, path: ast.DottedPath) ![]const u8 {
    var buf = try std.ArrayList(u8).initCapacity(alloc, 48);
    if (path.module_qualifier) |mq| {
        try buf.appendSlice(alloc, mq);
        try buf.append(alloc, ':');
    }
    for (path.segments, 0..) |seg, i| {
        if (i > 0) try buf.append(alloc, '.');
        try buf.appendSlice(alloc, seg);
    }
    return buf.items;
}

const SiteList = std.ArrayList(Site);
const OrdMap = std.StringHashMap(usize);

fn bump(map: *OrdMap, key: []const u8) !usize {
    const g = try map.getOrPut(key);
    if (!g.found_existing) g.value_ptr.* = 0;
    defer g.value_ptr.* += 1;
    return g.value_ptr.*;
}

/// Enumerate every addressable node in a (pre-transform or post-import)
/// program: decls, flow-heads, and invocation sites nested in continuations.
/// One enumerator serves `glance`, `at`, and every `[explainer]` — same tree,
/// same pointers, same hashes.
pub fn collectSites(alloc: std.mem.Allocator, prog: *const ast.Program) ![]Site {
    var list = SiteList{};
    try walkItems(alloc, &list, prog.items, null);
    return list.items;
}

/// A decl site: `decl:<path>` under the decl's own module or the enclosing
/// one. `decl` is an `EventDecl` or `ProcDecl` — same three fields drive
/// both.
fn appendDeclItem(
    alloc: std.mem.Allocator,
    list: *SiteList,
    module_name: ?[]const u8,
    decl: anytype,
) !void {
    const module = if (decl.module.len > 0) decl.module else module_name orelse "";
    const spelling = try spellPath(alloc, decl.path);
    const item_key = try std.fmt.allocPrint(alloc, "decl:{s}", .{spelling});
    try list.append(alloc, .{
        .hash = try hashPath(alloc, &.{ module, item_key }),
        .ptr = @intFromPtr(decl),
        .kind = .decl,
        .spelling = spelling,
        .module = module,
        .location = decl.location,
    });
}

fn walkItems(
    alloc: std.mem.Allocator,
    list: *SiteList,
    items: []const ast.Item,
    module_name: ?[]const u8,
) !void {
    // Per-module ordinal scopes: inserting an unrelated flow does not shift a
    // sibling's address — only a same-head sibling ahead of it does.
    var flow_ords = OrdMap.init(alloc);
    defer flow_ords.deinit();
    for (items) |*item| {
        switch (item.*) {
            .module_decl => |*m| try walkItems(alloc, list, m.items, m.logical_name),
            .event_decl => |*ed| try appendDeclItem(alloc, list, module_name, ed),
            .proc_decl => |*pd| try appendDeclItem(alloc, list, module_name, pd),
            .flow => |*fl| {
                const module = if (fl.module.len > 0) fl.module else module_name orelse "";
                try walkFlow(alloc, list, fl, module, &flow_ords);
            },
            else => {},
        }
    }
}

fn walkFlow(
    alloc: std.mem.Allocator,
    list: *SiteList,
    fl: *const ast.Flow,
    module: []const u8,
    flow_ords: *OrdMap,
) !void {
    const node: *const ast.Node = if (fl.body.node) |*n| n else return;
    if (node.* != .invocation) return;
    const inv = &node.invocation;
    const spelling = try spellPath(alloc, inv.path);
    const ord = try bump(flow_ords, spelling);
    const item_key = try std.fmt.allocPrint(alloc, "flow:{s}#{d}", .{ spelling, ord });
    const item_keys: []const []const u8 = &.{ module, item_key };
    try list.append(alloc, .{
        .hash = try hashPath(alloc, item_keys),
        .ptr = @intFromPtr(inv),
        .kind = .flow,
        .spelling = spelling,
        .module = module,
        .location = fl.location,
    });
    var site_ords = OrdMap.init(alloc);
    defer site_ords.deinit();
    try walkConts(alloc, list, fl.body.continuations, module, item_keys, &site_ords);
}

fn walkConts(
    alloc: std.mem.Allocator,
    list: *SiteList,
    conts: []const ast.Continuation,
    module: []const u8,
    parent_keys: []const []const u8,
    site_ords: *OrdMap,
) !void {
    if (parent_keys.len >= MAX_DEPTH) return;
    for (conts) |*c| {
        const node: *const ast.Node = if (c.node) |*n| n else continue;
        switch (node.*) {
            .invocation => |*inv| {
                const spelling = try spellPath(alloc, inv.path);
                const ord = try bump(site_ords, spelling);
                const site_key = try std.fmt.allocPrint(alloc, "site:{s}#{d}", .{ spelling, ord });
                const keys = try alloc.alloc([]const u8, parent_keys.len + 1);
                @memcpy(keys[0..parent_keys.len], parent_keys);
                keys[parent_keys.len] = site_key;
                try list.append(alloc, .{
                    .hash = try hashPath(alloc, keys),
                    .ptr = @intFromPtr(inv),
                    .kind = .site,
                    .spelling = spelling,
                    .module = module,
                    .location = c.location,
                });
                try walkConts(alloc, list, c.continuations, module, keys, site_ords);
            },
            else => try walkConts(alloc, list, c.continuations, module, parent_keys, site_ords),
        }
    }
}

/// ptr → hash. The transform holds the AST pointer; the enumerator recorded
/// the same pointer — no re-walk, no re-keying.
pub fn hashOf(sites: []const Site, ptr: usize) ?[]const u8 {
    for (sites) |s| if (s.ptr == ptr) return s.hash;
    return null;
}

/// Map a list of node pointers to their canonical hashes — a property's
/// witness list (`inserts = 1 [deadb]` is the count AND its sites).
pub fn hashesFor(alloc: std.mem.Allocator, sites: []const Site, ptrs: []const usize) ![]const []const u8 {
    var out = try std.ArrayList([]const u8).initCapacity(alloc, ptrs.len);
    for (ptrs) |p| if (hashOf(sites, p)) |h| try out.append(alloc, h);
    return out.items;
}

/// Shortest prefix of `hash` shared by no other site's hash — the display
/// width that keeps ` [deadb]` unambiguous inside this catalog.
pub fn displayLen(sites: []const Site, hash: []const u8) usize {
    var w: usize = SEG_CHARS;
    while (w < hash.len) : (w += 1) {
        var unique = true;
        for (sites) |s| {
            if (std.mem.eql(u8, s.hash, hash)) continue;
            if (s.hash.len >= w and std.mem.eql(u8, s.hash[0..w], hash[0..w])) {
                unique = false;
                break;
            }
        }
        if (unique) return w;
    }
    return hash.len;
}

pub const Resolution = struct {
    /// Sites in the deepest prefix cell the query still lands on.
    matched: []const Site,
    /// Chars of the query that matched — a multiple of SEG_CHARS.
    depth_chars: usize,
    /// Query ran past the deepest live prefix: the tail drifted, but the
    /// matched cell is still the right neighborhood.
    drifted: bool,
};

/// Longest-prefix descent: a hash is a path with graceful degradation, not a
/// pointer. Try the full query; on a miss, chomp right until something
/// matches. The answer is always "the right neighborhood," never null-or-hit.
pub fn resolve(alloc: std.mem.Allocator, sites: []const Site, query_raw: []const u8) !Resolution {
    const query = std.mem.trim(u8, query_raw, "[] \t\n");
    var n = @min(query.len, MAX_DEPTH * SEG_CHARS);
    while (n >= SEG_CHARS) : (n -= 1) {
        var matched = std.ArrayList(Site){};
        for (sites) |s| {
            if (s.hash.len >= n and std.mem.eql(u8, s.hash[0..n], query[0..n]))
                try matched.append(alloc, s);
        }
        if (matched.items.len > 0)
            return .{ .matched = matched.items, .depth_chars = n, .drifted = n < query.len };
    }
    return .{ .matched = &.{}, .depth_chars = 0, .drifted = query.len > 0 };
}

/// Immediate children of a site — the matryoshka step. Children are sites
/// whose hash has `parent.hash` as a prefix exactly one level longer, so `at`
/// never needs tree knowledge: prefix ops over the flat site list.
pub fn children(alloc: std.mem.Allocator, sites: []const Site, parent: Site) ![]Site {
    var out = std.ArrayList(Site){};
    for (sites) |s| {
        if (s.hash.len == parent.hash.len + SEG_CHARS and
            std.mem.startsWith(u8, s.hash, parent.hash))
            try out.append(alloc, s);
    }
    return out.items;
}
