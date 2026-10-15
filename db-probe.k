// db-probe.k — does koru-libs/sqlite3 read the vendored Rails schema?
// Gate for the whole port: if this prints seeded rows, the describe-the-
// library path carries the app. Run: koruc db-probe.k && ./a.out

import koru/sqlite3
import std/io

koru/sqlite3:open(path: "seed/dev.db")
| db d |> koru/sqlite3(conn: d) {
        SELECT u.name AS who, r.name AS room, COUNT(m.id) AS n
        FROM users u, rooms r, messages m
        WHERE m.room_id = r.id AND m.creator_id = u.id
        GROUP BY u.id, r.id
    }
    ! row r |> koru/sqlite3:col.text(stmt: r, index: 0): who
        |> koru/sqlite3:col.text(stmt: r, index: 1): room
        |> koru/sqlite3:col.int(stmt: r, index: 2): n
        |> std/io:print.ln("{{ who:s }} in {{ room:s }}: {{ n:d }} message(s)")
    | done d2 |> koru/sqlite3:close(conn: d2) |> std/io:print.ln("closed")
    | err e |> koru/sqlite3:close(e.conn) |> std/io:print.ln("query err: {{ e.msg:s }}")
| err _ |> std/io:print.ln("open failed")
