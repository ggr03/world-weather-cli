#!/usr/bin/env python3
"""
query_cities.py <cities.db> <query-term>

Prints matching cities, one per line, pipe-delimited:
    search_key|name|country_code|admin1|lat|lon|display|population|timezone

If query-term is empty, returns the most populous cities (a sensible
default list before the user has typed anything). Designed to be cheap
enough to run on every keystroke (fzf's `change:reload` binding).
"""
import sqlite3
import sys

LIMIT = 50


def escape_fts_term(term: str) -> str:
    """Turn a raw user token into a safe FTS5 prefix-match token."""
    # Strip characters FTS5 query syntax treats specially; keep it simple
    # and permissive since this is a search box, not a query language.
    cleaned = "".join(ch for ch in term if ch.isalnum() or ch in " -'")
    cleaned = cleaned.strip()
    if not cleaned:
        return ""
    tokens = cleaned.split()
    # Quote each token and mark as a prefix match; join with AND (implicit)
    return " ".join(f'"{tok}"*' for tok in tokens)


def main():
    if len(sys.argv) < 2:
        print("Usage: query_cities.py <cities.db> [query-term]", file=sys.stderr)
        sys.exit(1)

    db_path = sys.argv[1]
    term = sys.argv[2] if len(sys.argv) > 2 else ""

    con = sqlite3.connect(db_path)
    con.row_factory = sqlite3.Row

    fts_query = escape_fts_term(term)

    if fts_query:
        rows = con.execute(
            """
            SELECT c.name, c.country_code, c.admin1, c.lat, c.lon,
                   c.display, c.population, c.timezone
            FROM cities_fts
            JOIN cities c ON c.id = cities_fts.rowid
            WHERE cities_fts MATCH ?
            ORDER BY c.population DESC
            LIMIT ?
            """,
            (fts_query, LIMIT),
        ).fetchall()
    else:
        rows = con.execute(
            """
            SELECT name, country_code, admin1, lat, lon, display, population, timezone
            FROM cities
            ORDER BY population DESC
            LIMIT ?
            """,
            (LIMIT,),
        ).fetchall()

    out = []
    for r in rows:
        search_key = r["name"].lower()
        out.append(
            "|".join(
                str(x) for x in (
                    search_key, r["name"], r["country_code"] or "",
                    r["admin1"] or "", r["lat"], r["lon"], r["display"],
                    r["population"] or 0, r["timezone"] or "",
                )
            )
        )
    sys.stdout.write("\n".join(out))
    if out:
        sys.stdout.write("\n")


if __name__ == "__main__":
    main()
