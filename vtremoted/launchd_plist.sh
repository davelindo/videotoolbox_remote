#!/usr/bin/env bash
set -euo pipefail

label=$1
stdout_log=$2
stderr_log=$3
shift 3

xml_string() {
  local value="$1"
  value=${value//&/'&amp;'}
  value=${value//</'&lt;'}
  value=${value//>/'&gt;'}
  printf '    <string>%s</string>\n' "$value"
}

printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict>' '<key>Label</key>'
xml_string "$label"
printf '%s\n' '<key>ProgramArguments</key><array>'
for argument in "$@"; do xml_string "$argument"; done
printf '%s\n' '</array>' '<key>RunAtLoad</key><true/>' '<key>KeepAlive</key><true/>' '<key>StandardOutPath</key>'
xml_string "$stdout_log"
printf '%s\n' '<key>StandardErrorPath</key>'
xml_string "$stderr_log"
printf '%s\n' '</dict></plist>'
