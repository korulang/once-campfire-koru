// MINIMAL REPRO — compiler defect, koru worktree fix pending.
//
// `if` used inside an orisha route-branch continuation emits
// `__koru_continue_0` / `__koru_continue_1` placeholders into
// output_emitted.zig (unfilled template splices), producing
// "expected ';' after statement" at the Zig level.
//
// The if template's continuation splice doesn't reach inside the
// router transform's generated handler. Koru side accepts it
// (shape check passes); the leak is backend-only.
//
// Workaround in main.k: the branch moved into pages:page-status
// (empty buffer -> 204) since the conditional is buffer state,
// not request logic. This file pins the emission gap itself.

import orisha
import std/io

orisha:handler = orisha:router(req)
! [GET /t] -> { status: 200, body: "t", content_type: "text/plain" }
! [*] |> if(req.path.len > 0)
    | then -> { status: 404, body: "nope", content_type: "text/plain" }
    | else -> { status: 404, body: "nope", content_type: "text/plain" }

orisha:serve(port: 3198)
| shutdown s |> std/io:print.ln(s)
| failed   f |> std/io:print.ln(f)
