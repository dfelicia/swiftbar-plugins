#!/usr/bin/env bash
# <xbar.title>SSH Dropdown Menu for iTerm</xbar.title>
# <xbar.version>v2.0</xbar.version>
# <xbar.author>Don Feliciano</xbar.author>
# <xbar.author.github>dfelicia</xbar.author.github>
# <xbar.desc>Open a new iTerm tab and then ssh to the selected host.</xbar.desc>
# <xbar.dependencies>iTerm2,awk,osascript,ssh,~/.ssh/config</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
# <swiftbar.hideSwiftBar>true</swiftbar.hideSwiftBar>

# --- Configuration ---
readonly SSH_CONFIG_FILE="${HOME}/.ssh/config"
readonly FONT="SF Pro Text"
readonly FONTSIZE=13

# --- Functions ---

# Prints the main menu bar item.
print_menu_bar() {
    echo "SSH | font=${FONT} size=${FONTSIZE}"
    echo "---"
}

# Prints a menu item for a server.
# Args:
#   $1: Label to display.
#   $2: Host to SSH to.
print_server_item() {
    local label="$1"
    local server="$2"
    echo "${label} | bash='$0' param1=ssh param2='${server}' terminal=false font=${FONT} size=${FONTSIZE}"
}

# Prints all servers from ssh config, skipping 'Host *'.
print_all_servers() {
    local script_path="$0"
    while read -r line; do
        # Only process lines starting with 'Host ' (with a space), skip 'Host *'
        if [[ "$line" =~ ^Host[[:space:]]+ && ! "$line" =~ ^Host[[:space:]]+\* ]]; then
            # Remove 'Host ' and split remaining line into hosts
            local hosts
            IFS=' ' read -r -a hosts <<<"${line#Host }"
            for host in "${hosts[@]}"; do
                print_server_item "${host}" "${host}"
            done
        fi
    done <"${SSH_CONFIG_FILE}"
}

# Opens iTerm and runs SSH command.
# Args:
#   $1: Host to SSH to.
open_iterm_ssh() {
    local server="$1"

    if osascript -e 'application "iTerm" is running' >/dev/null; then
        # iTerm is running, open a new tab and bring to front.
        osascript >/dev/null <<EOF
tell application "iTerm"
  reopen
  activate
  tell current window
    create tab with default profile command "ssh ${server}"
  end tell
end tell
EOF
    else
        # Launch iTerm and run SSH in a new window.
        osascript >/dev/null <<EOF
tell application "iTerm"
  reopen
  activate
  create window with default profile command "ssh ${server}"
end tell
EOF
    fi
}

# --- Main Logic ---

# If called with 'ssh' param, open iTerm and SSH, then exit.
if [[ "$1" == "ssh" && -n "$2" ]]; then
    open_iterm_ssh "$2"
    exit 0
fi

# Otherwise, print the menu.
print_menu_bar
print_all_servers
echo "---"
