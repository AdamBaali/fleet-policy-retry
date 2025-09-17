# Fleet Policy Retry Controller

An automated remediation controller for Fleet that intelligently retries failed policy automations (scripts and software installations) on non-compliant hosts with configurable backoff strategies.

## 🚀 Features

- **Smart Retry Logic**: Implements exponential backoff (30min → 2h → 6h → 24h) to avoid overwhelming systems
- **Comprehensive Filtering**: Filter by teams, exclude problematic policies, and configure retry limits
- **Dry Run Mode**: Preview actions before execution
- **Persistent State**: SQLite-like cache tracking retry attempts and timestamps
- **Detailed Logging**: Configurable log levels with optional file output
- **Statistics Tracking**: Real-time metrics on processed hosts, triggered actions, and errors
- **Graceful Error Handling**: Robust API error handling with automatic retries

## 📋 Requirements

- **bash** (4.0+)
- **curl** 
- **jq**
- **Fleet API access** with appropriate permissions

## 🔧 Installation

1. Clone the repository:
```bash
git clone https://github.com/AdamBaali/fleet-policy-retry.git
cd fleet-policy-retry-controller
```

2. Make the script executable:
```bash
chmod +x fleet-retry-controller.sh
```

3. Set up your environment:
```bash
export FLEET_URL="https://your-fleet-instance.com"
export FLEET_TOKEN="your-api-token"
```

## 🚦 Usage

### Basic Usage

```bash
# Preview what would be retried (recommended first run)
./fleet-retry-controller.sh --dry-run

# Execute retries
./fleet-retry-controller.sh

# Verbose logging with file output
./fleet-retry-controller.sh --verbose --log-file=/var/log/fleet-retry.log
```

### Advanced Usage

```bash
# Process only specific teams
./fleet-retry-controller.sh --teams="Production,Staging"

# Exclude problematic policies
./fleet-retry-controller.sh --exclude-policies="Legacy Script,Broken Install"

# Custom retry limits
./fleet-retry-controller.sh --max-retries=5

# Load configuration from file
./fleet-retry-controller.sh --config=./config.env
```

## ⚙️ Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `FLEET_URL` | ✅ | - | Fleet server URL |
| `FLEET_TOKEN` | ✅ | - | Fleet API token |
| `API_SLEEP` | ❌ | `0.3` | Sleep between API calls (seconds) |
| `MAX_RETRIES` | ❌ | `3` | Maximum retry attempts |
| `LOG_LEVEL` | ❌ | `INFO` | Logging level (DEBUG/INFO/WARN/ERROR) |

### Command Line Options

```
--dry-run                    Preview actions without executing
--verbose, -v                Enable verbose logging
--config=FILE                Load configuration from file
--teams=LIST                 Comma-separated team names to process
--exclude-policies=LIST      Comma-separated policy names to exclude
--max-retries=N              Maximum retry attempts
--log-file=FILE              Log to file in addition to stderr
--help, -h                   Show help message
--version                    Show version information
```

### Configuration File Example

```bash
# config.env
FLEET_URL="https://fleet.example.com"
FLEET_TOKEN="your-token-here"
API_SLEEP="0.5"
MAX_RETRIES="5"
LOG_LEVEL="DEBUG"
```

## 🔄 Retry Logic

The controller implements intelligent retry scheduling to prevent system overload:

1. **30 minutes** - First retry (quick resolution for temporary issues)
2. **2 hours** - Second retry (medium-term issues)
3. **6 hours** - Third retry (persistent problems)
4. **24 hours** - Final retry (severe issues)

After reaching `MAX_RETRIES`, hosts are marked as requiring manual intervention.

## 📊 Output & Monitoring

### Statistics Report
```
=== Execution Statistics ===
Teams processed: 5
Policies processed: 23
Hosts processed: 147
Scripts triggered: 42
Software installs triggered: 18
Skipped (backoff): 89
Skipped (max retries): 12
API errors: 2
```

### Log Levels
- **DEBUG**: Detailed execution flow and decision logic
- **INFO**: Standard operations and statistics
- **WARN**: Non-critical issues that should be monitored
- **ERROR**: Critical failures requiring attention

## 🔐 Security Considerations

- Store Fleet tokens securely (consider using environment files or secret management)
- Rotate API tokens regularly
- Monitor log files for sensitive information
- Use least-privilege API tokens when possible

## 🛠️ Troubleshooting

### Common Issues

**API Authentication Errors**
```bash
# Verify token and URL
curl -H "Authorization: Bearer $FLEET_TOKEN" "$FLEET_URL/api/v1/fleet/me"
```

**High API Error Rate**
- Increase `API_SLEEP` value
- Check Fleet server capacity
- Verify network connectivity

**Cache Issues**
```bash
# Reset cache file
rm ~/.fleet_retry_cache.db
```

### Debug Mode
```bash
LOG_LEVEL=DEBUG ./fleet-retry-controller.sh --dry-run
```

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Built for [Fleet Device Management](https://fleetdm.com/)
- Inspired by GitOps and infrastructure automation best practices
---

**⚠️ Disclaimer**: This tool automates Fleet policy remediation. Always test in a non-production environment first and monitor execution closely.
