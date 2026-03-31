# acm-check.sh

A single-command diagnostic tool for troubleshooting AWS ACM certificate issues. Checks DNS delegation, CAA records, CNAME validation, live certificates, and domain registration in one pass.

## Requirements

- `bash`, `dig`, `openssl`, `whois` (pre-installed on most macOS/Linux systems)

## Usage

```bash
./acm-check.sh <domain> [acm-cname-record-name]
```

The script will interactively ask for the ACM CNAME validation record name. Press Enter to skip if you don't have it.

### Examples

```bash
# Basic — will prompt for CNAME
./acm-check.sh example.com

# With CNAME validation record
./acm-check.sh example.com _abc123.example.com
```

## What It Checks

| Check | What it tells you |
|---|---|
| NS Records | Whether the domain is properly delegated and to which nameservers |
| A / AAAA / CNAME | Basic DNS resolution for the domain |
| TXT Records | General DNS inspection |
| CAA Records | Whether Amazon CAs are authorized to issue certs (walks up the domain hierarchy) |
| ACM CNAME Validation | Whether the `_<token>` CNAME correctly points to `*.acm-validations.aws` |
| `dig +trace` | Full delegation path to spot misconfigurations |
| Live SSL Certificate | Issuer, SANs, expiry, and whether it's Amazon-issued |
| WHOIS | Registrar info and domain registration expiry |

## Common Scenarios

- **ACM cert stuck in "Pending validation"** — run the script and check the ACM CNAME Validation section
- **CAA blocking issuance** — look for the `Amazon CA NOT found in CAA` warning
- **DNS managed outside Route 53** — the NS Records section will flag if DNS is delegated elsewhere (e.g., Cloudflare)
- **Cert expired or not Amazon-issued** — the Live Certificate section shows issuer and days until expiry
