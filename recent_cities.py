#!/usr/bin/env python3
"""
recent_cities.py <cities.db> <add|list>

add:  reads a JSON object from stdin describing the selected city and
      records it as the most recent (de-duplicating by display name),
      trimming the table down to the most recent 10 entries.
list: prints the most recent cities, pipe-delimited, most-recent-first,
      in the same format query_cities.py uses so they can be fed
      straight into fzf. Each display name is prefixed with a clock
      icon so the user can tell them apart from ordinary search hits.
"""
import sqlite3
import sys
import json
import time

LIMIT = 10

SCHEMA = """
CREATE TABLE IF NOT EXISTS recent_cities (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    name         TEXT,
    country_code TEXT,
    admin1       TEXT,
    lat          REAL,
    lon          REAL,
    display      TEXT,
    population   INTEGER,
    timezone     TEXT,
    last_used    INTEGER
);
"""


def add(db_path: str, payload: dict) -> None:
    con = sqlite3.connect(db_path)
    con.execute(SCHEMA)
    now = int(time.time())

    # De-dup: if this city was already recent, drop the old entry so it
    # moves back to the top instead of appearing twice.
    con.execute("DELETE FROM recent_cities WHERE lower(display) = lower(?)", (payload["display"],))

    con.execute(
        """INSERT INTO recent_cities
           (name, country_code, admin1, lat, lon, display, population, timezone, last_used)
           VALUES (?,?,?,?,?,?,?,?,?)""",
        (
            payload["name"], payload.get("country_code", ""), payload.get("admin1", ""),
            payload["lat"], payload["lon"], payload["display"],
            payload.get("population", 0), payload.get("timezone", ""), now,
        ),
    )

    # Keep only the most recent LIMIT entries.
    con.execute(
        """DELETE FROM recent_cities WHERE id NOT IN (
               SELECT id FROM recent_cities ORDER BY last_used DESC, id DESC LIMIT ?
           )""",
        (LIMIT,),
    )
    con.commit()


def list_recent(db_path: str) -> None:
    con = sqlite3.connect(db_path)
    con.execute(SCHEMA)
    con.row_factory = sqlite3.Row
    rows = con.execute(
        "SELECT * FROM recent_cities ORDER BY last_used DESC, id DESC LIMIT ?", (LIMIT,)
    ).fetchall()

    out = []
    for r in rows:
        search_key = r["name"].lower()
        display = f'🕐 {r["display"]}'
        out.append(
            "|".join(
                str(x) for x in (
                    search_key, r["name"], r["country_code"] or "",
                    r["admin1"] or "", r["lat"], r["lon"], display,
                    r["population"] or 0, r["timezone"] or "",
                )
            )
        )
    sys.stdout.write("\n".join(out))
    if out:
        sys.stdout.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: recent_cities.py <cities.db> <add|list>", file=sys.stderr)
        sys.exit(1)

    db_path, cmd = sys.argv[1], sys.argv[2]
    if cmd == "add":
        add(db_path, json.load(sys.stdin))
    elif cmd == "list":
        list_recent(db_path)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)
