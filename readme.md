# SwiftBar Stock Price Plugin (Twelve Data)

This SwiftBar plugin displays the stock price, change, and percent change for any symbol using the [Twelve Data API](https://twelvedata.com/).
**The symbol is determined by the script filename:**
For example, `aapl.sh` will show Apple (AAPL), `orcl.sh` will show Oracle (ORCL), etc.

![SwiftBar ORCL Example](images/orcl-example.png)

## Requirements

- [SwiftBar](https://swiftbar.app/)
  Install via Homebrew:
  ```bash
  brew install --cask swiftbar
  ```
- [`jq`](https://stedolan.github.io/jq/) (for JSON parsing)
  Install via Homebrew:
  ```bash
  brew install jq
  ```
- **A free [Twelve Data API key](https://twelvedata.com/)**
  Sign up at [twelvedata.com](https://twelvedata.com/) to get your API key.

---

**Proxy Note:**
If your environment requires a proxy to access the internet, you will need to configure `curl` accordingly.
You can do this by updating your `~/.curlrc` file. For example, add the following lines to `~/.curlrc`:

```
proxy = "http://your-proxy-host:port"
proxy-user = "username:password"
```

Adjust these settings as needed for your proxy configuration.

---

## Usage

1. **Copy and Rename the Script**

   Copy the script to your SwiftBar plugins folder and rename it to match the symbol you want (lowercase or uppercase, `.sh` extension required):

   ```bash
   cp orcl.sh aapl.sh   # For Apple
   cp orcl.sh msft.sh   # For Microsoft
   ```

2. **Set Up Your Twelve Data API Key**

   Store your Twelve Data API key securely in your macOS Keychain:

   ```bash
   security add-generic-password -a "$USER" -s "twelvedata_api_key" -w "<YOUR_API_KEY>"
   ```

   Replace `<YOUR_API_KEY>` with your actual Twelve Data API key.

   - To update the key, run the same command with the new key.
   - To delete the key:

     ```bash
     security delete-generic-password -a "$USER" -s "twelvedata_api_key"
     ```

3. **Reload SwiftBar**

   SwiftBar will automatically pick up the new script and display the price for the symbol in the filename.

4. **Live Fetch Only**

   This version of the plugin fetches the latest price from the API on every run. Caching has been removed, so the displayed value is always live. If the API call fails or returns an error, the plugin will show “N/A” or an appropriate error indicator.

   **Closed Market Styling:** When the market is closed, the plugin displays the price and arrow in gray. The arrow (△ or ▽) still reflects whether the current price is above or below the previous close.


---

**Note:**
- No need to edit the script to change the symbol—just rename the file!

# SSH Dropdown Menu for iTerm (ssh.sh)

This SwiftBar plugin creates a dropdown menu of all your SSH hosts (from `~/.ssh/config`).
Clicking a host opens a new iTerm tab (or window) and connects via SSH.

## Usage

1. **Copy the Script**

   Place `ssh.sh` in your SwiftBar plugins directory.

2. **Configure Your SSH Hosts**

   Make sure your SSH hosts are defined in `~/.ssh/config`, for example:

   ```
   Host myserver
     HostName myserver.example.com
     User alice

   Host devbox
     HostName 192.168.1.100
     User bob
   ```

   The plugin will list all hosts except wildcards (`Host *`).

3. **Requirements**

   - [iTerm2](https://iterm2.com/) must be installed.
   - Your SSH config file should be at `~/.ssh/config`.
   - The script uses `osascript` (AppleScript) to control iTerm.

4. **How it Works**

   - The menu bar will show "SSH".
   - Clicking a host in the dropdown opens a new iTerm tab (or window if iTerm is not running) and runs `ssh <host>`.

---

**Tip:**
If iTerm is minimized or hidden, the script will bring it to the foreground before opening the new tab or window.