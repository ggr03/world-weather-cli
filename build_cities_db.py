#!/usr/bin/env python3
"""
build_cities_db.py

Builds (or rebuilds) the SQLite cities database used by world-weather.sh
from a GeoNames allCountries.txt dump (tab-separated, no header).

Usage:
    build_cities_db.py <path-to-allCountries.txt> <path-to-cities.db>

On success, writes/updates a `meta` table with last_updated (unix epoch)
and total_cities, so the caller can decide when a re-download is due.
"""
import sqlite3
import sys
import time
import os

GEONAMES_COLUMNS = [
    "geonameid", "name", "asciiname", "alternatenames", "latitude", "longitude",
    "feature_class", "feature_code", "country_code", "cc2", "admin1_code",
    "admin2_code", "admin3_code", "admin4_code", "population", "elevation",
    "dem", "timezone", "modification_date",
]

SCHEMA = """
DROP TABLE IF EXISTS cities;
DROP TABLE IF EXISTS cities_fts;
DROP TABLE IF EXISTS meta;

CREATE TABLE cities (
    id            INTEGER PRIMARY KEY,
    name          TEXT NOT NULL,
    country_code  TEXT,
    admin1        TEXT,
    lat           REAL,
    lon           REAL,
    population    INTEGER,
    timezone      TEXT,
    display       TEXT
);

-- FTS5 with prefix indexes: makes "type a few letters -> instant matches"
-- fast even with millions of rows, because SQLite can jump straight to
-- matching prefixes instead of scanning every row.
CREATE VIRTUAL TABLE cities_fts USING fts5(
    name,
    content='cities',
    content_rowid='id',
    prefix='2 3 4'
);

CREATE TABLE meta (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def build(input_path: str, db_path: str) -> None:
    tmp_path = db_path + ".tmp"
    if os.path.exists(tmp_path):
        os.remove(tmp_path)

    con = sqlite3.connect(tmp_path)
    con.executescript(SCHEMA)
    con.execute("PRAGMA journal_mode=WAL")
    con.execute("PRAGMA synchronous=OFF")

    total = 0
    batch = []
    BATCH_SIZE = 20000

    def flush():
        nonlocal batch
        if not batch:
            return
        con.executemany(
            """INSERT INTO cities
               (id, name, country_code, admin1, lat, lon, population, timezone, display)
               VALUES (?,?,?,?,?,?,?,?,?)""",
            batch,
        )
        batch = []

    with open(input_path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.rstrip("\n").split("\t")
            if len(parts) < 19:
                continue
            row = dict(zip(GEONAMES_COLUMNS, parts))

            # Only populated places and administrative divisions (matches
            # the filtering the original bash/awk pipeline used).
            if row["feature_class"] not in ("P", "A"):
                continue

            name = row["name"].strip()
            if not name:
                continue

            country_code = row["country_code"]
            admin1 = row["admin1_code"]
            try:
                lat = float(row["latitude"])
                lon = float(row["longitude"])
            except ValueError:
                continue
            try:
                population = int(row["population"]) if row["population"] else 0
            except ValueError:
                population = 0
            timezone = row["timezone"]

            display = f"{name}, {admin1}, {country_code}" if admin1 else f"{name}, {country_code}"

            total += 1
            batch.append((total, name, country_code, admin1, lat, lon, population, timezone, display))

            if len(batch) >= BATCH_SIZE:
                flush()

    flush()
    con.execute("INSERT INTO cities_fts(rowid, name) SELECT id, name FROM cities")

    now = int(time.time())
    con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('last_updated', ?)", (str(now),))
    con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('total_cities', ?)", (str(total),))
    con.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('version', '3.0')")

    con.commit()
    con.execute("PRAGMA optimize")
    con.close()

    os.replace(tmp_path, db_path)
    print(f"Cities database built: {total} cities -> {db_path}", file=sys.stderr)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: build_cities_db.py <allCountries.txt> <cities.db>", file=sys.stderr)
        sys.exit(1)
    build(sys.argv[1], sys.argv[2])
