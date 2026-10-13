const std = @import("std");
const ast = @import("ast");
const transform = @import("ast_transform");

/// Visitor pattern for traversing and transforming AST nodes
/// Supports both read-only traversal and mutation

pub const TraversalOrder = enum {
    pre_order,  // Visit node before children
    post_order, // Visit node after children
    both,       // Visit node both before and after children
};

pub const TraversalControl = enum {
    continue_traversal,
    skip_children,
    stop_traversal,
};

/// Generic AST visitor interface
pub const ASTVisitor = struct {
    allocator: std.mem.Allocator,
    context: ?*transform.TransformContext = null,
    order: TraversalOrder = .pre_order,
    
    // Visitor methods for each node type (pre-visit)
    visitSourceFilePre: ?*const fn (self: *ASTVisitor, file: *ast.Program) anyerror!TraversalControl = null,
    visitEventPre: ?*const fn (self: *ASTVisitor, event: *ast.EventDecl) anyerror!TraversalControl = null,
    visitProcPre: ?*const fn (self: *ASTVisitor, proc: *ast.ProcDecl) anyerror!TraversalControl = null,
    visitFlowPre: ?*const fn (self: *ASTVisitor, flow: *ast.Flow) anyerror!TraversalControl = null,
    visitLabelPre: ?*const fn (self: *ASTVisitor, label: *ast.LabelDecl) anyerror!TraversalControl = null,
    visitImmediateImplPre: ?*const fn (self: *ASTVisitor, ii: *ast.ImmediateImpl) anyerror!TraversalControl = null,
    visitImportPre: ?*const fn (self: *ASTVisitor, import: *ast.ImportDecl) anyerror!TraversalControl = null,
    visitHostLinePre: ?*const fn (self: *ASTVisitor, line: *ast.HostLine) anyerror!TraversalControl = null,

    // Visitor methods for each node type (post-visit)
    visitSourceFilePost: ?*const fn (self: *ASTVisitor, file: *ast.Program) anyerror!void = null,
    visitEventPost: ?*const fn (self: *ASTVisitor, event: *ast.EventDecl) anyerror!void = null,
    visitProcPost: ?*const fn (self: *ASTVisitor, proc: *ast.ProcDecl) anyerror!void = null,
    visitFlowPost: ?*const fn (self: *ASTVisitor, flow: *ast.Flow) anyerror!void = null,
    visitLabelPost: ?*const fn (self: *ASTVisitor, label: *ast.LabelDecl) anyerror!void = null,
    visitImmediateImplPost: ?*const fn (self: *ASTVisitor, ii: *ast.ImmediateImpl) anyerror!void = null,
    visitImportPost: ?*const fn (self: *ASTVisitor, import: *ast.ImportDecl) anyerror!void = null,
    visitHostLinePost: ?*const fn (self: *ASTVisitor, line: *ast.HostLine) anyerror!void = null,
    
    /// Start traversal from the root
    pub fn visit(self: *ASTVisitor, source_file: *ast.Program) !void {
        _ = try self.visitSourceFile(source_file);
    }
    
    fn visitSourceFile(self: *ASTVisitor, file: *ast.Program) !TraversalControl {
        // Pre-visit
        if (self.order == .pre_order or self.order == .both) {
            if (self.visitSourceFilePre) |visitor| {
                const control = try visitor(self, file);
                if (control == .stop_traversal) return .stop_traversal;
                if (control == .skip_children) {
                    // Still do post-visit if configured
                    if (self.order == .both and self.visitSourceFilePost != null) {
                        try self.visitSourceFilePost.?(self, file);
                    }
                    return .continue_traversal;
                }
            }
        }
        
        // Visit children
        for (file.items, 0..) |*item, i| {
            const mutable_item = @constCast(item);
            // Track parent if we have context
            if (self.context) |ctx| {
                try ctx.pushParent(mutable_item);
            }
            defer if (self.context) |ctx| ctx.popParent();
            
            const control = try self.visitItem(mutable_item, i);
            if (control == .stop_traversal) return .stop_traversal;
        }
        
        // Post-visit
        if (self.order == .post_order or self.order == .both) {
            if (self.visitSourceFilePost) |visitor| {
                try visitor(self, file);
            }
        }
        
        return .continue_traversal;
    }
    
    fn visitItem(self: *ASTVisitor, item: *ast.Item, index: usize) !TraversalControl {
        _ = index; // Available for transformations that need the index
        
        switch (item.*) {
            .event_decl => |*event| return self.visitEvent(event),
            .proc_decl => |*proc| return self.visitProc(proc),
            .flow => |*flow| return self.visitFlow(flow),
            .event_tap => |*tap| return self.visitEventTap(tap),
            .label_decl => |*label| return self.visitLabel(label),
            .immediate_impl => |*ii| return self.visitImmediateImpl(ii),
            .import_decl => |*import| return self.visitImport(import),
            .host_line => |*line| return self.visitHostLine(line),
            else => return .continue_traversal,
        }
    }
    
    /// Leaf visit shared by every node type with no children: pre hook,
    /// post hook. Under `both`-order traversal a `skip_children` from the
    /// pre hook still runs the post hook before the control propagates.
    fn visitLeaf(self: *ASTVisitor, node: anytype, comptime pre_field: []const u8, comptime post_field: []const u8) !TraversalControl {
        if (self.order == .pre_order or self.order == .both) {
            if (@field(self, pre_field)) |visitor| {
                const control = try visitor(self, node);
                if (control != .continue_traversal) {
                    if (control == .skip_children and self.order == .both and @field(self, post_field) != null) {
                        try @field(self, post_field).?(self, node);
                    }
                    return control;
                }
            }
        }
        if (self.order == .post_order or self.order == .both) {
            if (@field(self, post_field)) |visitor| {
                try visitor(self, node);
            }
        }
        return .continue_traversal;
    }

    fn visitEvent(self: *ASTVisitor, event: *ast.EventDecl) !TraversalControl {
        return self.visitLeaf(event, "visitEventPre", "visitEventPost");
    }
    
    fn visitProc(self: *ASTVisitor, proc: *ast.ProcDecl) !TraversalControl {
        // Proc body is opaque Zig code, no children to visit
        return self.visitLeaf(proc, "visitProcPre", "visitProcPost");
    }
    
    fn visitFlow(self: *ASTVisitor, flow: *ast.Flow) !TraversalControl {
        // Invocations and continuations could be visited here
        return self.visitLeaf(flow, "visitFlowPre", "visitFlowPost");
    }
    
    fn visitEventTap(self: *ASTVisitor, tap: *ast.EventTap) !TraversalControl {
        // For now, just return continue - taps are not transformed
        _ = self;
        _ = tap;
        return .continue_traversal;
    }
    
    fn visitLabel(self: *ASTVisitor, label: *ast.LabelDecl) !TraversalControl {
        return self.visitLeaf(label, "visitLabelPre", "visitLabelPost");
    }
    
    fn visitImmediateImpl(self: *ASTVisitor, ii: *ast.ImmediateImpl) !TraversalControl {
        return self.visitLeaf(ii, "visitImmediateImplPre", "visitImmediateImplPost");
    }
    
    fn visitImport(self: *ASTVisitor, import: *ast.ImportDecl) !TraversalControl {
        return self.visitLeaf(import, "visitImportPre", "visitImportPost");
    }
    
    fn visitHostLine(self: *ASTVisitor, line: *ast.HostLine) !TraversalControl {
        // Pre-visit
        if (self.order == .pre_order or self.order == .both) {
            if (self.visitHostLinePre) |visitor| {
                return try visitor(self, line);
            }
        }

        // Host lines have no children

        // Post-visit
        if (self.order == .post_order or self.order == .both) {
            if (self.visitHostLinePost) |visitor| {
                try visitor(self, line);
            }
        }

        return .continue_traversal;
    }
};

/// Specialized visitor for collecting information
pub const CollectingVisitor = struct {
    base: ASTVisitor,
    events: std.ArrayList(*ast.EventDecl),
    procs: std.ArrayList(*ast.ProcDecl),
    flows: std.ArrayList(*ast.Flow),
    
    pub fn init(allocator: std.mem.Allocator) !CollectingVisitor {
        return .{
            .base = ASTVisitor{
                .allocator = allocator,
                .visitEventPre = visitEvent,
                .visitProcPre = visitProc,
                .visitFlowPre = visitFlow,
            },
            .events = try std.ArrayList(*ast.EventDecl).initCapacity(allocator, 0),
            .procs = try std.ArrayList(*ast.ProcDecl).initCapacity(allocator, 0),
            .flows = try std.ArrayList(*ast.Flow).initCapacity(allocator, 0),
        };
    }
    
    pub fn deinit(self: *CollectingVisitor) void {
        self.events.deinit(self.base.allocator);
        self.procs.deinit(self.base.allocator);
        self.flows.deinit(self.base.allocator);
    }
    
    fn visitEvent(visitor: *ASTVisitor, event: *ast.EventDecl) !TraversalControl {
        const self: *CollectingVisitor = @fieldParentPtr("base", visitor);
        try self.events.append(visitor.allocator, event);
        return .continue_traversal;
    }
    
    fn visitProc(visitor: *ASTVisitor, proc: *ast.ProcDecl) !TraversalControl {
        const self: *CollectingVisitor = @fieldParentPtr("base", visitor);
        try self.procs.append(visitor.allocator, proc);
        return .continue_traversal;
    }
    
    fn visitFlow(visitor: *ASTVisitor, flow: *ast.Flow) !TraversalControl {
        const self: *CollectingVisitor = @fieldParentPtr("base", visitor);
        try self.flows.append(visitor.allocator, flow);
        return .continue_traversal;
    }
};

/// Specialized visitor for finding small events to inline
pub const InliningVisitor = struct {
    base: ASTVisitor,
    context: *transform.TransformContext,
    threshold: usize,
    candidates: std.ArrayList(InlineCandidate),
    
    pub const InlineCandidate = struct {
        flow_index: usize,
        invocation: *ast.Invocation,
        proc: *ast.ProcDecl,
    };
    
    pub fn init(allocator: std.mem.Allocator, context: *transform.TransformContext, threshold: usize) !InliningVisitor {
        return .{
            .base = ASTVisitor{
                .allocator = allocator,
                .context = context,
                .visitFlowPre = visitFlow,
            },
            .context = context,
            .threshold = threshold,
            .candidates = try std.ArrayList(InlineCandidate).initCapacity(allocator, 0),
        };
    }
    
    pub fn deinit(self: *InliningVisitor) void {
        self.candidates.deinit(self.base.allocator);
    }
    
    fn visitFlow(visitor: *ASTVisitor, flow: *ast.Flow) !TraversalControl {
        const self: *InliningVisitor = @fieldParentPtr("base", visitor);
        
        // Check if this flow's invocation is a candidate for inlining
        if (self.context.canInline(flow.inv().path)) {
            const path_str = try transform.pathToString(self.context.allocator, flow.inv().path);
            if (self.context.symbol_table.procs.get(path_str)) |_| {
                // Find the actual proc in the AST
                // This is simplified - in reality we'd need to search properly
                const candidate = InlineCandidate{
                    .flow_index = 0, // Would need to track this
                    .invocation = flow.inv(),
                    .proc = undefined, // Would need to find the actual proc
                };
                _ = candidate;
                // try self.candidates.append(candidate);
            }
        }
        
        return .continue_traversal;
    }
};
