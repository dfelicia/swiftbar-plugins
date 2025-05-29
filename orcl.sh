#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# SCRIPT: orcl.sh
# PURPOSE: SwiftBar plugin to display the latest stock price for the symbol
#          (derived from the script filename) using the Twelve Data API.
#          Handles market-open vs. closed logic, error and rate-limit fallbacks,
#          and caches the last close price after market hours.
# -----------------------------------------------------------------------------
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

## -----------------------------------------------------------------------------
## MAIN ENTRY POINT
##   Orchestrates dependency checks, API fetch, error handling, and output.
## -----------------------------------------------------------------------------
main() {
    check_dependencies

    if ! get_twelvedata_quote; then
        error_output "N/A" gray 1
        return 1
    fi

    # HTTP error handling
    if ((http_code >= 500)); then
        error_output "API down" gray 1
        return 0
    fi
    if ((http_code == 401 || http_code == 429)); then
        error_output "Rate or plan limit" red 0
        return 0
    fi
    if ((http_code != 200)); then
        error_output "HTTP ${http_code}" red 1
        return 1
    fi

    # JSON-level error
    if jq -e '.status=="error"' <<<"$json_body" >/dev/null; then
        err_msg=$(jq -r '.message' <<<"$json_body")
        error_output "$err_msg" red 1
        return 1
    fi

    is_market_open=$(jq -r '.is_market_open' <<<"$json_body")
    price=$(jq -r '.close // 0' <<<"$json_body")
    prev_close=$(jq -r '.previous_close // 0' <<<"$json_body")

    price_fmt=$(printf '%.2f' "$price")

    # If market is open, use API's change/pct fields
    if [[ $is_market_open == "true" ]]; then
        change=$(jq -r '.change // 0' <<<"$json_body")
        pct=$(jq -r '.percent_change // 0' <<<"$json_body")
        change_fmt=$(printf '%.2f' "$change")
        pct_fmt=$(printf '%.2f' "$pct")
        if [[ ${change:0:1} == '-' ]]; then
            color=red
            arrow=$ARROW_DOWN
        else
            color=green
            arrow=$ARROW_UP
        fi
        echo "$(format_output "$price_fmt" "$change_fmt" "$pct_fmt" "$color" "$arrow")"
        return 0
    fi

    # Market is closed: calculate $/%, color, arrow from .close and .previous_close
    if [[ -n "$prev_close" && "$prev_close" != "0" ]]; then
        change=$(awk "BEGIN { printf \"%.2f\", $price - $prev_close }")
        pct=$(awk "BEGIN { printf \"%.2f\", 100 * ($price - $prev_close) / $prev_close }")
        # Determine arrow direction based on change, but use gray color for closed market
        if (($(awk "BEGIN {print ($change < 0)}"))); then
            arrow=$ARROW_DOWN
        else
            arrow=$ARROW_UP
        fi
        color=gray
        echo "$(format_output "$price_fmt" "$change" "$pct" "$color" "$arrow")"
        return 0
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
