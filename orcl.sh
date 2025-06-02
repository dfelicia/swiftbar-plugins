#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# SCRIPT: orcl.sh
# PURPOSE: SwiftBar plugin to display the latest stock price for the symbol
#          (derived from the script filename) using the Twelve Data API.
#          Handles market-open vs. closed logic, error and rate-limit fallbacks,
#          and caches the last close price after market hours.
# -----------------------------------------------------------------------------
## -----------------------------------------------------------------------------
## Overview:
##   Tries Twelve Data first; on any failure (HTTP error, JSON error, rate-limit), falls back to Nasdaq. Caches last close for after-hours display.
## -----------------------------------------------------------------------------
# <xbar.title>Stock Price via Twelve Data</xbar.title>
# <xbar.version>v3.0</xbar.version>
# <xbar.author>Don Feliciano</xbar.author>
# <xbar.author.github>dfelicia</xbar.author.github>
# <xbar.desc>Shows stock price for the symbol in the script filename (e.g., aapl.sh → AAPL) using Twelve Data API. Uses .is_market_open for logic and displays $/%, color, and arrow after hours.</xbar.desc>
# <xbar.dependencies>jq,curl</xbar.dependencies>
# <swiftbar.schedule>*/5 * * * *</swiftbar.schedule>
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>false</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>

set -o pipefail
umask 077 # secure cache files

## -----------------------------------------------------------------------------
## Configuration constants
## -----------------------------------------------------------------------------
readonly FONT="SF Pro Text"
readonly FONTSIZE=13
readonly ARROW_UP="△"
readonly ARROW_DOWN="▽"
readonly API_SYMBOL_RAW="$(basename "$0" .sh)"
readonly API_SYMBOL="${API_SYMBOL_RAW^^}"
readonly CURL_TIMEOUT=10

IFS=$'\n\t'

## -----------------------------------------------------------------------------
## Function: check_dependencies
##   Verifies that required external commands (jq, curl) are installed.
##   Exits script if any dependency is missing.
## -----------------------------------------------------------------------------
# check_dependencies()
check_dependencies() {
    local dep
    for dep in jq curl; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo "Error: '$dep' is required but not installed." >&2
            exit 1
        fi
    done
}

## -----------------------------------------------------------------------------
## Function: error_output
##   Prints an error or status message with appropriate styling for SwiftBar.
##   Arguments:
##     $1 - message text
##     $2 - text color (default: gray)
##     $3 - exit code (default: 1)
## -----------------------------------------------------------------------------
# error_output(msg, [color], [exit_code])
error_output() {
    local msg=$1 color=${2:-gray} exit_code=${3:-1}
    echo "${API_SYMBOL} ${msg} | color=${color} font=${FONT} size=${FONTSIZE}"
    return "$exit_code"
}

## -----------------------------------------------------------------------------
## Function: get_api_key
##   Retrieves the API key from the macOS Keychain using 'security'.
##   Returns the key or exits with failure if not found.
## -----------------------------------------------------------------------------
# get_api_key()
get_api_key() {
    security find-generic-password -a "$USER" -s "twelvedata_api_key" -w 2>/dev/null
}

## -----------------------------------------------------------------------------
## Function: get_twelvedata_quote
##   Fetches the JSON quote from the Twelve Data API for the configured symbol.
##   Uses a temporary file to capture the response and HTTP status.
##   Cleans up the temp file on function exit via a RETURN trap.
## -----------------------------------------------------------------------------
# get_twelvedata_quote()
get_twelvedata_quote() {
    local key url tmp
    key=$(get_api_key)
    [[ -z "$key" ]] && return 1

    url="https://api.twelvedata.com/quote?symbol=${API_SYMBOL}&apikey=${key}"
    tmp=$(mktemp) || return 1
    # Ensure temporary file is removed when this function returns,
    # regardless of success or error.
    trap 'rm -f "$tmp"' RETURN

    http_code=$(curl -4 -sS --max-time "$CURL_TIMEOUT" -o "$tmp" -w "%{http_code}" "$url") || return 1
    json_body=$(<"$tmp")
    [[ -n "$json_body" ]] || return 1

    return 0
}

## -----------------------------------------------------------------------------
## Function: get_nasdaq_quote
##   Fetches the JSON quote from Nasdaq’s quote API for the configured symbol.
##   Uses a temporary file, a standard User-Agent header, and parses JSON fields.
##   Sets global variables:
##     nasdaq_price        (e.g. "165.53")
##     nasdaq_prev_close   (e.g. "164.00")
##   Returns:
##     0 if successful and both price and prev_close were parsed
##     1 otherwise
## -----------------------------------------------------------------------------
# get_nasdaq_quote()
get_nasdaq_quote() {
  local url tmp_file res close_raw prev_raw

  url="https://api.nasdaq.com/api/quote/${API_SYMBOL}/info?assetclass=stocks"
  tmp_file=$(mktemp) || return 1
  trap 'rm -f "${tmp_file}"' RETURN

  # Use a browser-like User-Agent so Nasdaq doesn’t block the request, force HTTP/1.1, and add extra headers to avoid INTERNAL_ERROR
  if ! res=$(curl -sS --http1.1 -H "Accept: application/json" -H "User-Agent: Mozilla/5.0" -H "Accept-Language: en-US,en;q=0.9" -H "Connection: keep-alive" "${url}"); then
    return 1
  fi

  # Parse "lastSalePrice" (e.g. "$165.53") and "PreviousClose" (e.g. "$164.00")
  close_raw=$(jq -r '.data.primaryData.lastSalePrice' <<<"$res")
  prev_raw=$(jq -r '.data.keyStats.PreviousClose.value' <<<"$res")

  # Strip non-numeric characters (dollar sign, commas) to leave plain decimal
  nasdaq_price=${close_raw//[\$,]/}
  nasdaq_prev_close=${prev_raw//[\$,]/}

  # Ensure we parsed something reasonable
  if [[ -z "${nasdaq_price}" || -z "${nasdaq_prev_close}" ]]; then
    return 1
  fi

  return 0
}

## -----------------------------------------------------------------------------
## Function: is_market_hours
##   Checks current time in Eastern Time (ET) against extended market hours
##   (08:58–16:02 ET Monday–Friday) to allow for slight clock drift.
##   Returns:
##     0 if current ET time is between 08:58 and 16:02 on a weekday
##     1 otherwise
## -----------------------------------------------------------------------------
# is_market_hours()
is_market_hours() {
  local day_of_week_et hour_et minute_et time_et

  # Get day of week in ET (1=Mon ... 7=Sun)
  day_of_week_et=$(TZ="America/New_York" date +%u)
  # If weekend in ET, market is closed
  if (( day_of_week_et >= 6 )); then
    return 1
  fi

  # Get hour and minute in ET
  hour_et=$(TZ="America/New_York" date +%H)
  minute_et=$(TZ="America/New_York" date +%M)
  # Convert to HHMM integer for comparison
  time_et=$((10#$hour_et * 100 + 10#$minute_et))

  # Extended market hours: 08:58 (858) to 16:02 (1602)
  if (( time_et >=  858 && time_et <= 1602 )); then
    return 0
  fi

  return 1
}

## -----------------------------------------------------------------------------
## Function: format_output
##   Formats the price, change, and percentage into a SwiftBar output string.
##   Arguments:
##     $1 - current price
##     $2 - absolute change amount
##     $3 - percentage change
##     $4 - text color for output
##     $5 - arrow symbol indicating up/down
## -----------------------------------------------------------------------------
# format_output(price change pct color arrow)
format_output() {
    local price=$1 change=$2 pct=$3 color=$4 arrow=$5
    printf "%s %s %.2f (\$%.2f / %.2f%%) | color=%s font=%s size=%d" \
        "$arrow" "$API_SYMBOL" "$price" "$change" "$pct" \
        "$color" "$FONT" "$FONTSIZE"
}

main() {
  check_dependencies

  # Cache location for after-hours fallback
  CACHE_DIR="${HOME}/.cache/swiftbar-stock"
  CACHE_FILE="${CACHE_DIR}/${API_SYMBOL}.last"

  if is_market_hours; then
    # Market is open: attempt to fetch live data via Twelve Data
    local source_price source_prev change pct color arrow

    if get_twelvedata_quote; then
      # Check HTTP errors first
      if (( http_code >= 500 )); then
        # Twelve Data is down; fallback to Nasdaq
        if get_nasdaq_quote; then
          source_price="${nasdaq_price}"
          source_prev="${nasdaq_prev_close}"
        else
          error_output "N/A" gray 1
          return 1
        fi
      elif (( http_code == 401 || http_code == 429 )); then
        # Rate‐limit or unauthorized; fallback to Nasdaq
        if get_nasdaq_quote; then
          source_price="${nasdaq_price}"
          source_prev="${nasdaq_prev_close}"
        else
          error_output "Rate or plan limit" red 0
          return 0
        fi
      elif (( http_code != 200 )); then
        # Other HTTP error; fallback to Nasdaq
        if get_nasdaq_quote; then
          source_price="${nasdaq_price}"
          source_prev="${nasdaq_prev_close}"
        else
          error_output "HTTP ${http_code}" red 1
          return 1
        fi
      else
        # HTTP 200: check JSON‐level error
        if jq -e '.status == "error"' <<<"${json_body}" >/dev/null; then
          local err_msg
          err_msg=$(jq -r '.message' <<<"${json_body}")
          # API returned error message; fallback to Nasdaq
          if get_nasdaq_quote; then
            source_price="${nasdaq_price}"
            source_prev="${nasdaq_prev_close}"
          else
            error_output "${err_msg}" red 1
            return 1
          fi
        else
          # Successful JSON from Twelve Data: parse fields
          source_price=$(jq -r '.close // 0' <<<"${json_body}")
          source_prev=$(jq -r '.previous_close // 0' <<<"${json_body}")
        fi
      fi
    else
      # Twelve Data fetch failed entirely; fallback to Nasdaq
      if get_nasdaq_quote; then
        source_price="${nasdaq_price}"
        source_prev="${nasdaq_prev_close}"
      else
        error_output "N/A" gray 1
        return 1
      fi
    fi

    # Cache the chosen source's price and prev_close for after hours
    mkdir -p "${CACHE_DIR}"
    printf "%.2f\n%.2f\n" "${source_price}" "${source_prev}" > "${CACHE_FILE}"

    # Compute change and percent, then choose arrow/color
    change=$(awk "BEGIN { printf \"%.2f\", ${source_price} - ${source_prev} }")
    pct=$(awk "BEGIN { printf \"%.2f\", 100 * (${source_price} - ${source_prev}) / ${source_prev} }")

    change=$(printf '%.2f' "${change}")
    pct=$(printf '%.2f' "${pct}")

    if [[ "${change:0:1}" == "-" ]]; then
      color="red"
      arrow="${ARROW_DOWN}"
    else
      color="green"
      arrow="${ARROW_UP}"
    fi

    # Finally, output via format_output
    format_output "${source_price}" "${change}" "${pct}" "${color}" "${arrow}"
    return 0
  fi

  # Market is closed: try to use cached values
  if [[ -f "${CACHE_FILE}" ]]; then
    readarray -t cached < "${CACHE_FILE}"
    cached_price="${cached[0]}"
    cached_prev="${cached[1]}"
    if [[ -n "${cached_price}" && -n "${cached_prev}" ]]; then
      change=$(awk "BEGIN { printf \"%.2f\", ${cached_price} - ${cached_prev} }")
      pct=$(awk "BEGIN { printf \"%.2f\", 100 * (${cached_price} - ${cached_prev}) / ${cached_prev} }")
      if [[ "${change:0:1}" == "-" ]]; then
        arrow="${ARROW_DOWN}"
        color="red"
      else
        arrow="${ARROW_UP}"
        color="green"
      fi
      format_output "${cached_price}" "${change}" "${pct}" "${color}" "${arrow}"
      return 0
    fi
  fi

  # Ultimate fallback
  error_output "N/A" gray 1
  return 1
}

if (($# == 0)); then
  main
else
  main "$@"
fi
