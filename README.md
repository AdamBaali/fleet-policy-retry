# Fleet Policy Retry Controller

A script that automatically retries failed policy automations (scripts and software installations) on non-compliant hosts in Fleet.

## Features

- Intelligent retry scheduling with exponential backoff (30min → 2h → 6h → 24h)
- Supports both script execution and software installation automations
- Filtering options for teams and policies
- Dry run mode to preview actions
- Detailed logging and statistics

## Requirements

- bash 4.0+
- curl
- jq
- Fleet API access

## Installation

1. Clone the repository:
```bash
git clone https://github.com/AdamBaali/fleet-policy-retry.git
cd fleet-policy-retry
```

2. Make the script executable:
```bash
chmod +x fleet-retry-final.sh
```

3. Edit the script to set your Fleet credentials:
```bash
# Edit these variables in fleet-retry-final.sh
FLEET_URL="https://your-fleet-instance.com"
FLEET_TOKEN="your-api-token"
```

## Usage

### Basic Usage

```bash
# Preview what would be retried
./fleet-retry-final.sh --dry-run

# Execute retries
./fleet-retry-final.sh
```

### Options

```
--dry-run                    Preview without executing
--verbose, -v                Enable verbose logging
--teams=LIST                 Process specific teams
--exclude-policies=LIST      Skip specific policies
--max-retries=N              Set retry limit (default: 3)
--log-file=FILE              Write logs to file
--help, -h                   Show help message
--version                    Show version
```

## Retry Logic

The script implements exponential backoff to prevent overwhelming systems:

1. First retry: 30 minutes
2. Second retry: 2 hours
3. Third retry: 6 hours
4. Subsequent retries: 24 hours

After reaching the maximum retry count (default: 3), hosts require manual intervention.

## Resetting Backoff

To reset all retry tracking:
```bash
rm -f $HOME/.fleet_retry_cache.db
```

## Troubleshooting

- **API errors**: Verify your Fleet URL and token are correct
- **Script/software issues**: Check that scripts and software packages exist in Fleet
- **Network issues**: Ensure connectivity between the machine running the script and Fleet server

For detailed debugging:
```bash
./fleet-retry-final.sh --verbose
```

## License

MIT License

---

Built for [Fleet Device Management](https://fleetdm.com/)
