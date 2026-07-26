# 🌍 world-weather.sh

A terminal-based weather and astronomical data tool with **live fuzzy search over every city on Earth**. Type a few letters, pick a city from an `fzf` picker, and get a full weather report — temperature, feels-like, wind, air quality, sunrise/sunset, and moon phase — right in your terminal.

```
╔════════════════════════════════════════════════════════╗
║     🌍 WORLDWIDE WEATHER - ALL CITIES DATABASE 🌍      ║
╚════════════════════════════════════════════════════════╝
```

## What it does

- **Search any city worldwide** — not a hardcoded list. The picker searches a local database built from the full [GeoNames](https://www.geonames.org/) dump, so obscure towns work just as well as capital cities.
- **Type-as-you-go search** — every keystroke re-queries a local SQLite database (via FTS5 prefix search), so results update instantly even with millions of cities in the index.
- **Recent cities** — your last 10 searches are remembered and shown first (marked with 🕐), with `Ctrl-R` to jump back to them at any point.
- **Full weather report** — current conditions, feels-like temperature, high/low, rain chance, humidity, pressure, wind (speed/direction/gusts), UV index, and color-coded US AQI.
- **Astronomical data** — sunrise, sunset, moonrise, moonset, moon phase, and illumination percentage.
- **Smart units** — Fahrenheit/mph for the US, Liberia, and Myanmar; Celsius/m·s⁻¹ everywhere else, with both shown side by side.
- **No API keys required** — weather comes from [Open-Meteo](https://open-meteo.com/), a free, keyless weather API.

## How it works

The project is a small pipeline of scripts, all shipped together:

| File | Role |
|---|---|
| `world-weather.sh` | Main entry point — dependency checks, city picker UI, weather fetching/rendering |
| `build_cities_db.py` | One-time (well, once-a-month) builder that turns the raw GeoNames dump into a fast, searchable SQLite database |
| `query_cities.py` | Runs a live full-text search against the cities database as you type in `fzf` |
| `recent_cities.py` | Tracks and serves your last 10 searched cities |

All three Python scripts must live in the same directory as `world-weather.sh` — it looks for them next to itself at runtime.

## Why the first run takes a while

The first time you run the script (or any time the cache expires), it needs to build its city search index from scratch:

1. **Downloads `allCountries.zip` from GeoNames** — this is the complete worldwide place-names dataset, and the download is **~350MB**. Time depends entirely on your connection.
2. **Extracts the raw `allCountries.txt`** — a multi-GB, tab-separated file listing every populated place and administrative division on Earth.
3. **Builds a SQLite database with an FTS5 full-text index** (`build_cities_db.py`) — this parses every line, filters to populated places (`P`) and administrative divisions (`A`), and writes them into SQLite with a prefix-indexed FTS5 virtual table so later searches are instant. This step is the "Building searchable database (this may take ~30s)" you'll see, though it can take longer on slower hardware.

After that, everything is cached locally in `~/.cache/weather_script/cities_db/cities.db`, and searches are instant. **The database is automatically refreshed every 30 days** (`CACHE_EXPIRY_DAYS`), so you'll see this one-time cost again roughly monthly to keep place names/populations current. Force a rebuild any time with:

```bash
./world-weather.sh --update
```

Check what's currently cached without triggering a rebuild:

```bash
./world-weather.sh --stats
```

## Dependencies

The script checks for these on startup and will tell you what's missing:

- `curl` — downloading the GeoNames dump and calling the weather APIs
- `jq` — parsing JSON API responses
- `bc` — floating-point math (unit conversions, moon phase calculation)
- `fzf` — the interactive fuzzy-search picker
- `awk` — text processing
- `python3` — building/querying the SQLite cities database

On Debian/Ubuntu-based systems:

```bash
sudo apt-get update && sudo apt-get install -y curl jq bc fzf gawk python3
```

## Usage

```bash
chmod +x world-weather.sh
./world-weather.sh
```

- Type to search live for a city.
- `Ctrl-R` — jump back to your recently searched cities.
- `Enter` — select a city and view its weather report.
- `Esc` — cancel the search.
- After viewing a report, you're prompted to look up another city or exit.

Flags:

| Flag | Effect |
|---|---|
| `--update` | Force-delete and rebuild the cities database, even if it hasn't expired |
| `--stats` | Print database stats (city count, size, last updated) and exit |

## Data sources

- **[GeoNames](https://www.geonames.org/)** — worldwide place names, coordinates, populations, timezones (CC-BY 4.0 license; attribution required if redistributed)
- **[Open-Meteo](https://open-meteo.com/)** — current/hourly/daily weather, air quality, and moon data — free, no API key needed

## Notes and gotchas

- The GeoNames dump is large; make sure you have a few hundred MB of free disk space in `~/.cache/weather_script/` before the first run.
- Country-name display currently shows the raw ISO country code (e.g. `US`, `IN`) rather than a full name — there's a placeholder for a proper code→name mapping if you want to extend it.
- AQI is reported using the **US AQI** scale when available, falling back to the **European AQI** scale.
- Everything runs locally except the two outbound calls per session: one to GeoNames (only when the DB needs rebuilding) and one set to Open-Meteo (every weather lookup).
