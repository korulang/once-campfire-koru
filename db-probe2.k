// db-probe2.k — does the { SQL } source block interpolate {{id}}?

import koru/sqlite3
import std/io

tor probe { id: string }

probe = koru/sqlite3:open(path: "seed/dev.db")
| db d |> koru/sqlite3:default(conn: d) {
        SELECT m.id, rt.body FROM messages m
        JOIN action_text_rich_texts rt ON rt.record_type = 'Message' AND rt.record_id = m.id
        WHERE m.room_id = {{id}}
    }
    ! row r |> koru/sqlite3:col.int(stmt: r, index: 0): mid
        |> koru/sqlite3:col.text(stmt: r, index: 1): body
        |> std/io:print.ln("msg {{ mid:d }}: {{ body:s }}")
    | done d2 |> koru/sqlite3:close(conn: d2) |> std/io:print.ln("closed")
    | err e |> koru/sqlite3:close(e.conn) |> std/io:print.ln("query err: {{ e.msg:s }}")
| err _ |> std/io:print.ln("open failed")

probe(id: "1")
