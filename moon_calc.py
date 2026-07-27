#!/usr/bin/env python3
"""
moon_calc.py <lat> <lon> <timezone>

Self-contained astronomical moon calculations for the local day (no
external API call). This is a faithful Python port of the moon
algorithms in SunCalc.js by Vladimir Agafonkin (BSD licensed,
https://github.com/mourner/suncalc), which are themselves based on
"Astronomical Algorithms" (Jean Meeus, 2nd ed., 1998) and the
Astronomy Answers articles (https://aa.quae.nl).

It's used here instead of any weather API's moon fields because moon
phase/illumination/rise/set is pure astronomical math that only needs
a timestamp and coordinates — there's nothing for a weather provider
to "not support" or get wrong, unlike e.g. precipitation forecasts.

Outputs JSON:
  {
    "phase": 0..1,        # 0/1=new, 0.25=first quarter, 0.5=full, 0.75=last quarter
    "fraction": 0..1,     # illuminated fraction (0=new moon, 1=full moon)
    "distance_km": float, # Earth-Moon distance right now
    "moonrise": "HH:MM" or null,  # local time, for today's local calendar day
    "moonset": "HH:MM" or null,
    "always_up": bool,    # moon never sets today (can happen near the poles)
    "always_down": bool   # moon never rises today
  }
"""
import sys
import json
import math
from datetime import datetime, timedelta, timezone as dt_timezone
from zoneinfo import ZoneInfo

RAD = math.pi / 180.0
DAY_MS = 86400000
J1970 = 2440588
J2000 = 2451545


def to_days(dt_utc: datetime) -> float:
    unix_ms = dt_utc.timestamp() * 1000.0
    j = unix_ms / DAY_MS - 0.5 + J1970
    return j - J2000


def right_ascension(l, b):
    e = RAD * 23.4397
    return math.atan2(math.sin(l) * math.cos(e) - math.tan(b) * math.sin(e), math.cos(l))


def declination(l, b):
    e = RAD * 23.4397
    return math.asin(math.sin(b) * math.cos(e) + math.cos(b) * math.sin(e) * math.sin(l))


def azimuth(H, phi, dec):
    return math.atan2(math.sin(H), math.cos(H) * math.sin(phi) - math.tan(dec) * math.cos(phi))


def altitude(H, phi, dec):
    return math.asin(math.sin(phi) * math.sin(dec) + math.cos(phi) * math.cos(dec) * math.cos(H))


def sidereal_time(d, lw):
    return RAD * (280.16 + 360.9856235 * d) - lw


def astro_refraction(h):
    if h < 0:
        h = 0
    return 0.0002967 / math.tan(h + 0.00312536 / (h + 0.08901179))


def solar_mean_anomaly(d):
    return RAD * (357.5291 + 0.98560028 * d)


def ecliptic_longitude(m):
    c = RAD * (1.9148 * math.sin(m) + 0.02 * math.sin(2 * m) + 0.0003 * math.sin(3 * m))
    p = RAD * 102.9372
    return m + c + p + math.pi


def sun_coords(d):
    m = solar_mean_anomaly(d)
    l = ecliptic_longitude(m)
    return {"dec": declination(l, 0), "ra": right_ascension(l, 0)}


def moon_coords(d):
    l = RAD * (218.316 + 13.176396 * d)
    m = RAD * (134.963 + 13.064993 * d)
    f = RAD * (93.272 + 13.229350 * d)
    l = l + RAD * 6.289 * math.sin(m)
    b = RAD * 5.128 * math.sin(f)
    dist = 385001 - 20905 * math.cos(m)
    return {"ra": right_ascension(l, b), "dec": declination(l, b), "dist": dist}


def get_moon_position(dt_utc, lat, lng):
    lw = RAD * -lng
    phi = RAD * lat
    d = to_days(dt_utc)
    c = moon_coords(d)
    H = sidereal_time(d, lw) - c["ra"]
    h = altitude(H, phi, c["dec"])
    h = h + astro_refraction(h)
    return {"altitude": h}


def get_moon_illumination(dt_utc):
    d = to_days(dt_utc)
    s = sun_coords(d)
    m = moon_coords(d)
    sdist = 149598000  # Earth-Sun distance, km

    phi = math.acos(
        math.sin(s["dec"]) * math.sin(m["dec"]) +
        math.cos(s["dec"]) * math.cos(m["dec"]) * math.cos(s["ra"] - m["ra"])
    )
    inc = math.atan2(sdist * math.sin(phi), m["dist"] - sdist * math.cos(phi))
    angle = math.atan2(
        math.cos(s["dec"]) * math.sin(s["ra"] - m["ra"]),
        math.sin(s["dec"]) * math.cos(m["dec"]) -
        math.cos(s["dec"]) * math.sin(m["dec"]) * math.cos(s["ra"] - m["ra"])
    )
    fraction = (1 + math.cos(inc)) / 2
    phase = 0.5 + 0.5 * inc * (-1 if angle < 0 else 1) / math.pi
    return {"fraction": fraction, "phase": phase, "distance_km": m["dist"]}


def get_moon_times(local_midnight_utc, lat, lng):
    """local_midnight_utc: a UTC datetime for local midnight (start of
    the local calendar day). Scans in 2-hour steps fitting a quadratic
    to the altitude curve, per the stargazing.net moonrise algorithm."""
    hc = RAD * 0.133
    h0 = get_moon_position(local_midnight_utc, lat, lng)["altitude"] - hc

    rise = None
    set_ = None
    ye = 0.0

    i = 1
    while i <= 23:
        h1 = get_moon_position(local_midnight_utc + timedelta(hours=i), lat, lng)["altitude"] - hc
        h2 = get_moon_position(local_midnight_utc + timedelta(hours=i + 1), lat, lng)["altitude"] - hc

        a = (h0 + h2) / 2 - h1
        b = (h2 - h0) / 2
        xe = -b / (2 * a) if a != 0 else 0
        ye = (a * xe + b) * xe + h1
        d = b * b - 4 * a * h1
        roots = 0
        x1 = x2 = None

        if d >= 0:
            dx = math.sqrt(d) / (abs(a) * 2) if a != 0 else 0
            x1 = xe - dx
            x2 = xe + dx
            if abs(x1) <= 1:
                roots += 1
            if abs(x2) <= 1:
                roots += 1
            if x1 < -1:
                x1 = x2

        if roots == 1:
            if h0 < 0:
                rise = i + x1
            else:
                set_ = i + x1
        elif roots == 2:
            rise = i + (x2 if ye < 0 else x1)
            set_ = i + (x1 if ye < 0 else x2)

        if rise is not None and set_ is not None:
            break

        h0 = h2
        i += 2

    result = {"rise": None, "set": None, "always_up": False, "always_down": False}
    if rise is not None:
        result["rise"] = local_midnight_utc + timedelta(hours=rise)
    if set_ is not None:
        result["set"] = local_midnight_utc + timedelta(hours=set_)
    if rise is None and set_ is None:
        if ye > 0:
            result["always_up"] = True
        else:
            result["always_down"] = True
    return result


def main():
    if len(sys.argv) < 4:
        print("Usage: moon_calc.py <lat> <lon> <timezone>", file=sys.stderr)
        sys.exit(1)

    lat = float(sys.argv[1])
    lon = float(sys.argv[2])
    tz_name = sys.argv[3]

    try:
        tz = ZoneInfo(tz_name)
    except Exception:
        tz = dt_timezone.utc

    now_utc = datetime.now(dt_timezone.utc)
    now_local = now_utc.astimezone(tz)
    local_midnight = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
    local_midnight_utc = local_midnight.astimezone(dt_timezone.utc)

    illum = get_moon_illumination(now_utc)
    times = get_moon_times(local_midnight_utc, lat, lon)

    def fmt(dt_val):
        if dt_val is None:
            return None
        return dt_val.astimezone(tz).strftime("%H:%M")

    out = {
        "phase": round(illum["phase"], 6),
        "fraction": round(illum["fraction"], 6),
        "distance_km": round(illum["distance_km"], 1),
        "moonrise": fmt(times["rise"]),
        "moonset": fmt(times["set"]),
        "always_up": times["always_up"],
        "always_down": times["always_down"],
    }
    print(json.dumps(out))


if __name__ == "__main__":
    main()
