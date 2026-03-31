#!/usr/bin/env bash
set -uo pipefail

# Colors
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

header() { echo -e "\n${C}═══════════════════════════════════════════════════════════════${N}"; echo -e "${B}  $1${N}"; echo -e "${C}═══════════════════════════════════════════════════════════════${N}"; }
section() { echo -e "\n${Y}── $1 ──${N}"; }
ok() { echo -e "  ${G}✔${N} $1"; }
warn() { echo -e "  ${R}✘${N} $1"; }
info() { echo -e "  ${C}ℹ${N} $1"; }

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <domain> [acm-cname-record-name]"
  echo ""
  echo "Examples:"
  echo "  $0 example.com"
  echo "  $0 example.com _abc123.example.com"
  exit 1
fi

DOMAIN="$1"
ACM_CNAME="${2:-}"

# If no CNAME provided, prompt
if [[ -z "$ACM_CNAME" ]]; then
  echo -e "${Y}Do you have an ACM CNAME validation record name? (e.g. _abc123.example.com)${N}"
  read -rp "Paste it here (or press Enter to skip): " ACM_CNAME
fi

header "ACM Certificate Troubleshooter — $DOMAIN"
echo -e "  Date: $(date)"

# ─── DNS: NS Records ───
section "NS Records"
NS_SHORT=$(dig +short NS "$DOMAIN" +time=5 +tries=1 2>/dev/null || true)
NS_ANSWER=$(dig NS "$DOMAIN" +time=5 +tries=1 2>/dev/null || true)
NS_CNAME=$(echo "$NS_ANSWER" | grep -i 'CNAME' | awk '{print $NF}' || true)
if [[ -n "$NS_SHORT" ]]; then
  echo "$NS_SHORT" | while read -r line; do info "$line"; done || true
  NS_COUNT=$(echo "$NS_SHORT" | wc -l | tr -d ' ')
  ok "$NS_COUNT nameserver(s) found"
elif [[ -n "$NS_CNAME" ]]; then
  warn "NS query returned a CNAME instead of NS records: $NS_CNAME"
  warn "This domain may be delegated to a third-party (e.g. Cloudflare) via CNAME"
  warn "ACM validation records in Route 53 will NOT be queried — add them at the actual DNS provider"
else
  warn "No NS records found — domain may not be delegated or does not exist"
  info "DNS queries are being answered by the parent zone's nameservers"
fi

# Check parent zone NS for context
PARENT_DOMAIN=$(echo "$DOMAIN" | cut -d. -f2-)
if [[ "$PARENT_DOMAIN" == *.* ]]; then
  PARENT_NS=$(dig +short NS "$PARENT_DOMAIN" +time=5 +tries=1 2>/dev/null | head -4 || true)
  if [[ -n "$PARENT_NS" ]]; then
    info "Parent zone ($PARENT_DOMAIN) nameservers:"
    echo "$PARENT_NS" | while read -r line; do info "  $line"; done || true
  fi
fi

# ─── DNS: A / AAAA / CNAME ───
section "A / AAAA / CNAME Records"
A=$(dig +short A "$DOMAIN")
AAAA=$(dig +short AAAA "$DOMAIN")
CNAME=$(dig +short CNAME "$DOMAIN")
[[ -n "$A" ]] && echo "$A" | while read -r line; do info "A: $line"; done || info "A: (none)"
[[ -n "$AAAA" ]] && echo "$AAAA" | while read -r line; do info "AAAA: $line"; done || info "AAAA: (none)"
[[ -n "$CNAME" ]] && info "CNAME: $CNAME" || info "CNAME: (none)"

# ─── DNS: TXT Records ───
section "TXT Records"
TXT=$(dig +short TXT "$DOMAIN")
if [[ -n "$TXT" ]]; then
  echo "$TXT" | while read -r line; do info "$line"; done
else
  info "(none)"
fi

# ─── DNS: CAA Records ───
section "CAA Records (domain + parent domains)"
check_caa() {
  local d="$1"
  while [[ "$d" == *.* ]]; do
    CAA=$(dig +short CAA "$d")
    if [[ -n "$CAA" ]]; then
      echo -e "  ${B}$d:${N}"
      echo "$CAA" | while read -r line; do info "$line"; done
      # Check for Amazon CAs
      if echo "$CAA" | grep -qiE 'amazon\.com|amazontrust\.com|awstrust\.com|amazonaws\.com'; then
        ok "Amazon CA is authorized at $d"
      else
        warn "Amazon CA NOT found in CAA at $d — ACM issuance will be BLOCKED"
        warn "CAA must include one of: amazon.com, amazontrust.com, awstrust.com, amazonaws.com"
      fi
      return
    fi
    d="${d#*.}"
  done
  ok "No CAA records found at any level — no restrictions (any CA can issue)"
}
check_caa "$DOMAIN"

# ─── ACM CNAME Validation Record ───
if [[ -n "$ACM_CNAME" ]]; then
  section "ACM CNAME Validation Record"
  # Strip trailing dot if present for consistency
  ACM_CNAME="${ACM_CNAME%.}"
  # Warn if missing leading underscore
  if [[ "$ACM_CNAME" != _* ]]; then
    warn "CNAME record name should start with an underscore (_)"
    info "Auto-correcting: _$ACM_CNAME"
    ACM_CNAME="_$ACM_CNAME"
  fi
  info "Checking: $ACM_CNAME"
  CNAME_VAL=$(dig +short CNAME "$ACM_CNAME")
  if [[ -n "$CNAME_VAL" ]]; then
    info "Resolves to: $CNAME_VAL"
    if echo "$CNAME_VAL" | grep -qi 'acm-validations\.aws'; then
      ok "CNAME correctly points to *.acm-validations.aws"
      info "Verify this name→value pair matches what ACM shows in the console:"
      info "  Name:  $ACM_CNAME"
      info "  Value: $CNAME_VAL"
      info "Note: If the customer has multiple certs, confirm the value isn't swapped with another domain's CNAME"
    else
      warn "CNAME does NOT point to *.acm-validations.aws — validation will fail"
      warn "Expected target pattern: _<token>.acm-validations.aws."
    fi
  else
    warn "CNAME record NOT FOUND — this is likely why validation is pending/failing"
    info "Customer needs to add this CNAME to their DNS provider"
    info "Verify where DNS is actually resolved (check NS section above) — record may exist in Route 53 but DNS is handled elsewhere"
  fi
fi

# ─── DNS: +trace ───
section "dig +trace (delegation path)"
dig +trace "$DOMAIN" 2>&1 | tail -30

# ─── SSL Certificate (openssl) ───
section "Live Certificate from $DOMAIN:443"
CERT_OUTPUT=$(echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN":443 2>/dev/null)
if [[ -n "$CERT_OUTPUT" ]] && echo "$CERT_OUTPUT" | grep -q 'BEGIN CERTIFICATE'; then
  CERT=$(echo "$CERT_OUTPUT" | openssl x509 -noout -text 2>/dev/null)
  if [[ -n "$CERT" ]]; then
    # Issuer
    ISSUER=$(echo "$CERT_OUTPUT" | openssl x509 -noout -issuer 2>/dev/null | sed 's/issuer=//')
    info "Issuer: $ISSUER"

    # Subject
    SUBJECT=$(echo "$CERT_OUTPUT" | openssl x509 -noout -subject 2>/dev/null | sed 's/subject=//')
    info "Subject: $SUBJECT"

    # SANs
    SANS=$(echo "$CERT" | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ *//')
    info "SANs: $SANS"

    # Validity
    DATES=$(echo "$CERT_OUTPUT" | openssl x509 -noout -dates 2>/dev/null)
    NOT_BEFORE=$(echo "$DATES" | grep notBefore | cut -d= -f2)
    NOT_AFTER=$(echo "$DATES" | grep notAfter | cut -d= -f2)
    info "Valid from: $NOT_BEFORE"
    info "Valid until: $NOT_AFTER"

    # Serial
    SERIAL=$(echo "$CERT_OUTPUT" | openssl x509 -noout -serial 2>/dev/null | cut -d= -f2)
    info "Serial: $SERIAL"

    # Check if Amazon-issued
    if echo "$ISSUER" | grep -qiE 'amazon|awstrust|amazontrust'; then
      ok "Certificate is Amazon/ACM-issued"
    else
      warn "Certificate is NOT Amazon-issued (Issuer: $ISSUER)"
    fi

    # Check expiry
    EXPIRY_EPOCH=$(date -jf "%b %d %T %Y %Z" "$NOT_AFTER" +%s 2>/dev/null || date -d "$NOT_AFTER" +%s 2>/dev/null || echo "")
    NOW_EPOCH=$(date +%s)
    if [[ -n "$EXPIRY_EPOCH" ]]; then
      DAYS_LEFT=$(( (EXPIRY_EPOCH - NOW_EPOCH) / 86400 ))
      if [[ $DAYS_LEFT -lt 0 ]]; then
        warn "Certificate is EXPIRED ($DAYS_LEFT days ago)"
      elif [[ $DAYS_LEFT -lt 30 ]]; then
        warn "Certificate expires in $DAYS_LEFT days"
      else
        ok "Certificate expires in $DAYS_LEFT days"
      fi
    fi
  fi
else
  warn "Could not connect to $DOMAIN:443 or no certificate returned"
  info "The domain may not have HTTPS configured or is not publicly reachable"
fi

# ─── WHOIS ───
section "WHOIS Summary"
WHOIS_OUT=$(whois "$DOMAIN" 2>/dev/null || true)
if [[ -n "$WHOIS_OUT" ]]; then
  echo "$WHOIS_OUT" | grep -iE 'registrar:|creation date|expir|name server|status' | head -15 | while read -r line; do info "$line"; done
  # Check domain expiry
  DOMAIN_EXPIRY=$(echo "$WHOIS_OUT" | grep -i 'expir' | head -1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
  if [[ -n "$DOMAIN_EXPIRY" ]]; then
    D_EXP_EPOCH=$(date -jf "%Y-%m-%d" "$DOMAIN_EXPIRY" +%s 2>/dev/null || date -d "$DOMAIN_EXPIRY" +%s 2>/dev/null || echo "")
    if [[ -n "$D_EXP_EPOCH" && "$D_EXP_EPOCH" -lt "$NOW_EPOCH" ]]; then
      warn "Domain registration appears EXPIRED ($DOMAIN_EXPIRY)"
    fi
  fi
else
  info "WHOIS lookup returned no data"
fi

header "Done"
echo -e "  ${G}All checks complete for ${B}$DOMAIN${N}\n"
