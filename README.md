# Fleet Policy Retry Controller

An intelligent automation tool that automatically retries failed Fleet policy automations (scripts and software installations) on non-compliant hosts using exponential backoff strategies.

## ✨ Features

- **Intelligent Retry Logic**: Exponential backoff scheduling (30min → 2h → 6h → 24h)
- **Dual Automation Support**: Handles both script execution and software installation automations  
- **Team & Policy Filtering**: Process specific teams or exclude certain policies
- **Safe Testing**: Dry run mode to preview actions before execution
- **Comprehensive Logging**: Detailed statistics and progress tracking
- **Production Ready**: Built-in rate limiting and error handling

## 🔧 Requirements

- **bash** 4.0 or later
- **curl** for API communications
- **jq** for JSON processing
- **Fleet API** access with valid token

## 📦 Installation

1. **Clone the repository:**
```bash
git clone https://github.com/AdamBaali/fleet-policy-retry.git
cd fleet-policy-retry
```

2. **Make the script executable:**
```bash
chmod +x fleet-retry-controller.sh
```

3. **Configure your Fleet credentials:**
```bash
# Edit these variables in fleet-retry-controller.sh
FLEET_URL="https://your-fleet-instance.com"
FLEET_TOKEN="your-api-token"
```

## 🚀 Usage

### Basic Usage

```bash
# Preview what would be retried (recommended first step)
./fleet-retry-controller.sh --dry-run

# Execute retries
./fleet-retry-controller.sh
```

### Command Line Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview actions without executing |
| `--verbose, -v` | Enable verbose logging |
| `--teams=LIST` | Process specific teams (comma-separated) |
| `--exclude-policies=LIST` | Skip specific policies (comma-separated) |
| `--max-retries=N` | Set retry limit (default: 3) |
| `--log-file=FILE` | Write logs to file |
| `--help, -h` | Show help message |
| `--version` | Show version information |

### Examples

```bash
# Safe preview mode
./fleet-retry-controller.sh --dry-run --verbose

# Process only production teams
./fleet-retry-controller.sh --teams="Production,Critical"

# Exclude specific policies
./fleet-retry-controller.sh --exclude-policies="Legacy Policy,Test Policy"

# Full logging to file
./fleet-retry-controller.sh --log-file=/var/log/fleet-retry.log --verbose
```

## ⚙️ How It Works

The script implements intelligent exponential backoff to prevent overwhelming systems:

| Retry Attempt | Wait Time | Description |
|---------------|-----------|-------------|
| 1st retry | 30 minutes | Quick recovery for transient issues |
| 2nd retry | 2 hours | Allow for longer system recovery |
| 3rd retry | 6 hours | Extended wait for persistent issues |
| 4th+ retry | 24 hours | Daily attempts for stubborn failures |

After reaching the maximum retry count (default: 3), hosts require manual intervention.

## 🔄 Management & Maintenance

### Resetting Retry Tracking

To reset all retry tracking and start fresh:
```bash
rm -f $HOME/.fleet_retry_cache.db
```

### Monitoring

The script provides comprehensive statistics including:
- Teams and policies processed
- Scripts and software installations triggered  
- Hosts skipped due to backoff or retry limits
- API errors encountered

## 🔍 Troubleshooting

| Issue | Solution |
|-------|----------|
| **API errors** | Verify Fleet URL and token are correct |
| **Script/software issues** | Check that scripts and software packages exist in Fleet |
| **Network issues** | Ensure connectivity between script host and Fleet server |
| **Permission errors** | Verify API token has sufficient permissions |

### Debug Mode

For detailed troubleshooting information:
```bash
./fleet-retry-controller.sh --verbose --dry-run
```

## 📝 License

MIT License - see [LICENSE](LICENSE) file for details.

## 🤝 Support

Built for [Fleet Device Management](https://fleetdm.com/)

For issues and feature requests, please use the GitHub issue tracker.
