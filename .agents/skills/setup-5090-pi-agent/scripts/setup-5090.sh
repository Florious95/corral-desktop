#!/usr/bin/env bash
set -Eeuo pipefail

# Install and mirror the local Pi runtime into the 5090 WSL distribution.
# The payload is produced by Git archive and streamed over SSH; no SCP and no
# credential-bearing file is ever placed in the payload.

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_ROOT=$(git -C "$SKILL_DIR" rev-parse --show-toplevel)
ENV_FILE="$SKILL_DIR/.env"

usage() {
  cat <<'USAGE'
Usage: setup-5090.sh [options]

  --target HOST         SSH target (default: SETUP_5090_SSH_TARGET or 5090)
  --repo-ref REF        Git ref to archive on the remote (default: env or HEAD)
  --repo-url URL        Git URL used by the remote archive (default: env/origin)
  --smoke-session NAME  Start a new interactive Pi in this tmux session
  --no-global-skills    Do not mirror ~/.agents/skills
  --help                Show this help
USAGE
}

die() {
  printf 'setup-5090-pi-agent: %s\n' "$*" >&2
  exit 1
}

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE; copy the template and fill it locally"
# shellcheck disable=SC1090
set -a
. "$ENV_FILE"
set +a

SSH_TARGET=${SETUP_5090_SSH_TARGET:-5090}
REPO_REF=${SETUP_5090_REPO_REF:-}
REPO_URL=${SETUP_5090_REPO_URL:-}
SMOKE_SESSION=
SYNC_GLOBAL_SKILLS=1

while (($#)); do
  case "$1" in
    --target) [[ $# -ge 2 ]] || die "--target needs a value"; SSH_TARGET=$2; shift 2 ;;
    --repo-ref) [[ $# -ge 2 ]] || die "--repo-ref needs a value"; REPO_REF=$2; shift 2 ;;
    --repo-url) [[ $# -ge 2 ]] || die "--repo-url needs a value"; REPO_URL=$2; shift 2 ;;
    --smoke-session) [[ $# -ge 2 ]] || die "--smoke-session needs a value"; SMOKE_SESSION=$2; shift 2 ;;
    --no-global-skills) SYNC_GLOBAL_SKILLS=0; shift ;;
    --help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n ${TEAM_AGENT_API_KEY:-} ]] || die 'TEAM_AGENT_API_KEY is empty'
[[ -n ${TEAM_AGENT_BASE_URL:-} ]] || die 'TEAM_AGENT_BASE_URL is empty'
[[ "$TEAM_AGENT_BASE_URL" =~ ^https?://[^[:space:]]+$ ]] || die 'TEAM_AGENT_BASE_URL must be an http(s) URL without whitespace'
[[ "$TEAM_AGENT_API_KEY" != *$'\n'* && "$TEAM_AGENT_API_KEY" != *$'\r'* ]] || die 'TEAM_AGENT_API_KEY contains a newline'
if [[ -n "$SMOKE_SESSION" && ! "$SMOKE_SESSION" =~ ^[A-Za-z0-9._-]+$ ]]; then
  die '--smoke-session must contain only letters, numbers, dot, underscore, or hyphen'
fi

if [[ -z "$REPO_REF" ]]; then
  REPO_REF=$(git -C "$PROJECT_ROOT" symbolic-ref --quiet --short HEAD || git -C "$PROJECT_ROOT" rev-parse HEAD)
fi
if [[ -z "$REPO_URL" ]]; then
  REPO_URL=$(git -C "$PROJECT_ROOT" remote get-url origin 2>/dev/null || true)
fi
[[ -n "$REPO_URL" ]] || die 'cannot determine Git origin; pass --repo-url'
git ls-remote --exit-code "$REPO_URL" "$REPO_REF" >/dev/null 2>&1 || die "Git ref is not readable from origin: $REPO_REF"

STAGE="$PROJECT_ROOT/.team/setup-5090-pi-agent-sync.$$.tmp"
REMOTE_HOME=
REMOTE_PAYLOAD=
cleanup() {
  rm -rf -- "$STAGE"
}
trap cleanup EXIT
mkdir -p "$STAGE/payload/extensions" "$STAGE/payload/pi-skills" "$STAGE/payload/global-skills" "$STAGE/payload/agent"

copy_tree() {
  local source=$1 destination=$2
  [[ -d "$source" ]] || return 0
  while IFS= read -r -d '' source_file; do
    local relative basename destination_file
    relative=${source_file#"$source"/}
    basename=${relative##*/}
    case "$basename" in
      # Basename deny-list for personal subscription and credential material.
      # Documentation containing words such as "cursor" remains copyable.
      .DS_Store|.env|auth.json|models-store.json|trust.json|mcp.json|credentials.json|credentials.*|*cursor*auth*|*claude*auth*|*xai*auth*|*openai*auth*|*oauth*|*token*|*credential*|*.pem|*.key|*.p12|*.secret)
        continue
        ;;
    esac
    destination_file="$destination/$relative"
    mkdir -p "$(dirname -- "$destination_file")"
    cp -p -- "$source_file" "$destination_file"
  done < <(find "$source" -type f \
    ! -path '*/.git/*' \
    ! -path '*/node_modules/*' \
    ! -path '*/__pycache__/*' \
    ! -path '*/.cache/*' \
    ! -path '*/sessions/*' \
    -print0)
}

copy_tree "$HOME/.pi/agent/extensions" "$STAGE/payload/extensions"
copy_tree "$HOME/.pi/agent/skills" "$STAGE/payload/pi-skills"
if ((SYNC_GLOBAL_SKILLS)); then
  copy_tree "$HOME/.agents/skills" "$STAGE/payload/global-skills"
fi

# The local extension historically carried a fallback API key. Keep the
# extension logic, but make the portable copy env-only before it enters Git
# archive. The remote env file is the sole credential source.
TEAM_MODELS="$STAGE/payload/extensions/team-agent-models.ts"
if [[ ! -f "$TEAM_MODELS" ]]; then
  cp -p -- "$SKILL_DIR/assets/team-agent-models.ts" "$TEAM_MODELS"
fi
python3 - "$TEAM_MODELS" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
updated, count = re.subn(
    r'(process\.env\.TEAM_AGENT_API_KEY\s*\?\?\s*)["\'][^"\']*["\']',
    r'\1undefined',
    text,
    count=1,
)
if count > 1:
    raise SystemExit("more than one API key fallback found")
if count == 1:
    path.write_text(updated)
PY

# Copy only non-secret JSON configuration. JSON keys that hold credentials are
# omitted recursively; provider credentials are supplied by env at runtime.
copy_json_sanitized() {
  local source=$1 destination=$2
  [[ -f "$source" ]] || return 0
  python3 - "$source" "$destination" <<'PY'
import json
import re
import sys
from pathlib import Path

source, destination = map(Path, sys.argv[1:])
blocked = re.compile(
    r"^(api[_-]?key|token|access[_-]?token|refresh[_-]?token|password|secret|authorization|credentials?)$",
    re.I,
)

def clean(value):
    if isinstance(value, dict):
        return {k: clean(v) for k, v in value.items() if not blocked.fullmatch(k)}
    if isinstance(value, list):
        return [clean(v) for v in value]
    return value

with source.open() as handle:
    value = json.load(handle)
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(clean(value), indent=2, ensure_ascii=False) + "\n")
destination.chmod(0o600)
PY
}

copy_json_sanitized "$HOME/.pi/agent/settings.json" "$STAGE/payload/agent/settings.json"
copy_json_sanitized "$HOME/.pi/agent/models.json" "$STAGE/payload/agent/models.json"
[[ -f "$HOME/.pi/agent/AGENTS.md" ]] && cp -p -- "$HOME/.pi/agent/AGENTS.md" "$STAGE/payload/agent/AGENTS.md"

# Never transfer a credential-shaped literal accidentally added to an
# extension or skill. Do not print the matching file or line.
if grep -RIlE 'sk-[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}' "$STAGE/payload" >/dev/null 2>&1; then
  die 'payload contains credential-shaped content; inspect locally and rerun'
fi

# Git owns the payload manifest and archive creation. The archive is streamed
# over SSH instead of using SCP; credentials are not in this tree.
git -C "$STAGE" init -q
git -C "$STAGE" -c user.name=setup-5090 -c user.email=setup-5090@localhost add payload
git -C "$STAGE" -c user.name=setup-5090 -c user.email=setup-5090@localhost commit -qm setup-5090-pi-payload
ARCHIVE_TREE=$(git -C "$STAGE" rev-parse HEAD^{tree})

REMOTE_HOME=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" 'wsl.exe -e bash -lc "printf %s $HOME"')
REMOTE_HOME=${REMOTE_HOME//$'\r'/}
[[ "$REMOTE_HOME" == /* ]] || die 'remote WSL did not return an absolute HOME'
ARCHIVE_ID="setup-5090-pi-agent-$(date +%Y%m%d%H%M%S)-$$"
REMOTE_PAYLOAD="$REMOTE_HOME/.cache/$ARCHIVE_ID"

printf 'staging Git archive tree %s for %s\n' "$ARCHIVE_TREE" "$SSH_TARGET"
git -C "$STAGE" archive --format=tar HEAD | \
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" \
    "wsl.exe -e bash -lc \"rm -rf '$REMOTE_PAYLOAD' && mkdir -p '$REMOTE_PAYLOAD' && tar -xf - -C '$REMOTE_PAYLOAD'\""

# Values are sent as shell-quoted stdin assignments, never as SSH argv or
# terminal output. The remote shell receives one script and executes it without
# echoing the credential-bearing assignments.
{
  printf 'set -Eeuo pipefail\n'
  printf 'TEAM_AGENT_BASE_URL=%q\nTEAM_AGENT_API_KEY=%q\nREMOTE_PAYLOAD=%q\nSMOKE_SESSION=%q\n' \
    "$TEAM_AGENT_BASE_URL" "$TEAM_AGENT_API_KEY" "$REMOTE_PAYLOAD" "$SMOKE_SESSION"
  printf 'export TEAM_AGENT_BASE_URL TEAM_AGENT_API_KEY REMOTE_PAYLOAD SMOKE_SESSION\n'
  cat <<'REMOTE_SCRIPT'
set -Eeuo pipefail

fail() {
  printf 'remote setup failed: %s\n' "$*" >&2
  exit 1
}

[[ "$REMOTE_PAYLOAD" == "$HOME/.cache/"* ]] || fail 'payload path outside WSL cache'
trap 'rm -rf -- "$REMOTE_PAYLOAD"' EXIT
umask 077

AGENT_DIR="$HOME/.pi/agent"
BACKUP="$HOME/.cache/setup-5090-pi-agent-$(date +%Y%m%d%H%M%S)-backup"
mkdir -p "$AGENT_DIR" "$HOME/.agents" "$BACKUP"

# Personal subscription stores are never copied into the payload or backup.
# Remove known stores on the target so repeated runs cannot leave them behind.
remove_personal_auth() {
  local path config_dir
  for path in \
    "$AGENT_DIR/auth.json" "$AGENT_DIR/models-store.json" \
    "$AGENT_DIR/credentials.json" "$AGENT_DIR/oauth.json" \
    "$AGENT_DIR/token.json" "$AGENT_DIR/tokens.json" \
    "$HOME/.cursor/auth.json" "$HOME/.cursor/credentials.json" \
    "$HOME/.config/cursor/auth.json" "$HOME/.config/cursor/credentials.json" \
    "$HOME/.claude/auth.json" "$HOME/.claude/credentials.json" \
    "$HOME/.config/claude/auth.json" "$HOME/.config/claude/credentials.json" \
    "$HOME/.config/xai/auth.json" "$HOME/.config/xai/credentials.json" \
    "$HOME/.config/openai/auth.json" "$HOME/.config/openai/credentials.json"; do
    rm -rf -- "$path"
  done
  for config_dir in "$HOME/.cursor" "$HOME/.claude" "$HOME/.config/cursor" "$HOME/.config/claude" "$HOME/.config/xai" "$HOME/.config/openai"; do
    if [[ -d "$config_dir" ]]; then
      find "$config_dir" -type f \( \
        -iname 'auth.json' -o -iname 'models-store.json' -o \
        -iname 'credentials.json' -o -iname 'oauth.json' -o \
        -iname 'token.json' -o -iname 'tokens.json' \
      \) -delete 2>/dev/null || true
    fi
  done
}
remove_personal_auth
for path in extensions skills settings.json models.json AGENTS.md env; do
  if [[ -e "$AGENT_DIR/$path" ]]; then cp -a -- "$AGENT_DIR/$path" "$BACKUP/"; fi
done
if [[ -d "$HOME/.agents/skills" ]]; then cp -a -- "$HOME/.agents/skills" "$BACKUP/global-skills"; fi
# Existing managed trees predate this gate; prune known auth stores and
# credential-shaped literals from the private backup as well.
find "$BACKUP" -type f \( \
  -iname 'auth.json' -o -iname 'models-store.json' -o \
  -iname 'credentials.json' -o -iname 'oauth.json' -o \
  -iname 'token.json' -o -iname 'tokens.json' \
\) -delete 2>/dev/null || true
while IFS= read -r -d '' backup_file; do
  if grep -IqE 'sk-[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|(OPENAI|XAI|ANTHROPIC)_API_KEY[[:space:]]*=' "$backup_file"; then
    rm -f -- "$backup_file"
  fi
done < <(find "$BACKUP" -type f -print0)

PAYLOAD="$REMOTE_PAYLOAD/payload"
[[ -d "$PAYLOAD/extensions" ]] || fail 'extension payload missing'
rm -rf -- "$AGENT_DIR/extensions" "$AGENT_DIR/skills"
cp -a -- "$PAYLOAD/extensions" "$AGENT_DIR/extensions"
[[ -d "$PAYLOAD/pi-skills" ]] && cp -a -- "$PAYLOAD/pi-skills" "$AGENT_DIR/skills"
if [[ -d "$PAYLOAD/global-skills" ]]; then
  rm -rf -- "$HOME/.agents/skills"
  cp -a -- "$PAYLOAD/global-skills" "$HOME/.agents/skills"
fi
for name in settings.json models.json AGENTS.md; do
  if [[ -f "$PAYLOAD/agent/$name" ]]; then cp -p -- "$PAYLOAD/agent/$name" "$AGENT_DIR/$name"; fi
done
# Rewrite Mac home prefixes in copied JSON package paths for the WSL user.
for json_file in "$AGENT_DIR/settings.json" "$AGENT_DIR/models.json"; do
  if [[ -f "$json_file" ]]; then
    python3 - "$json_file" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
value = json.loads(path.read_text())
root = os.path.expanduser("~")
mac_prefix = re.compile(r"/Users/[^/]+/(\\.pi/agent|\\.agents)")

def adapt(item):
    if isinstance(item, dict):
        return {key: adapt(val) for key, val in item.items()}
    if isinstance(item, list):
        return [adapt(val) for val in item]
    if isinstance(item, str):
        return mac_prefix.sub(lambda match: root + "/" + match.group(1), item)
    return item

adapted = adapt(value)
# Force Pi's default route to the Team Agent provider; official provider
# credentials are deliberately absent and official API env vars are unset.
if path.name == "settings.json" and isinstance(adapted, dict):
    adapted["defaultProvider"] = "team-agent"
    adapted["defaultModel"] = "gpt-5.6-luna"
    packages = adapted.get("packages")
    if isinstance(packages, list):
        # This package is a macOS-only desktop bridge and makes Pi abort
        # while loading Linux settings. Keep all other user packages.
        adapted["packages"] = [
            package for package in packages
            if "codex-computer-use-mcp" not in json.dumps(package).lower()
        ]
path.write_text(json.dumps(adapted, indent=2, ensure_ascii=False) + "\n")
PY
  fi
done

# The env file is the only deployed credential-bearing file and is private.
ENV_PATH="$AGENT_DIR/env"
printf 'export TEAM_AGENT_BASE_URL=%q\nexport TEAM_AGENT_API_KEY=%q\n' \
  "$TEAM_AGENT_BASE_URL" "$TEAM_AGENT_API_KEY" > "$ENV_PATH"
chmod 600 "$ENV_PATH"

# Idempotent login/interactive-shell hooks. Existing shells are not altered;
# new tmux windows and panes source the env automatically.
HOOK_START='# setup-5090-pi-agent: begin'
HOOK_END='# setup-5090-pi-agent: end'
ensure_hook() {
  local file=$1
  touch "$file"
  python3 - "$file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
start = "# setup-5090-pi-agent: begin"
end = "# setup-5090-pi-agent: end"
block = (start + "\n"
         "export PATH=\"$HOME/.local/bin:$PATH\"\n"
         "unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY\n"
         "if [ -f \"$HOME/.pi/agent/env\" ]; then . \"$HOME/.pi/agent/env\"; fi\n"
         "unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY\n"
         + end + "\n")
text = path.read_text() if path.exists() else ""
pattern = re.compile(r"(?ms)^" + re.escape(start) + r"\n.*?^" + re.escape(end) + r"\n?")
if pattern.search(text):
    text = pattern.sub(block, text, count=1)
else:
    text = text.rstrip("\n") + "\n\n" + block
path.write_text(text)
PY
}
ensure_hook "$HOME/.bashrc"
ensure_hook "$HOME/.profile"

# Purge any pre-existing personal stores again in case a managed directory
# contained one, then enforce the hard exclusion and literal-content gates.
remove_personal_auth
while IFS= read -r -d '' forbidden; do
  fail 'forbidden credential file remains under .pi/agent'
done < <(find "$AGENT_DIR" -type f \( \
  -iname 'auth.json' -o -iname 'models-store.json' -o \
  -iname 'credentials.json' -o -iname 'oauth.json' -o \
  -iname 'token.json' -o -iname 'tokens.json' \
\) -print0)
while IFS= read -r -d '' candidate; do
  if grep -IqE 'sk-[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|(OPENAI|XAI|ANTHROPIC)_API_KEY[[:space:]]*=' "$candidate"; then
    fail 'personal subscription literal found in synced Pi files'
  fi
done < <(find "$AGENT_DIR" -type f ! -path "$ENV_PATH" -print0)
for startup_file in "$HOME/.bashrc" "$HOME/.profile"; do
  grep -Fq 'unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY' "$startup_file" \
    || fail 'single-egress unset hook missing'
done
[[ ! -e "$AGENT_DIR/auth.json" && ! -e "$AGENT_DIR/models-store.json" ]] \
  || fail 'forbidden Pi auth store remains'

# Use a WSL-local npm config. A Windows npm prefix in ~/.npmrc is invalid
# inside WSL and may also carry unrelated user configuration.
NPM_CONFIG_USERCONFIG="$HOME/.cache/setup-5090-pi-agent-npmrc"
mkdir -p "$HOME/.cache"
printf 'prefix=%s\n' "$HOME/.local" > "$NPM_CONFIG_USERCONFIG"
chmod 600 "$NPM_CONFIG_USERCONFIG"
export NPM_CONFIG_USERCONFIG

# Resolve nvm if present, then install the official Pi package for this user.
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # Avoid nvm's implicit auto-use when the user's npmrc has a Windows
    # prefix; select the active version explicitly below.
    export NVM_NO_USE=1
    . "$NVM_DIR/nvm.sh"
    unset NVM_NO_USE
    if command -v nvm >/dev/null 2>&1; then
      active_node=$(nvm current)
      if [[ "$active_node" != 'none' && "$active_node" != 'system' ]]; then
        nvm use --delete-prefix "$active_node" --silent >/dev/null
      fi
    fi
  fi
fi
# Apply the WSL-local global prefix only after any nvm loading.
export npm_config_prefix="$HOME/.local"
export PATH="$HOME/.local/bin:$PATH"
command -v node >/dev/null 2>&1 || fail 'node is not installed in WSL'
command -v npm >/dev/null 2>&1 || fail 'npm is not installed in WSL'
npm install -g @earendil-works/pi-coding-agent --no-audit --no-fund >/dev/null
command -v pi >/dev/null 2>&1 || fail 'pi command was not installed'
pi --version >/dev/null 2>&1 || fail 'pi --version failed'
printf 'Pi install: pass\n'

# Verify model discovery without writing output to the terminal. The env file
# is sourced explicitly so this also validates the credential path.
MODEL_CHECK="$HOME/.cache/setup-5090-pi-agent-models.$$.out"
chmod 600 "$MODEL_CHECK" 2>/dev/null || true
if ( unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY; . "$ENV_PATH"; unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY; pi --list-models >"$MODEL_CHECK" 2>/dev/null ); then
  rm -f -- "$MODEL_CHECK"
  printf 'Pi model discovery: pass\n'
else
  rm -f -- "$MODEL_CHECK"
  fail 'pi --list-models failed; credentials/API endpoint were not accepted'
fi

if [[ -n "$SMOKE_SESSION" ]]; then
  command -v tmux >/dev/null 2>&1 || fail 'tmux is not installed in WSL'
  if tmux has-session -t "$SMOKE_SESSION" 2>/dev/null; then
    fail "smoke session already exists: $SMOKE_SESSION"
  fi
  tmux new-session -d -s "$SMOKE_SESSION" "bash -lc 'unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY; source \"$ENV_PATH\"; unset OPENAI_API_KEY XAI_API_KEY ANTHROPIC_API_KEY; exec pi'"
  tmux has-session -t "$SMOKE_SESSION" 2>/dev/null || fail 'smoke session did not stay alive'
  printf 'Pi smoke session: pass (%s)\n' "$SMOKE_SESSION"
fi

# Pi may materialize auth stores while discovering models; remove and audit
# once more after all Pi/npm activity, including an optional smoke session.
remove_personal_auth
while IFS= read -r -d '' forbidden; do
  fail 'forbidden credential file remains under .pi/agent'
done < <(find "$AGENT_DIR" -type f \( \
  -iname 'auth.json' -o -iname 'models-store.json' -o \
  -iname 'credentials.json' -o -iname 'oauth.json' \
\) -print0)
while IFS= read -r -d '' candidate; do
  if [[ "$candidate" == "$ENV_PATH" ]]; then continue; fi
  if grep -IqE 'sk-[A-Za-z0-9]{20,}|Bearer[[:space:]]+[A-Za-z0-9._-]{20,}|(OPENAI|XAI|ANTHROPIC)_API_KEY[[:space:]]*=' "$candidate"; then
    fail 'personal subscription literal found after Pi setup'
  fi
done < <(find "$AGENT_DIR" -type f -print0)

printf 'Pi configuration sync: pass\n'
printf 'Backup: %s\n' "$BACKUP"
REMOTE_SCRIPT
} | ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_TARGET" 'wsl.exe -e bash -s'

printf '5090 Pi setup complete; credentials were not printed.\n'
