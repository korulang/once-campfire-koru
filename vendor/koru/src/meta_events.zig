const std = @import("std");
const ast = @import("ast");
const errors = @import("errors");

/// Meta-Event Injection Pass
///
/// This compiler pass injects synthetic meta-event flows into the AST BEFORE tap transformation.
/// Meta-events like `koru:start` and `koru:end` are used to mark program lifecycle boundaries
/// that taps can observe (e.g., profiler writes header/footer).
///
/// The beauty: Once injected, these become regular AST items that tap transformation handles!
/// No special cases needed - the profiler tap `~koru:start -> * | Profile p |>` just works.

fn metaLocation() errors.SourceLocation {
    return .{ .file = "koru_meta_events", .line = 0, .column = 0 };
}

/// Build the `koru:<name> {} | done {}` decl — one of the two lifecycle
/// tors the koru module injects.
fn koruLifecycleDecl(allocator: std.mem.Allocator, name: []const u8) !ast.Item {
    var branches = try allocator.alloc(ast.Branch, 1);
    branches[0] = ast.Branch{
        .name = try allocator.dupe(u8, "done"),
        .payload = ast.Shape{ .fields = &.{} },
    };

    var segments = try allocator.alloc([]const u8, 1);
    segments[0] = try allocator.dupe(u8, name);

    return ast.Item{
        .event_decl = ast.EventDecl{
            .path = ast.DottedPath{
                .module_qualifier = try allocator.dupe(u8, "koru"),
                .segments = segments,
            },
            .input = ast.Shape{ .fields = &.{} },
            .branches = branches,
            .is_public = true,
            .is_implicit_flow = true,
            .annotations = &.{},
            .location = metaLocation(),
            .module = try allocator.dupe(u8, "koru"),
        },
    };
}

/// Build the `~koru:<name>() | done |> _` flow — one of the two lifecycle
/// flows the pass injects.
fn koruLifecycleFlow(allocator: std.mem.Allocator, name: []const u8) !ast.Item {
    var continuations = try allocator.alloc(ast.Continuation, 1);
    continuations[0] = ast.Continuation{
        .branch = try allocator.dupe(u8, "done"),
        .binding = null,  // Discard pattern (no binding)
        .binding_type = .branch_payload,
        .binding_annotations = &[_][]const u8{},
        .is_catchall = false,
        .catchall_metatype = null,
        .condition = null,
        .condition_expr = null,
        .node = null,  // Empty (no node)
        .indent = 0,
        .continuations = &.{},
        .location = metaLocation(),
    };

    var segments = try allocator.alloc([]const u8, 1);
    segments[0] = try allocator.dupe(u8, name);

    return ast.Item{
        .flow = ast.Flow{
            .body = ast.rootSite(ast.Invocation{
                .path = ast.DottedPath{
                    .module_qualifier = try allocator.dupe(u8, "koru"),
                    .segments = segments,
                },
                .args = &.{},
            }, continuations, metaLocation()),
            .location = metaLocation(),
            .module = try allocator.dupe(u8, "koru"),
        },
    };
}

/// Inject meta-event items into the program AST
/// MUST be called AFTER canonicalization (so events get module qualifiers)
/// MUST be called BEFORE tap transformation (so taps can observe these flows)
pub fn injectMetaEvents(allocator: std.mem.Allocator, program: *ast.Program) !void {
    // Calculate how many items we need to add
    // We're adding:
    // - 1 module declaration for 'koru' containing 2 event decls
    // - 2 top-level flows (~koru:start and ~koru:end)
    const items_to_add: usize = 3;
    const old_len = program.items.len;
    const new_len = old_len + items_to_add;

    // Reallocate items array to fit new items
    var new_items = try allocator.alloc(ast.Item, new_len);

    // Copy existing items
    @memcpy(new_items[0..old_len], program.items);

    // Don't free old items array - we're using an arena allocator that will clean up everything
    // when parse_arena.deinit() is called at the end of main()

    // Create koru module with start and end tors
    var koru_module_items = try allocator.alloc(ast.Item, 2);
    koru_module_items[0] = try koruLifecycleDecl(allocator, "start");
    koru_module_items[1] = try koruLifecycleDecl(allocator, "end");

    // Module declaration for 'koru'
    new_items[old_len] = ast.Item{
        .module_decl = ast.ModuleDecl{
            .logical_name = try allocator.dupe(u8, "koru"),
            .canonical_path = try allocator.dupe(u8, "koru_meta_events"),
            .items = koru_module_items,
            .is_system = false,  // NOT a system module - should be emitted in runtime backend only
            .location = metaLocation(),
        },
    };

    // Flows: ~koru:start() | done |> _  and  ~koru:end() | done |> _
    new_items[old_len + 1] = try koruLifecycleFlow(allocator, "start");
    new_items[old_len + 2] = try koruLifecycleFlow(allocator, "end");

    // Update program items
    program.items = new_items;
}
