# 🌍 world-weather.sh

A terminal-based weather and astronomical data tool with **live fuzzy search over every city on Earth**. Type a few letters, pick a city from an `fzf` picker, and get a full weather report — temperature, feels-like, wind, air quality, sunrise/sunset, and moon phase — right in your terminal.

```
╔════════════════════════════════════════════════════════╗
║        WEATHER & ASTRONOMICAL REPORT                  ║
╚════════════════════════════════════════════════════════╝

  Location:        Port Coquitlam, 02, CA
  Coordinates:     49.26637, -122.76932
  Population:      58000
  Local Time:      01:16:45 PM PDT - Sunday, July 26, 2026
  Timezone:        America/Vancouver

┌──────────────────────────────────────────────────────────┐
│                  CURRENT CONDITIONS                     │
└──────────────────────────────────────────────────────────┘

  Condition:       🌧️ Drizzle
  Temperature:     60.8°F / 16.0°C
  Feels Like:      63.1°F / 17.3°C
  High/Low:        64.4°F/59.7°F (18.0°C/15.4°C)
  Rain Chance:     88% now (Max today: 91%)
  Precipitation:   0.30mm

┌──────────────────────────────────────────────────────────┐
│                  DETAILED CONDITIONS                    │
└──────────────────────────────────────────────────────────┘

  Humidity:        96%
  Air Pressure:    1017.1 hPa (30.03 inHg)
  Wind:            0.95 m/s from ENE (72°)
  Wind Gusts:      1.20 m/s
  UV Index:        0.45 (Max today: 0.75)
  Air Quality:     44 (Good)

┌──────────────────────────────────────────────────────────┐
│                  ASTRONOMICAL DATA                       │
└──────────────────────────────────────────────────────────┘

  Sunrise:         05:35
  Sunset:          20:59
  Moonrise:        19:45
  Moonset:         02:12
  Moon Phase:      🌔 Waxing Gibbous
  Illumination:    94%

Look up another city? [Y/n]:
```

*(Illustrative output — every label lines up in a fixed column regardless of length, and AQI/moon phase are shown for real, live values rather than the placeholder examples above.)*

## What it does

- **Search any city worldwide** — not a hardcoded list. The picker searches a local database built from the full [GeoNames](https://www.geonames.org/) dump, so obscure towns work just as well as capital cities.
- **Type-as-you-go search** — every keystroke re-queries a local SQLite database (via FTS5 prefix search), so results update instantly even with millions of cities in the index.
- **Recent cities** — your last 10 searches are remembered and shown first (marked with 🕐) before you type anything, with `Ctrl-R` to jump back to them at any point mid-search.
- **Look up multiple cities per session** — after viewing a report, you're asked whether to search again or exit, instead of the script quitting after one lookup.
- **Full weather report** — current conditions, feels-like temperature, high/low, rain chance, humidity, pressure, wind (speed/direction/gusts), UV index, and color-coded US AQI.
- **Astronomical data** — sunrise, sunset, moonrise, moonset, moon phase, and illumination percentage, computed locally (see below).
- **Smart units** — Fahrenheit/mph for the US, Liberia, and Myanmar; Celsius/m·s⁻¹ everywhere else, with both shown side by side.
- **No API keys required** — weather comes from [Open-Meteo](https://open-meteo.com/), a free, keyless weather API.
- **Readable, aligned output** — every section uses a fixed label column and bright, high-contrast colors so values line up and stay legible on a plain black terminal background.

## Report sections, explained

**Header block** — the city you picked (`Location`), its coordinates, GeoNames population figure, and its current local time/date/timezone, all derived from the timezone Open-Meteo returns for those coordinates.

**Current Conditions** — the live snapshot: condition text with an emoji (drizzle, clear sky, snow, etc., mapped from Open-Meteo's numeric weather code), current temperature and feels-like in both units, today's forecast high/low, current + today's-max rain probability, and precipitation accumulated so far today.

**Detailed Conditions** — humidity, sea-level pressure (hPa and inHg), wind speed/direction/gusts, current + today's-max UV index, and US AQI (falling back to European AQI if US isn't available). AQI is color-coded by severity band (Good/Moderate/Unhealthy for Sensitive Groups/Unhealthy/Very Unhealthy/Hazardous) using the standard EPA breakpoints — this used to silently mis-render for any two-digit AQI due to a shell pattern-matching bug, which is now fixed.

**Astronomical Data** — sunrise/sunset from Open-Meteo, plus moonrise, moonset, moon phase name, and illumination percentage. These are **not** fetched from any weather API — Open-Meteo's moon fields turned out to be unreliable in practice, so they're computed locally by `moon_calc.py`, a Python port of the same [SunCalc.js](https://github.com/mourner/suncalc) astronomical algorithms used by many moon-phase widgets. It's pure math from the current time + your coordinates (Meeus's low-precision solar/lunar position formulas), so there's no API call and nothing for a provider to get wrong. Validated against an independent astronomy library (`ephem`) to within ~0.5% on illumination and a few minutes on rise/set times across multiple dates and locations.

**Footer + continue prompt** — a reminder of the data sources, followed by a `Look up another city? [Y/n]` prompt. Answering no (or `n`) exits; anything else clears the screen and starts a new search.

## How it works

The project is a small pipeline of scripts, all shipped together:

| File | Role |
|---|---|
| `world-weather.sh` | Main entry point — dependency checks, city picker UI, weather fetching/rendering, the search-again/quit loop |
| `build_cities_db.py` | One-time (well, once-a-month) builder that turns the raw GeoNames dump into a fast, searchable SQLite database |
| `query_cities.py` | Runs a live full-text search against the cities database as you type in `fzf` |
| `recent_cities.py` | Tracks and serves your last 10 searched cities, deduplicated and most-recent-first |
| `moon_calc.py` | Computes moon phase, illumination, moonrise, and moonset locally — no API call |

**All four Python scripts must live in the same directory as `world-weather.sh`** — it looks for them next to itself at runtime.

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

- `curl` — downloading the GeoNames dump and calling the weather/AQI APIs
- `jq` — parsing JSON API responses
- `bc` — floating-point math (unit conversions, final illumination rounding)
- `fzf` — the interactive fuzzy-search picker, including the live recent-cities/search reload
- `awk` — text processing
- `python3` — building/querying the SQLite cities database, recent-cities tracking, and all moon calculations

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
- After viewing a report, you're prompted to look up another city or exit — answer `n` (or anything starting with n/N) to quit, anything else to search again.

Flags:

| Flag | Effect |
|---|---|
| `--update` | Force-delete and rebuild the cities database, even if it hasn't expired |
| `--stats` | Print database stats (city count, size, last updated) and exit |

## Data sources

- **[GeoNames](https://www.geonames.org/)** — worldwide place names, coordinates, populations, timezones (CC-BY 4.0 license; attribution required if redistributed)
- **[Open-Meteo](https://open-meteo.com/)** — current/hourly/daily weather and air quality — free, no API key needed
- **Local calculation** — moonrise, moonset, moon phase, and illumination are computed on-device (see `moon_calc.py`), not fetched from any API

## Notes and gotchas

- The GeoNames dump is large; make sure you have a few hundred MB of free disk space in `~/.cache/weather_script/` before the first run.
- Country-name display currently shows the raw ISO country code (e.g. `US`, `IN`) rather than a full name — there's a placeholder for a proper code→name mapping if you want to extend it.
- AQI is reported using the **US AQI** scale when available, falling back to the **European AQI** scale.
- Network calls per session: one to GeoNames (only when the city database needs rebuilding, roughly monthly) and one set to Open-Meteo per weather lookup (current/hourly/daily weather + AQI). Moon data involves no network call at all.
