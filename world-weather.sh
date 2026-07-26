#!/bin/bash

# Weather & Astronomical Information Script - Worldwide Edition (Optimized)
# Displays comprehensive weather data for cities worldwide with interactive search

set -euo pipefail

# Color codes for output (bold/bright variants read much better on black terminals)
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;94m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
WHITE='\033[1;37m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration
CACHE_DIR="${HOME}/.cache/weather_script"
CITIES_DIR="${CACHE_DIR}/cities_db"
CITIES_DB="${CITIES_DIR}/cities.db"
# Location of the helper scripts (build_cities_db.py, query_cities.py).
# They ship alongside this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DB_SCRIPT="${SCRIPT_DIR}/build_cities_db.py"
QUERY_DB_SCRIPT="${SCRIPT_DIR}/query_cities.py"
RECENT_DB_SCRIPT="${SCRIPT_DIR}/recent_cities.py"
CACHE_EXPIRY_DAYS=30

# Performance settings
export LANG=C
export LC_ALL=C

# Check for required commands
check_dependencies() {
    local missing_deps=()
    
    for cmd in curl jq bc fzf awk python3; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing_deps[*]}${NC}"
        echo -e "${YELLOW}Please install them using:${NC}"
        echo "sudo apt-get update && sudo apt-get install -y curl jq bc fzf gawk python3"
        exit 1
    fi
}

# Create cache directories
init_cache() {
    mkdir -p "$CITIES_DIR"
}

# Show progress bar
show_progress() {
    local current="$1"
    local total="$2"
    local prefix="$3"
    local width=50
    local percent=$((current * 100 / total))
    local filled=$((percent * width / 100))
    local empty=$((width - filled))
    
    printf "\r${prefix} ["
    printf "%${filled}s" | tr ' ' '='
    printf "%${empty}s" | tr ' ' ' '
    printf "] %3d%%" "$percent"
}

# Download with progress and resume support
download_with_progress() {
    local url="$1"
    local output="$2"
    local description="$3"
    
    echo -e "${YELLOW}Downloading $description...${NC}"
    
    if [ -f "$output" ]; then
        local file_size=$(stat -c %s "$output" 2>/dev/null || echo "0")
        curl -L -C - --progress-bar -o "$output" "$url"
    else
        curl -L --progress-bar -o "$output" "$url"
    fi
}

# Check how old the current database is, and whether it needs updating.
# Returns 0 (true) if a (re)build is needed.
db_needs_update() {
    if [ ! -f "$CITIES_DB" ]; then
        return 0
    fi

    local last_updated
    last_updated=$(python3 -c "
import sqlite3, sys
try:
    con = sqlite3.connect('$CITIES_DB')
    row = con.execute(\"SELECT value FROM meta WHERE key='last_updated'\").fetchone()
    print(row[0] if row else 0)
except Exception:
    print(0)
" 2>/dev/null || echo 0)

    local now=$(date +%s)
    local age=$((now - last_updated))
    local max_age=$((CACHE_EXPIRY_DAYS * 86400))

    [ "$age" -ge "$max_age" ]
}

# Download the GeoNames dump and (re)build the SQLite database + FTS index.
# Only runs when the DB is missing or older than CACHE_EXPIRY_DAYS.
download_cities_database() {
    if ! db_needs_update; then
        local total
        total=$(python3 -c "
import sqlite3
con = sqlite3.connect('$CITIES_DB')
row = con.execute(\"SELECT value FROM meta WHERE key='total_cities'\").fetchone()
print(row[0] if row else '?')
")
        echo -e "${GREEN}Using cached cities database ($total cities)${NC}"
        return 0
    fi

    echo -e "${YELLOW}Cities database missing or older than ${CACHE_EXPIRY_DAYS} days — updating...${NC}"
    echo -e "${YELLOW}Download size: ~350MB${NC}"

    local temp_zip="${CITIES_DIR}/allCountries.zip"
    local temp_txt="${CITIES_DIR}/allCountries.txt"

    download_with_progress "https://download.geonames.org/export/dump/allCountries.zip" \
        "$temp_zip" \
        "complete GeoNames database"

    if [ ! -f "$temp_zip" ]; then
        echo -e "${RED}Failed to download database${NC}"
        exit 1
    fi

    echo -e "\n${YELLOW}Extracting database...${NC}"
    (cd "$CITIES_DIR" && unzip -o "$temp_zip" allCountries.txt > /dev/null 2>&1)

    if [ ! -f "$temp_txt" ]; then
        echo -e "${RED}Failed to extract database${NC}"
        exit 1
    fi

    echo -e "${YELLOW}Building searchable database (this may take ~30s)...${NC}"
    if ! python3 "$BUILD_DB_SCRIPT" "$temp_txt" "$CITIES_DB"; then
        echo -e "${RED}Failed to build cities database${NC}"
        exit 1
    fi

    rm -f "$temp_zip" "$temp_txt"
    echo -e "${GREEN}Cities database ready for fast searching!${NC}"
}

# Live, type-as-you-go city search. Each keystroke re-queries SQLite via
# query_cities.py (fzf's --disabled + change:reload binding), rather than
# loading the whole multi-million-row dataset into fzf's own matcher.
#
# Before anything is typed, recently-searched cities (marked with 🕐) are
# shown first, followed by the most populous cities worldwide. Ctrl-R
# jumps back to the recent-only list at any point, so it's always a
# keystroke away even after you've started typing a new search.
select_city() {
    local selected

    selected=$(
        fzf \
            --disabled \
            --ansi \
            --delimiter='|' \
            --with-nth=7 \
            --prompt='🌍 Search any city (type to filter): ' \
            --header='Type to search live · Ctrl-R: recent cities · ENTER: select · ESC: cancel' \
            --height=50% \
            --layout=reverse \
            --border \
            --preview='IFS="|" read -r _ name cc admin1 lat lon display pop tz <<< {}; printf "📍 %s\n🌐 Coordinates: %s, %s\n👥 Population: %s\n🕐 Timezone: %s\n" "$display" "$lat" "$lon" "${pop:-Unknown}" "${tz:-Unknown}"' \
            --preview-window=up:4:wrap \
            --bind="start:reload:(python3 '$RECENT_DB_SCRIPT' '$CITIES_DB' list; python3 '$QUERY_DB_SCRIPT' '$CITIES_DB' '')" \
            --bind="change:reload:python3 '$QUERY_DB_SCRIPT' '$CITIES_DB' {q}" \
            --bind="ctrl-r:reload:python3 '$RECENT_DB_SCRIPT' '$CITIES_DB' list" \
            --history="${CACHE_DIR}/search_history" \
            --history-size=100
    )

    if [ -n "$selected" ]; then
        echo "$selected"
        return 0
    else
        return 1
    fi
}

# Parse selection and return location data
parse_selection() {
    local selection="$1"

    IFS='|' read -r search_key CITY COUNTRY_CODE STATE LAT LON DISPLAY POPULATION TIMEZONE <<< "$selection"

    # Strip the 🕐 recent-city marker from the display name if present,
    # since it's a UI hint, not part of the location's name.
    DISPLAY="${DISPLAY#🕐 }"

    # Get full country name from country code (simplified mapping for common countries)
    COUNTRY="$COUNTRY_CODE"
}

# Record the just-selected city as the most recent search (kept to the
# last 10, de-duplicated) so it surfaces at the top of select_city next time.
record_recent_city() {
    jq -n \
        --arg name "$CITY" \
        --arg cc "$COUNTRY_CODE" \
        --arg admin1 "$STATE" \
        --argjson lat "${LAT:-0}" \
        --argjson lon "${LON:-0}" \
        --arg display "$DISPLAY" \
        --argjson population "${POPULATION:-0}" \
        --arg timezone "$TIMEZONE" \
        '{name:$name, country_code:$cc, admin1:$admin1, lat:$lat, lon:$lon, display:$display, population:$population, timezone:$timezone}' \
    2>/dev/null | python3 "$RECENT_DB_SCRIPT" "$CITIES_DB" add 2>/dev/null || true
}

# Function to get weather data from Open-Meteo API
get_weather_data() {
    local lat="$1"
    local lon="$2"
    
    local url="https://api.open-meteo.com/v1/forecast"
    url+="?latitude=$lat&longitude=$lon"
    url+="&current=temperature_2m,relative_humidity_2m,apparent_temperature"
    url+=",precipitation,weather_code,pressure_msl,surface_pressure"
    url+=",wind_speed_10m,wind_direction_10m,wind_gusts_10m"
    url+=",uv_index"
    url+="&hourly=precipitation_probability,temperature_2m"
    url+="&daily=sunrise,sunset,temperature_2m_max,temperature_2m_min"
    url+=",precipitation_probability_max,uv_index_max"
    url+="&timezone=auto"
    
    # Smart unit selection based on country
    if [[ "$COUNTRY_CODE" == "US" || "$COUNTRY_CODE" == "LR" || "$COUNTRY_CODE" == "MM" ]]; then
        # United States, Liberia, Myanmar use imperial
        url+="&temperature_unit=fahrenheit"
        url+="&wind_speed_unit=mph"
    else
        url+="&temperature_unit=celsius"
        url+="&wind_speed_unit=ms"
    fi
    
    curl -s --max-time 10 "$url"
}

# Function to get AQI data
get_aqi_data() {
    local lat="$1"
    local lon="$2"
    
    local url="https://air-quality-api.open-meteo.com/v1/air-quality"
    url+="?latitude=$lat&longitude=$lon"
    url+="&current=us_aqi,us_aqi_pm2_5,us_aqi_pm10,us_aqi_ozone,european_aqi"
    url+="&timezone=auto"
    
    curl -s --max-time 10 "$url"
}

# Function to get moon data
get_moon_data() {
    local lat="$1"
    local lon="$2"
    
    local url="https://api.open-meteo.com/v1/forecast"
    url+="?latitude=$lat&longitude=$lon"
    url+="&daily=moonrise,moonset,moon_phase,moon_illumination"
    url+="&timezone=auto"
    url+="&forecast_days=1"
    
    curl -s --max-time 10 "$url"
}

# Function to convert weather code to description with emoji
get_weather_description() {
    local code="$1"
    case $code in
        0) echo "☀️ Clear sky" ;;
        1) echo "🌤️ Mainly clear" ;;
        2) echo "⛅ Partly cloudy" ;;
        3) echo "☁️ Overcast" ;;
        45|48) echo "🌫️ Foggy" ;;
        51|53|55) echo "🌧️ Drizzle" ;;
        61|63|65) echo "🌧️ Rain" ;;
        66|67) echo "🌨️ Freezing rain" ;;
        71|73|75) echo "❄️ Snowfall" ;;
        77) echo "🌨️ Snow grains" ;;
        80|81|82) echo "🌧️ Rain showers" ;;
        85|86) echo "🌨️ Snow showers" ;;
        95) echo "⛈️ Thunderstorm" ;;
        96|99) echo "⛈️ Thunderstorm with hail" ;;
        *) echo "❓ Unknown" ;;
    esac
}

# Function to get wind direction from degrees
get_wind_direction() {
    local degrees="$1"
    local directions=("N" "NNE" "NE" "ENE" "E" "ESE" "SE" "SSE" "S" "SSW" "SW" "WSW" "W" "WNW" "NW" "NNW")
    local index=$(( (($degrees + 11) % 360) / 22 ))
    echo "${directions[$index]}"
}

# Temperature conversion functions
c_to_f() {
    echo "scale=1; ($1 * 9 / 5) + 32" | bc
}

f_to_c() {
    echo "scale=1; ($1 - 32) * 5 / 9" | bc
}

# Main display function
# Draw a section header box whose border width is fixed and whose title
# is centered dynamically, so borders never drift out of alignment.
print_section_header() {
    local title="$1"
    local width=58
    local title_len=${#title}
    local pad_total=$((width - title_len))
    [ "$pad_total" -lt 0 ] && pad_total=0
    local pad_left=$((pad_total / 2))
    local pad_right=$((pad_total - pad_left))
    local border
    border=$(printf '─%.0s' $(seq 1 "$width"))
    printf "${BOLD}${CYAN}┌%s┐${NC}\n" "$border"
    printf "${BOLD}${CYAN}│%*s%s%*s│${NC}\n" "$pad_left" "" "$title" "$pad_right" ""
    printf "${BOLD}${CYAN}└%s┘${NC}\n" "$border"
}

# Print one label/value row with a fixed label column width, so values
# always start at the same screen column regardless of label length.
print_row() {
    local label="$1"
    local value="$2"
    printf "  ${BOLD}%-16s${NC} %b\n" "$label" "$value"
}

display_weather() {
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║        WEATHER & ASTRONOMICAL REPORT                  ║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo
    
    echo -e "${YELLOW}🔄 Fetching latest weather data...${NC}"
    
    # Fetch all data in parallel using background processes
    local weather_data aqi_data moon_data
    
    get_weather_data "$LAT" "$LON" > "${CACHE_DIR}/weather.json" &
    get_aqi_data "$LAT" "$LON" > "${CACHE_DIR}/aqi.json" &
    get_moon_data "$LAT" "$LON" > "${CACHE_DIR}/moon.json" &
    
    # Wait for all background processes to complete
    wait
    
    weather_data=$(cat "${CACHE_DIR}/weather.json")
    aqi_data=$(cat "${CACHE_DIR}/aqi.json")
    moon_data=$(cat "${CACHE_DIR}/moon.json")
    
    # Check if data was retrieved successfully
    if ! echo "$weather_data" | jq -e '.current' > /dev/null 2>&1; then
        echo -e "${RED}Error: Failed to fetch weather data. Please check your internet connection.${NC}"
        return 1
    fi
    
    # Get timezone from response
    local timezone=$(echo "$weather_data" | jq -r '.timezone // "UTC"')
    local current_time=$(TZ="$timezone" date '+%I:%M:%S %p')
    local current_date=$(TZ="$timezone" date '+%A, %B %d, %Y')
    local timezone_abbr=$(TZ="$timezone" date '+%Z')
    
    # Extract current weather
    local current_temp=$(echo "$weather_data" | jq -r '.current.temperature_2m')
    local feels_like=$(echo "$weather_data" | jq -r '.current.apparent_temperature')
    local humidity=$(echo "$weather_data" | jq -r '.current.relative_humidity_2m')
    local pressure=$(echo "$weather_data" | jq -r '.current.pressure_msl')
    local pressure_inhg=$(echo "scale=2; $pressure * 0.02953" | bc)
    local wind_speed=$(echo "$weather_data" | jq -r '.current.wind_speed_10m')
    local wind_direction_deg=$(echo "$weather_data" | jq -r '.current.wind_direction_10m')
    local wind_direction=$(get_wind_direction "$wind_direction_deg")
    local wind_gusts=$(echo "$weather_data" | jq -r '.current.wind_gusts_10m')
    local uv_index=$(echo "$weather_data" | jq -r '.current.uv_index')
    local weather_code=$(echo "$weather_data" | jq -r '.current.weather_code')
    local weather_desc=$(get_weather_description "$weather_code")
    local precipitation=$(echo "$weather_data" | jq -r '.current.precipitation // 0')
    
    # Determine units from API response
    local temp_unit=$(echo "$weather_data" | jq -r '.current_units.temperature_2m // "°C"')
    local wind_unit=$(echo "$weather_data" | jq -r '.current_units.wind_speed_10m // "m/s"')
    
    # Convert temperatures for dual display
    if [[ "$temp_unit" == *"F"* ]]; then
        local temp_f=$current_temp
        local temp_c=$(f_to_c "$current_temp")
        local feels_f=$feels_like
        local feels_c=$(f_to_c "$feels_like")
    else
        local temp_c=$current_temp
        local temp_f=$(c_to_f "$current_temp")
        local feels_c=$feels_like
        local feels_f=$(c_to_f "$feels_like")
    fi
    
    # Extract precipitation probability
    local current_hour=$(TZ="$timezone" date +%H)
    local precip_prob=$(echo "$weather_data" | jq -r ".hourly.precipitation_probability[$current_hour] // 0")
    
    # Extract daily data
    local temp_high=$(echo "$weather_data" | jq -r '.daily.temperature_2m_max[0]')
    local temp_low=$(echo "$weather_data" | jq -r '.daily.temperature_2m_min[0]')
    
    if [[ "$temp_unit" == *"F"* ]]; then
        local temp_high_f=$temp_high
        local temp_low_f=$temp_low
        local temp_high_c=$(f_to_c "$temp_high")
        local temp_low_c=$(f_to_c "$temp_low")
    else
        local temp_high_c=$temp_high
        local temp_low_c=$temp_low
        local temp_high_f=$(c_to_f "$temp_high")
        local temp_low_f=$(c_to_f "$temp_low")
    fi
    
    local precip_prob_max=$(echo "$weather_data" | jq -r '.daily.precipitation_probability_max[0]')
    local uv_max=$(echo "$weather_data" | jq -r '.daily.uv_index_max[0]')
    
    # Extract sunrise/sunset
    local sunrise=$(echo "$weather_data" | jq -r '.daily.sunrise[0]' | awk -F'T' '{print $2}' 2>/dev/null || echo "N/A")
    local sunset=$(echo "$weather_data" | jq -r '.daily.sunset[0]' | awk -F'T' '{print $2}' 2>/dev/null || echo "N/A")
    
    # Extract moon data
    local moonrise=$(echo "$moon_data" | jq -r '.daily.moonrise[0]' | awk -F'T' '{print $2}' 2>/dev/null || echo "N/A")
    local moonset=$(echo "$moon_data" | jq -r '.daily.moonset[0]' | awk -F'T' '{print $2}' 2>/dev/null || echo "N/A")
    local moon_phase=$(echo "$moon_data" | jq -r '.daily.moon_phase[0] // 0')
    local moon_illumination=$(echo "$moon_data" | jq -r '.daily.moon_illumination[0] // 0')
    
    # Extract AQI
    local aqi=$(echo "$aqi_data" | jq -r '.current.us_aqi // .current.european_aqi // "N/A"')
    
    # Display location header
    print_row "Location:" "${BOLD}${WHITE}$DISPLAY${NC}"
    print_row "Coordinates:" "${WHITE}$LAT, $LON${NC}"
    print_row "Population:" "${WHITE}${POPULATION:-Unknown}${NC}"
    print_row "Local Time:" "${BOLD}${WHITE}$current_time $timezone_abbr${NC} - ${WHITE}$current_date${NC}"
    print_row "Timezone:" "${WHITE}$timezone${NC}"
    echo
    
    # Display current conditions
    print_section_header "CURRENT CONDITIONS"
    print_row "Condition:" "${YELLOW}$weather_desc${NC}"
    print_row "Temperature:" "${RED}${temp_f}°F${NC} / ${BLUE}${temp_c}°C${NC}"
    print_row "Feels Like:" "${RED}${feels_f}°F${NC} / ${BLUE}${feels_c}°C${NC}"
    print_row "High/Low:" "${RED}${temp_high_f}°F${NC}/${RED}${temp_low_f}°F${NC} (${BLUE}${temp_high_c}°C${NC}/${BLUE}${temp_low_c}°C${NC})"
    print_row "Rain Chance:" "${WHITE}${precip_prob}% now${NC} (Max today: ${precip_prob_max}%)"
    [ "$precipitation" != "0" ] && print_row "Precipitation:" "${WHITE}${precipitation}mm${NC}"
    echo
    
    # Display detailed conditions
    print_section_header "DETAILED CONDITIONS"
    print_row "Humidity:" "${WHITE}${humidity}%${NC}"
    print_row "Air Pressure:" "${WHITE}${pressure} hPa (${pressure_inhg} inHg)${NC}"
    
    # Display wind with appropriate units
    if [[ "$wind_unit" == "mph" ]]; then
        print_row "Wind:" "${WHITE}${wind_speed} mph from $wind_direction (${wind_direction_deg}°)${NC}"
        [ "$wind_gusts" != "null" ] && print_row "Wind Gusts:" "${WHITE}${wind_gusts} mph${NC}"
    else
        print_row "Wind:" "${WHITE}${wind_speed} m/s from $wind_direction (${wind_direction_deg}°)${NC}"
        [ "$wind_gusts" != "null" ] && print_row "Wind Gusts:" "${WHITE}${wind_gusts} m/s${NC}"
    fi
    
    print_row "UV Index:" "${WHITE}${uv_index}${NC} (Max today: $uv_max)"
    
    # AQI with color coding — proper numeric comparison, not a bracket-glob
    # (a case pattern like [0-50] only matches a single character 0-5,
    # never the number 44, which is why AQI used to show as uncolored
    # "Not Available" for almost every real reading).
    local aqi_color="$NC"
    local aqi_level="Not Available"
    if [[ "$aqi" =~ ^[0-9]+$ ]]; then
        if   [ "$aqi" -le 50 ];  then aqi_color="$GREEN";   aqi_level="Good"
        elif [ "$aqi" -le 100 ]; then aqi_color="$YELLOW";  aqi_level="Moderate"
        elif [ "$aqi" -le 150 ]; then aqi_color="$MAGENTA"; aqi_level="Unhealthy for Sensitive Groups"
        elif [ "$aqi" -le 200 ]; then aqi_color="$RED";     aqi_level="Unhealthy"
        elif [ "$aqi" -le 300 ]; then aqi_color="$RED";     aqi_level="Very Unhealthy"
        else                          aqi_color="$RED";     aqi_level="Hazardous"
        fi
    fi
    print_row "Air Quality:" "${aqi_color}${aqi} ($aqi_level)${NC}"
    echo
    
    # Display astronomical data
    print_section_header "ASTRONOMICAL DATA"
    print_row "Sunrise:" "${WHITE}$sunrise${NC}"
    print_row "Sunset:" "${WHITE}$sunset${NC}"
    print_row "Moonrise:" "${WHITE}$moonrise${NC}"
    print_row "Moonset:" "${WHITE}$moonset${NC}"
    
    # Moon phase interpretation
    local moon_phase_int=$(echo "$moon_phase * 100" | bc | cut -d. -f1)
    local moon_phase_name
    if [ "$moon_phase_int" -le 3 ]; then moon_phase_name="🌑 New Moon"
    elif [ "$moon_phase_int" -le 23 ]; then moon_phase_name="🌒 Waxing Crescent"
    elif [ "$moon_phase_int" -le 27 ]; then moon_phase_name="🌓 First Quarter"
    elif [ "$moon_phase_int" -le 48 ]; then moon_phase_name="🌔 Waxing Gibbous"
    elif [ "$moon_phase_int" -le 52 ]; then moon_phase_name="🌕 Full Moon"
    elif [ "$moon_phase_int" -le 73 ]; then moon_phase_name="🌖 Waning Gibbous"
    elif [ "$moon_phase_int" -le 77 ]; then moon_phase_name="🌗 Last Quarter"
    else moon_phase_name="🌘 Waning Crescent"
    fi
    
    print_row "Moon Phase:" "${WHITE}$moon_phase_name${NC}"
    print_row "Illumination:" "${WHITE}${moon_illumination}%${NC}"
    echo
    
    # Footer
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║  Data: Open-Meteo API | GeoNames Database              ║${NC}"
    echo -e "${BOLD}${BLUE}║  Free service - no API key required                    ║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
}

# Function to display database statistics
show_stats() {
    if [ -f "$CITIES_DB" ]; then
        local size
        size=$(du -h "$CITIES_DB" | cut -f1)
        python3 -c "
import sqlite3, datetime
con = sqlite3.connect('$CITIES_DB')
meta = dict(con.execute('SELECT key, value FROM meta').fetchall())
total = meta.get('total_cities', '?')
last_updated = meta.get('last_updated')
created = datetime.datetime.fromtimestamp(int(last_updated)).isoformat() if last_updated else 'unknown'
print(f'\033[0;36mDatabase Stats: {total} cities, $size, last updated {created}\033[0m')
"
        echo
    fi
}

# Main script execution
main() {
    # Check dependencies
    check_dependencies
    
    # Initialize cache
    init_cache
    
    # Show header
    clear
    echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${BLUE}║     🌍 WORLDWIDE WEATHER - ALL CITIES DATABASE 🌍      ║${NC}"
    echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Handle special commands
    if [ "${1:-}" = "--update" ]; then
        echo -e "${YELLOW}Force updating cities database...${NC}"
        rm -f "$CITIES_DB"
    elif [ "${1:-}" = "--stats" ]; then
        show_stats
        exit 0
    fi
    
    # Download/update cities database if needed
    download_cities_database
    
    # Show database stats
    show_stats

    # Search -> display -> ask to search again, until the user quits
    local selection
    while true; do
        if selection=$(select_city); then
            parse_selection "$selection"
            record_recent_city

            clear
            display_weather || true

            echo
            local again
            read -r -p "$(echo -e "${BOLD}Look up another city? [Y/n]:${NC} ")" again
            case "$again" in
                [nN]*)
                    echo -e "${GREEN}Goodbye!${NC}"
                    exit 0
                    ;;
                *)
                    clear
                    ;;
            esac
        else
            echo -e "${YELLOW}No city selected. Exiting.${NC}"
            exit 0
        fi
    done
}

# Run main function
main "$@"