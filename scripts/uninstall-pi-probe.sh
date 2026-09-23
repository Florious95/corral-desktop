#!/bin/sh
set -eu

# Remove only AgentMirror-owned probe paths. Do not remove user-created Pi
# extensions, plugins, state records, or parent directories.
home=${HOME:?HOME is required}
rm -rf -- "$home/.pi/agent/plugins/agentmirror-probe"
rm -f -- \
  "$home/.pi/agent/plugins/agentmirror-probe.js" \
  "$home/.pi/agent/extensions/nodeprobe-pi-activity.js" \
  "$home/.pi/agent/extensions/agentmirror-probe.js"

# Clean interrupted atomic writes without touching unrelated files.
find "$home/.pi/agent/plugins" "$home/.pi/agent/extensions" \
  -maxdepth 1 -type f -name '.agentmirror-probe.tmp-*' -exec rm -f -- {} + 2>/dev/null || true
