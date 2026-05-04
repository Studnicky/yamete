# Privacy Policy

**Yamete** is a macOS menu bar app that detects physical impacts on Apple Silicon MacBooks.

## Data Collection

Yamete collects and stores the following data **locally on your Mac only**:

### Activity Logs
- Timestamped sensor and detection events written to the app's log directory (`~/Library/Application Support/Yamete Direct/logs/` for direct downloads, `~/Library/Containers/com.studnicky.yamete/Data/Library/Application Support/Yamete/logs/` for the Mac App Store build)
- Logs may include your Mac's accelerometer serial number
- **Retention: 24 hours** — log files older than 24 hours are automatically deleted
- Logs are never transmitted over the network

### User Preferences
- Detection sensitivity, volume, opacity, frequency band, and device settings
- Stored in macOS UserDefaults (standard app preferences)
- No personally identifiable information

### Device Identifiers
- Core Audio device UIDs (for audio output routing)
- Display IDs (for flash overlay targeting)
- These are hardware identifiers used only for local device selection

## Network Access

Yamete does not make any network connections. All data stays on your Mac.

## No Data Sharing

Yamete does not:
- Collect personal information
- Track usage patterns
- Send data to third parties
- Use advertising identifiers
- Require an account or login

## Contact

For privacy questions: see the [GitHub repository](https://github.com/Studnicky/yamete).
