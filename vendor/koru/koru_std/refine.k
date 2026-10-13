// Koru Standard Library: Refine — value-level constraints on declared fields
// ===========================================================================
//
// `std/refine(Name) { name: type & constraint… }` — a definition surface for
// constraints on ABSTRACTS: it never touches a value, only meets bounds onto
// a declaration another module made. The `&`-atoms meet per field name,
// order-independently; a meet that lands empty is a loud KORU205 refusal,
// never a last-wins override.
//
// SURFACE:
//   std/refine(Server) {
//     port: i64 & >1024 & <=65535
//   }
//   meets the `std/proto(Server)` declaration — refined fields must exist
//   there on one agreed base. The meet is name-keyed, total, confluent:
//   `std/refine` blocks in any module fold onto one facet that lands as a
//   typed `Item.facet_decl` — consumers match the node, never comment text.
//
// LAYERING — the point of a separate module: a bound can arrive apart
//   from the declaration. A library declares `std/proto(Server)` plainly;
//   a downstream module writes `std/refine(lib/home:Server) { port: i64 &
//   >1024 }` — `home:Name` rides the named-arg channel (proto's own
//   `app/alpha:Health` convention), addressing the type by home while the
//   facet meets the declaration program-wide. Definition is import-scoped;
//   the constraint rides the type, so enforcement is type-global.
//
// TARGET SCOPES: `std/refine(Server)|fpga { … }` selects a declared impl
//   variant (`proc default|fpga` below) — `|variant` keeps its one meaning,
//   implementation selection — and the selected impl stamps `target` onto
//   the facet it lands. The universal facet (bare `std/refine`) meets
//   unscoped blocks only; a `|fpga` facet meets universal + fpga blocks.
//   A tag with no declared impl is a loud KORU122 — the target vocabulary
//   is closed by declaration, never a facet minted under a name nobody
//   reads. Consumers read the universal facet by default; a target-aware
//   consumer asks for its scope (`facets.findFor`, `metFields(…, scope)`).
//
// ENFORCEMENT IS THE CONSUMER'S: refine emits data, never a check.
//   `std/store` insert, `std/json` decode, `std/list:push` — each reads the
//   facet at its own boundary and decides. An unconsumed facet is
//   enumerable documentation, not a hole.
//
// v0 ATOMS: `>N` `>=N` `<N` `<=N` `==N` over integer literals, plus the
// `clamp(lo, hi)` normalizer — on integer scalar bases, raw (`i64`) or
// named through a terminal (`Port`). Disjunction (`*a | b`) is next.
//
// NOTE: `.k` files carry no host lines, so host types are spelled through
// `std/compiler:` aliases (Program, Item, Source, Allocator); the
// transform's own proc takes `std` inside its body and uses
// `koru_allocator()` — the canonical accessor emitted into every module
// (emitter_helpers.zig), riding the Debug leak counter.
// The explainer (`koruc <file> explain`) reports the met facet; the impl
// is refine.explain.kz. @retain: the generated gather invokes it.
[comptime|explainer]pub tor explain-refine {
    program: *const std/compiler:Program,
    allocator: std/compiler:Allocator
} -> ExplainReport
[comptime|transform|pre]pub tor default {
    expr: Expression,
    source: Source,
    item: *const std/compiler:Item,
    program: *const std/compiler:Program,
    reporter: *std/compiler:ErrorReporter
} -> SiteResult

// Target-scoped refines: `std/refine(S)|fpga { … }` dispatches to this
// variant (the `|variant` glyph keeps its one meaning — select the impl),
// and the impl stamps `target: "fpga"` on the facet it lands. Each scope
// is a declared proc — a tag with no impl is a loud KORU122, never a
// facet minted under a name nobody reads.
proc default|fpga {
    return refineDefault(expr, source, item, program, reporter, "fpga");
}

proc default|zig {
    return refineDefault(expr, source, item, program, reporter, null);
}


