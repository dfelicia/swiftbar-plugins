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
##   Uses Twelve Data API as primary source, since Nasdaq’s public API is intended
##   for manual/browser access and may block frequent automated curl requests.
##   On any Twelve Data failure (HTTP error, JSON error, or rate-limit), it falls
##   back to Nasdaq. Caches last close for after-hours display.
## -----------------------------------------------------------------------------
# <xbar.title>Stock Price via Twelve Data</xbar.title>
# <xbar.version>v3.0</xbar.version>
# <xbar.author>Don Feliciano</xbar.author>
# <xbar.author.github>dfelicia</xbar.author.github>
# <xbar.desc>Shows stock price for the symbol in the script filename (e.g., aapl.sh → AAPL) using Twelve Data API. Uses is_market_hours for logic and displays $/%, color, and arrow after hours.</xbar.desc>
# <xbar.dependencies>jq,curl</xbar.dependencies>
# <swiftbar.schedule>*/5 * * * *</swiftbar.schedule>
# <swiftbar.hideAbout>false</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>false</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>false</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>false</swiftbar.hideLastUpdated>
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
readonly CACHE_DIR="${HOME}/Library/Caches/com.ameba.SwiftBar/Plugins"
readonly CACHE_FILE="${CACHE_DIR}/${API_SYMBOL}.last"

################################################################################
## Global (mutable) variables used across functions:
##
##   fetched_price       # final “close” price returned by get_quote()
##   fetched_prev        # final “previous close” returned by get_quote()
##
## (All other variables are declared local within their functions.)
################################################################################
declare -g fetched_price
declare -g fetched_prev

IFS=$'\n\t'

## -----------------------------------------------------------------------------
## Function: check_dependencies
##   Verifies that required external commands (jq, curl) are installed.
##   Exits script if any dependency is missing.
## -----------------------------------------------------------------------------
# check_dependencies()
check_dependencies() {
    # Ensure Bash version is 4.3 or newer
    if [[ -z "${BASH_VERSINFO:-}" ]] || ((BASH_VERSINFO[0] < 4)); then
        echo "Error: Bash 4.3 or newer is required." >&2
        exit 1
    fi

    # Ensure readarray builtin is available
    if ! type readarray >/dev/null 2>&1; then
        echo "Error: 'readarray' not found (requires Bash 4+)." >&2
        exit 1
    fi

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
## -----------------------------------------------------------------------------
# error_output(msg, [color])
error_output() {
    local msg=$1 color=${2:-gray}

    echo "${API_SYMBOL} ${msg} | color=${color} font=${FONT} size=${FONTSIZE}"
    return 0
}

## -----------------------------------------------------------------------------
## Function: get_api_key
##   Retrieves the API key from the macOS Keychain using 'security'.
##   Returns the key or exits with failure if not found.
## -----------------------------------------------------------------------------
# get_api_key()
get_api_key() {
    security find-generic-password -a "$USER" -s "twelvedata_api_key" -w 2>/dev/null
    if (($? != 0)); then
        echo "Error: API key not found in Keychain." >&2
        return 1
    fi
    return 0
}

## -----------------------------------------------------------------------------
## Function: get_twelvedata_quote(json_var_name httpcode_var_name)
##   Fetches the JSON quote from the Twelve Data API for the configured symbol.
##   Uses a temporary file to capture the response and HTTP status.
##   Cleans up the temp file on function exit via a RETURN trap.
## -----------------------------------------------------------------------------
# get_twelvedata_quote(json_var_name httpcode_var_name)
get_twelvedata_quote() {
    # Named references to caller's variables
    declare -n json_ref="$1"
    declare -n http_ref="$2"

    local key url tmp
    key=$(get_api_key)
    [[ -z "$key" ]] && return 1

    url="https://api.twelvedata.com/quote?symbol=${API_SYMBOL}&apikey=${key}"
    tmp=$(mktemp) || return 1

    # Ensure temporary file is removed when this function returns
    trap 'rm -f "$tmp"' RETURN

    http_ref=$(curl -4 -sS --max-time "$CURL_TIMEOUT" -o "$tmp" -w "%{http_code}" "$url") || return 1
    json_ref=$(<"$tmp")
    [[ -n "${json_ref}" ]] || return 1

    return 0
}

## -----------------------------------------------------------------------------
# Function: get_nasdaq_quote
#   Fetches the JSON quote from Nasdaq’s quote API for the configured symbol.
#   Uses a temporary file, a standard User-Agent header, and parses JSON fields.
#   Sets global variables:
#     fetched_price        (e.g. "165.53")
#     fetched_prev         (e.g. "164.00")
#   Returns:
#     0 if successful and both values were parsed
#     1 otherwise
# -----------------------------------------------------------------------------
# get_nasdaq_quote()
get_nasdaq_quote() {
    local url tmp_file nasdaq_response
    local sec_close_raw sec_netchange_raw close_raw netchange_raw
    local close_num netchange_num

    url="https://api.nasdaq.com/api/quote/${API_SYMBOL}/info?assetclass=stocks"
    tmp_file=$(mktemp) || return 1
    trap 'rm -f "${tmp_file}"' RETURN

    # Use a browser-like User-Agent so Nasdaq doesn’t block the request, force HTTP/1.1
    if ! nasdaq_response=$(curl -sS --http1.1 \
        -H "Accept: application/json" \
        -H "User-Agent: Mozilla/5.0" \
        -H "Accept-Language: en-US,en;q=0.9" \
        -H "Connection: keep-alive" \
        "${url}"); then
        return 1
    fi

    # Prefer secondaryData for official 4:00 PM close
    sec_close_raw=$(jq -r '.data.secondaryData.lastSalePrice' <<<"${nasdaq_response}")
    sec_netchange_raw=$(jq -r '.data.secondaryData.netChange' <<<"${nasdaq_response}")

    if [[ "${sec_close_raw}" != "null" && -n "${sec_close_raw}" && \
          "${sec_netchange_raw}" != "null" && -n "${sec_netchange_raw}" ]]; then
        close_raw="${sec_close_raw}"
        netchange_raw="${sec_netchange_raw}"
    else
        # Fallback to primaryData if secondaryData unavailable
        close_raw=$(jq -r '.data.primaryData.lastSalePrice' <<<"${nasdaq_response}")
        netchange_raw=$(jq -r '.data.primaryData.netChange' <<<"${nasdaq_response}")
    fi

    # If close or netChange is missing/null, bail out
    if [[ "${close_raw}" == "null" || -z "${close_raw}" || \
          "${netchange_raw}" == "null" || -z "${netchange_raw}" ]]; then
        return 1
    fi

    # Strip non-numeric characters for arithmetic
    close_num=${close_raw//[\$,]/}          # remove '$'
    netchange_num=${netchange_raw//[+\,\-]/} # remove '+', ',', '-'

    # Compute previous close: if netchange was negative, add abs(netchange); else subtract
    fetched_price=$(printf "%s" "${close_num}")
    if [[ "${netchange_raw:0:1}" == "-" ]]; then
        fetched_prev=$(awk "BEGIN { printf \"%.2f\", ${close_num} + ${netchange_num} }")
    else
        fetched_prev=$(awk "BEGIN { printf \"%.2f\", ${close_num} - ${netchange_num} }")
    fi

    # If parsing failed, bail out
    if [[ -z "${fetched_price}" || -z "${fetched_prev}" ]]; then
        return 1
    fi

    return 0
}

## -----------------------------------------------------------------------------
## Function: get_quote(err_var_name)
##   Attempts to fetch stock price and previous close using Twelve Data API.
##   On JSON error or unreachable API, falls back to Nasdaq API.
##   Sets global variables:
##     fetched_price        (e.g. "165.53")
##     fetched_prev         (e.g. "164.00")
##     err_ref             (error message, if both APIs fail)
##   Returns:
##     0 if successful (from either API), 1 otherwise
## -----------------------------------------------------------------------------
# get_quote(err_var_name)
get_quote() {
    # Named reference for err_msg
    declare -n err_ref="$1"
    local td_price td_prev td_json td_http

    if get_twelvedata_quote td_json td_http; then
        # Only attempt parsing if JSON is valid
        if echo "${td_json}" | jq empty >/dev/null 2>&1; then
            if jq -e '.status == "error"' <<<"${td_json}" >/dev/null; then
                err_ref=$(jq -r '.message' <<<"${td_json}")
            else
                td_price=$(jq -r '.close // empty' <<<"${td_json}")
                td_prev=$(jq -r '.previous_close // empty' <<<"${td_json}")
                if [[ -n "${td_price}" && -n "${td_prev}" ]]; then
                    fetched_price="${td_price}"
                    fetched_prev="${td_prev}"
                    return 0
                fi
            fi
        else
            err_ref="Twelve Data returned invalid JSON"
        fi
    else
        err_ref="Twelve Data unreachable"
    fi

    # Fallback to Nasdaq
    if get_nasdaq_quote; then
        # get_nasdaq_quote sets fetched_price and fetched_prev
        return 0
    else
        err_ref="Twelve Data and Nasdaq both failed or returned invalid data"
        return 1
    fi
}

## -----------------------------------------------------------------------------
## Function: is_market_hours
##   Checks current time in Eastern Time (ET) against extended market hours
##   (08:59–16:01 ET Monday–Friday) to allow for slight clock drift.
##   Returns:
##     0 if current ET time is between 08:59 and 16:01 on a weekday
##     1 otherwise
## -----------------------------------------------------------------------------
# is_market_hours()
is_market_hours() {
    local day_of_week_et hour_et minute_et time_et

    # Get day of week in ET (1=Mon ... 7=Sun)
    day_of_week_et=$(TZ="America/New_York" date +%u)
    # If weekend in ET, market is closed
    if ((day_of_week_et >= 6)); then
        return 1
    fi

    # Get hour and minute in ET
    hour_et=$(TZ="America/New_York" date +%H)
    minute_et=$(TZ="America/New_York" date +%M)
    # Convert to HHMM integer for comparison
    time_et=$((10#$hour_et * 100 + 10#$minute_et))

    # Extended market hours: 08:59 (859) to 16:01 (1601)
    if ((time_et >= 859 && time_et <= 1601)); then
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

    printf "%s %s %.2f (\$%.2f / %.2f%%) | color=%s font=%s size=%d\n" \
        "$arrow" "$API_SYMBOL" "$price" "$change" "$pct" \
        "$color" "$FONT" "$FONTSIZE"

    return 0
}

main() {
    local cached_price cached_prev

    check_dependencies

    if is_market_hours; then
        # Market is open: fetch quote
        local change pct color arrow err_msg
        if get_quote err_msg; then
            # Compute change and percent
            change=$(awk "BEGIN { printf \"%.2f\", ${fetched_price} - ${fetched_prev} }")
            if [[ -z "${fetched_prev}" || "${fetched_prev}" == "0" ]]; then
                pct="0.00"
            else
                pct=$(awk "BEGIN { printf \"%.2f\", 100 * (${fetched_price} - ${fetched_prev}) / ${fetched_prev} }")
            fi
            if [[ "${change:0:1}" == "-" ]]; then
                color="red"
                arrow="${ARROW_DOWN}"
            else
                color="green"
                arrow="${ARROW_UP}"
            fi
            format_output "${fetched_price}" "${change}" "${pct}" "${color}" "${arrow}"
            return 0
        else
            # Both APIs failed; show error message
            echo "Error: ${err_msg}" >&2
            error_output "${err_msg}"
            return 0
        fi
    fi

    # Market is closed: use cached values if fresh; otherwise, rebuild cache using
    # Nasdaq’s official closing price (Twelve Data’s “previous_close” can lag behind).
    if [[ -f "${CACHE_FILE}" ]]; then
        # Check if cache is stale: modification time before 16:01 ET today
        local mod_epoch today_et threshold_epoch
        mod_epoch=$(stat -f %m "${CACHE_FILE}")
        today_et=$(TZ="America/New_York" date +'%Y-%m-%d')
        threshold_epoch=$(TZ="America/New_York" date -j -f "%Y-%m-%d %H:%M" "${today_et} 16:01" +%s)
        if ((mod_epoch < threshold_epoch)); then
            # Cache is stale: remove and fetch fresh from Nasdaq for final close
            rm -f "${CACHE_FILE}"
            local err_msg
            if get_nasdaq_quote; then
                # get_nasdaq_quote sets fetched_price & fetched_prev to Nasdaq’s close/prev
                [[ -d "${CACHE_DIR}" ]] || mkdir -p "${CACHE_DIR}"
                printf "%.2f\n%.2f\n" "${fetched_price}" "${fetched_prev}" >"${CACHE_FILE}"
                cached_price="${fetched_price}"
                cached_prev="${fetched_prev}"
            else
                # If Nasdaq fails, fall back to Twelve Data’s previous_close
                if get_quote err_msg; then
                    [[ -d "${CACHE_DIR}" ]] || mkdir -p "${CACHE_DIR}"
                    printf "%.2f\n%.2f\n" "${fetched_price}" "${fetched_prev}" >"${CACHE_FILE}"
                    cached_price="${fetched_price}"
                    cached_prev="${fetched_prev}"
                else
                    # Both APIs failed; show error
                    echo "Error: ${err_msg}" >&2
                    error_output "${err_msg}"
                    return 0
                fi
            fi
        else
            local cached
            readarray -t cached <"${CACHE_FILE}"
            cached_price="${cached[0]}"
            cached_prev="${cached[1]}"
        fi
    else
        local err_msg
        # No cache at all: fetch final close from Nasdaq because Twelve Data may lag
        if get_nasdaq_quote; then
            [[ -d "${CACHE_DIR}" ]] || mkdir -p "${CACHE_DIR}"
            printf "%.2f\n%.2f\n" "${fetched_price}" "${fetched_prev}" >"${CACHE_FILE}"
            cached_price="${fetched_price}"
            cached_prev="${fetched_prev}"
        else
            # If Nasdaq fails, fallback to Twelve Data
            if get_quote err_msg; then
                [[ -d "${CACHE_DIR}" ]] || mkdir -p "${CACHE_DIR}"
                printf "%.2f\n%.2f\n" "${fetched_price}" "${fetched_prev}" >"${CACHE_FILE}"
                cached_price="${fetched_price}"
                cached_prev="${fetched_prev}"
            else
                echo "Error: ${err_msg}" >&2
                error_output "${err_msg}"
                return 0
            fi
        fi
    fi

    if [[ -n "${cached_price}" && -n "${cached_prev}" ]]; then
        local change pct color arrow
        change=$(awk "BEGIN { printf \"%.2f\", ${cached_price} - ${cached_prev} }")
        if [[ -z "${cached_prev}" || "${cached_prev}" == "0" ]]; then
            pct="0.00"
        else
            pct=$(awk "BEGIN { printf \"%.2f\", 100 * (${cached_price} - ${cached_prev}) / ${cached_prev} }")
        fi
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

    # If everything failed, print error but exit 0 to avoid SwiftBar error icon
    error_output "Error fetching ${API_SYMBOL} quote"
}

if (($# == 0)); then
    main
else
    main "$@"
fi
