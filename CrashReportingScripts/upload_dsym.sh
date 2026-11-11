#!/usr/bin/env bash
#
# upload_dsym.sh
#
# Upload a .dSYM (or Android mapping.txt) zip to the QM crash-analytics
# symbols endpoint.
#
# Endpoint (per Crash Reporting PRD page 8, "Customer → Ingest"):
#   PUT https://api.quantummetric.com/crash-analytics/symbols/v1/[:uuid]
#       ?app_id=<app_id>&app_version=<app_version>&sub=<sub>&platform=<platform>
#   Authorization: Api-key <key>
#
#   The `sub` query param (optional) is the customer's QM subscription. The
#   backend uses it only to route the upload to that subscription's home
#   region (auto-forwarding non-US uploads to the correct region); when it is
#   omitted the upload is processed in whatever region receives it (US by
#   default). Omitting it for a non-US subscription can store the symbols in
#   the wrong region so crashes never symbolicate — set it when you can. This
#   mirrors the Android Gradle plugin's `sub`/QM_SUB support (QP-26136).
#
# ASSUMPTIONS / DIVERGENCES from the PRD (call out before relying on this):
#
#   1. Path-style: the PRD writes the symbols path as /crashanalytics/symbols/...
#      (no dashes). The live crash-report endpoint uses /crash-analytics/
#      crash-report/... (with dashes). We assume the symbols endpoint follows
#      the same dashed convention.
#
#   2. Auth scheme: the PRD shows "Authorization: Api-key xyz" for the symbols
#      PUT. The live crash-report GET uses "Bearer <token>". This script
#      defaults to the PRD's Api-key form but can be switched via
#      QM_AUTH_SCHEME=bearer to test against a Bearer-token deployment.
#
#   3. The PRD lists the path param as :uuid with the comment "unclear if
#      helpful, would be useful if customers ever want to validate they
#      uploaded something". In practice the server enforces it differently
#      per platform: iOS requires a valid UUID (rejects with 400 "uuid is
#      required" if missing); Android lets the server auto-generate one if
#      omitted. This script mirrors that — for iOS, you can either pass the
#      UUID explicitly or omit it and we'll extract it via dwarfdump from the
#      .dSYM bundle inside the zip (uploads once per arch in a multi-slice
#      dSYM). Android-without-UUID is passed through as-is.
#
#   4. PRD validation rules enforced here client-side as a courtesy:
#        - file must be a .zip (warn only)
#        - file must be < 2 GB (warn only — server returns 413)
#      Server-side rules (411 if no Content-Length, 413 if too large, 400 if
#      missing required params) are not duplicated here.
#
# Usage:
#   ./upload_dsym.sh <zip_file> <app_id> <app_version> <platform> [<api_key>] [<dsym_uuid>] [<sub>]
#
# Example (iOS):
#   ./upload_dsym.sh \
#       ~/Desktop/MyApp.app.dSYM.zip \
#       com.example.myapp \
#       2.7.1 \
#       ios \
#       "$QM_API_KEY"
#
# Example (Android):
#   ./upload_dsym.sh \
#       ~/Desktop/mapping.zip \
#       com.example.myapp \
#       2.7.1 \
#       android \
#       "$QM_API_KEY"
#
# Environment overrides:
#   QM_CRASH_ANALYTICS_HOST  default: api.quantummetric.com
#   QM_API_KEY               if set, used when no key arg is given
#   QM_AUTH_SCHEME           "api-key" (default) or "bearer"
#   QM_SUB                   subscription; used when no sub arg (7) is given
#
set -euo pipefail

usage() {
    cat >&2 <<EOF
Usage: $0 <zip_file> <app_id> <app_version> <platform> [<api_key>] [<dsym_uuid>] [<sub>]

  zip_file       path to .zip containing the dSYM bundle or Android mapping.txt
  app_id         e.g. com.example.myapp
  app_version    e.g. 2.7.1
  platform       ios | android
  api_key        optional if \$QM_API_KEY is set in env
  dsym_uuid      iOS: optional — if omitted, extracted from the dSYM inside
                 the zip via dwarfdump (one upload per arch slice).
                 Android: optional (server auto-generates one if omitted)
  sub            optional — the QM subscription you init the SDK with. Routes
                 the upload to that subscription's home region; if omitted the
                 upload lands in whatever region receives it (US by default).
                 Falls back to \$QM_SUB. Pass "" to skip it while giving a UUID.

Environment:
  QM_CRASH_ANALYTICS_HOST  override host (default: api.quantummetric.com)
  QM_AUTH_SCHEME           "api-key" (PRD default) or "bearer"
  QM_SUB                   subscription; used when no sub arg (7) is given
EOF
    exit 64
}

# URL-encode a query-string value (RFC 3986). The query is otherwise built by
# plain interpolation, so an app_id, app_version, or sub containing a space or
# a reserved char (e.g. "acme corp", or a value with & / =) would produce a
# malformed URL: curl would then see a truncated/garbled value or spurious
# extra params, and the backend could route the dSYM to the wrong region so
# crashes never symbolicate. Mirrors the Ruby uploader's URI.encode_www_form;
# the only cosmetic difference is space -> %20 here vs + there, both of which
# the server decodes to a space.
#
# LC_ALL=C forces byte-wise iteration so multibyte UTF-8 encodes correctly
# (each byte -> %XX). The `& 0xFF` masks bash 3.2's sign-extension of high
# bytes (0x80-0xFF otherwise come back negative and print as %FFFFFF..).
urlencode() {
    local LC_ALL=C string=$1 i c out=
    for (( i = 0; i < ${#string}; i++ )); do
        c=${string:i:1}
        case "$c" in
            [a-zA-Z0-9.~_-]) out+=$c ;;
            *) printf -v c '%%%02X' "$(( $(printf '%d' "'$c") & 0xFF ))"; out+=$c ;;
        esac
    done
    printf '%s' "$out"
}

if [[ $# -lt 4 ]]; then
    usage
fi

zip_file=$1
app_id=$2
app_version=$3
platform=$4
api_key=${5:-${QM_API_KEY:-}}
dsym_uuid=${6:-}
# No colon in ${7-...}: an explicitly-passed empty arg 7 must be honored as
# "skip sub" (see usage: 'Pass "" to skip it while giving a UUID'). With the
# colon form (${7:-...}) an empty arg 7 is indistinguishable from unset, so a
# caller trying to skip sub would still inherit $QM_SUB and route to the wrong
# region. Only a genuinely-absent arg 7 falls back to $QM_SUB.
sub=${7-${QM_SUB:-}}

if [[ ! -f "$zip_file" ]]; then
    echo "error: zip file not found: $zip_file" >&2
    exit 66
fi

if [[ -z "$app_id" ]]; then
    echo "error: app_id must be non-empty" >&2
    exit 64
fi

if [[ -z "$app_version" ]]; then
    echo "error: app_version must be non-empty" >&2
    exit 64
fi

if [[ "$zip_file" != *.zip ]]; then
    echo "warning: file does not have .zip extension (PRD requires .zip)" >&2
fi

# 2 GB = 2147483648 bytes (PRD: "under 2 gb (best guess, can be adjusted)").
file_size=$(stat -f%z "$zip_file" 2>/dev/null || stat -c%s "$zip_file")
if (( file_size >= 2147483648 )); then
    echo "warning: file is ${file_size} bytes (>= 2 GB); server will return 413" >&2
fi

if [[ -z "$api_key" ]]; then
    echo "error: api key required (arg 5 or \$QM_API_KEY)" >&2
    exit 64
fi

case "$platform" in
    ios|android) ;;
    *) echo "error: platform must be 'ios' or 'android' (got '$platform')" >&2; exit 64 ;;
esac

host=${QM_CRASH_ANALYTICS_HOST:-api.quantummetric.com}
auth_scheme=${QM_AUTH_SCHEME:-api-key}

case "$auth_scheme" in
    api-key)    auth_header="authorization: Api-key ${api_key}" ;;
    bearer)     auth_header="authorization: Bearer ${api_key}" ;;
    *)          echo "error: QM_AUTH_SCHEME must be 'api-key' or 'bearer'" >&2; exit 64 ;;
esac

# Resolve the UUID list to upload under.
#   - explicit arg given       → use as-is, one upload
#   - iOS + no arg             → extract every UUID from the zip's dSYM, one upload per arch
#   - Android + no arg         → empty string, server auto-generates a UUID
uuids=()
if [[ -n "$dsym_uuid" ]]; then
    uuids=("$dsym_uuid")
elif [[ "$platform" == "ios" ]]; then
    tmp_dir=$(mktemp -d -t qm_dsym_extract)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp_dir'" EXIT

    if ! ditto -x -k "$zip_file" "$tmp_dir" 2>/dev/null; then
        echo "error: failed to unzip $zip_file for UUID extraction" >&2
        exit 65
    fi

    # Strip macOS AppleDouble cruft (`._<name>` siblings and `__MACOSX/`)
    # that ride along when a dSYM is zipped from Finder or tarred without
    # COPYFILE_DISABLE=1. Left in place, dwarfdump finds no UUID in them
    # (they're 4 KiB resource-fork blobs, not Mach-O), and the backend
    # — which unpacks the same zip — would index them under bogus UUIDs.
    appledouble_count=$(find "$tmp_dir" \( -name '._*' -o -type d -name '__MACOSX' \) 2>/dev/null | wc -l | tr -d ' ')
    if (( appledouble_count > 0 )); then
        echo "warning: $zip_file contains ${appledouble_count} AppleDouble entries (._*, __MACOSX/). Filtering them locally for UUID extraction, but the uploaded zip still contains them. Re-zip with 'COPYFILE_DISABLE=1 zip -r out.zip Foo.dSYM' or 'ditto -c -k --sequesterRsrc Foo.dSYM out.zip' to keep the backend's symbol index clean." >&2
    fi
    find "$tmp_dir" -name '._*' -delete 2>/dev/null || true
    find "$tmp_dir" -type d -name '__MACOSX' -exec rm -rf {} + 2>/dev/null || true

    binaries=()
    while IFS= read -r line; do
        binaries+=("$line")
    done < <(find "$tmp_dir" -type f -path '*.dSYM/Contents/Resources/DWARF/*' ! -name '._*')

    if (( ${#binaries[@]} == 0 )); then
        echo "error: no DWARF binary found inside $zip_file (expected <Name>.dSYM/Contents/Resources/DWARF/<Name>)" >&2
        exit 65
    fi

    for binary in "${binaries[@]}"; do
        while IFS= read -r line; do
            # `dwarfdump --uuid` output: "UUID: <uuid> (<arch>) <path>"
            uid=$(echo "$line" | awk '{print $2}')
            [[ -n "$uid" ]] && uuids+=("$uid")
        done < <(dwarfdump --uuid "$binary" 2>/dev/null | grep '^UUID:')
    done

    if (( ${#uuids[@]} == 0 )); then
        echo "error: dwarfdump found no UUIDs in $zip_file" >&2
        exit 65
    fi

    echo "extracted ${#uuids[@]} UUID(s) from $zip_file:" >&2
    for u in "${uuids[@]}"; do echo "  $u" >&2; done
else
    # Android with no UUID → empty path segment, server generates one.
    uuids=("")
fi

base_url="https://${host}/crash-analytics/symbols/v1/"

# The `sub` (subscription) query param is optional. When set, the backend
# routes the upload to that subscription's home region; when omitted, the
# upload is handled in whatever region receives it (US by default). We only
# append it when non-empty, and mirror the query-param order the Android
# uploader uses: app_id, app_version, sub, platform.
if [[ -z "$sub" ]]; then
    echo "warning: sub is not set. Pass it as arg 7 or via \$QM_SUB using the subscription you init the SDK with. Without it, symbols for a non-US subscription may upload to the wrong region and crashes may not symbolicate." >&2
fi
query="?app_id=$(urlencode "$app_id")&app_version=$(urlencode "$app_version")"
if [[ -n "$sub" ]]; then
    query+="&sub=$(urlencode "$sub")"
fi
query+="&platform=$(urlencode "$platform")"

# Tally across all uploads in this run. Exit non-zero if any upload fails so
# CI / Fastlane wrappers can branch on $?. Per-upload status lines are written
# to stderr (machine-parseable: "PUT URL\n  OK HTTP 200 ...").
overall_exit=0
successes=0
failures=0

# Body of curl response goes to a tempfile so we can show it on failure
# without interleaving with our own status lines. Single cleanup function
# covers both this tempfile and the iOS-branch extraction dir (set earlier
# in the script when we needed to unzip for dwarfdump). Trap is replaced —
# bash doesn't stack EXIT traps.
body_file=$(mktemp -t qm_resp_body)
cleanup() {
    rm -f "$body_file"
    [[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"
}
trap cleanup EXIT

for uid in "${uuids[@]}"; do
    url="${base_url}${uid}${query}"
    echo "PUT ${url}" >&2
    echo "  file:  ${zip_file} (${file_size} bytes)" >&2
    echo "  auth:  ${auth_scheme}" >&2

    # --silent suppresses curl's progress meter; --show-error keeps connection
    # / DNS failures visible. --write-out emits machine-parseable stats AFTER
    # the response body, which we route to a tempfile via --output so the two
    # streams don't tangle. We DROP --fail-with-body because we want to keep
    # going through the multi-UUID loop and report a per-UUID outcome at the
    # end — a 4xx on slice 1 shouldn't suppress slice 2.
    : > "$body_file"
    write_out=$(curl --silent --show-error \
        --write-out "%{http_code} %{size_upload} %{time_total}" \
        --output "$body_file" \
        --request PUT \
        --url "${url}" \
        --header "${auth_header}" \
        --header "content-type: application/zip" \
        --data-binary "@${zip_file}" || true)

    # write_out is "<http_code> <upload_bytes> <time_seconds>". If curl
    # bailed before getting a response (DNS, connection refused), http_code
    # will be "000" and write_out may be empty — handle both.
    http_status="000"
    upload_bytes="0"
    time_total="0"
    if [[ -n "$write_out" ]]; then
        read -r http_status upload_bytes time_total <<< "$write_out"
    fi

    if [[ "$http_status" =~ ^2[0-9][0-9]$ ]]; then
        echo "  OK   HTTP ${http_status}  uploaded=${upload_bytes}B  time=${time_total}s" >&2
        successes=$((successes + 1))
    else
        echo "  FAIL HTTP ${http_status}  uploaded=${upload_bytes}B  time=${time_total}s" >&2
        # Surface the server's response body when something went wrong —
        # that's where "missing or invalid Authorization header", "uuid is
        # required", "app_id must be set" type messages live.
        if [[ -s "$body_file" ]]; then
            echo "  response:" >&2
            sed 's/^/    /' "$body_file" >&2
        fi
        failures=$((failures + 1))
        overall_exit=1
    fi
    echo >&2
done

# Multi-slice summary. For single-UUID uploads the per-UUID line above is
# already the summary, so we'd just be repeating ourselves.
if (( ${#uuids[@]} > 1 )); then
    echo "Summary: ${successes}/${#uuids[@]} uploaded successfully, ${failures} failed" >&2
fi

exit "$overall_exit"
