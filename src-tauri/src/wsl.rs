use serde::Serialize;
#[cfg(windows)]
use std::io::{Read, Write};
#[cfg(windows)]
use std::net::{SocketAddr, TcpStream};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::path::Path;

#[cfg(windows)]
use tauri::{path::BaseDirectory, Manager};

#[cfg(windows)]
const AGENTMIRRORD_RESOURCE: &str = "resources/agentmirrord-linux-amd64";
#[cfg(windows)]
const NODEPROBE_RESOURCE: &str = "resources/nodeprobe-linux-amd64";
#[cfg(any(windows, test))]
const NODEPROBE_SHA256: &str = "61d6dd99e7d7135e20b885b00724fb1359c1643c634857702239a092faa4e958";
const AGENTMIRRORD_NAME: &str = "agentmirrord";
// The bundle revision is part of the WSL marker so upgrading the embedded
// daemon cannot silently reuse a same-semver binary without /pair/whoami.
const AGENTMIRRORD_VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "+whoami-v1");
#[cfg(windows)]
const SERVICE_READY_PORT: u16 = 9900;
#[cfg(any(windows, test))]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const PROVIDERS_TSV: &str = include_str!("../resources/nodeprobe-providers.tsv");
const TITLES_TSV: &str = include_str!("../resources/nodeprobe-titles.tsv");
const PI_PROBE_SOURCE: &str = include_str!("../resources/nodeprobe-pi-activity.js");

/// Snapshot of the WSL 2 environment used by the local AgentMirror daemon.
#[derive(Debug, Default, Serialize, PartialEq, Eq)]
pub struct WslEnvironmentStatus {
    pub wsl_installed: bool,
    pub ubuntu_installed: bool,
    pub ubuntu_running: bool,
    pub tmux_installed: bool,
    pub service_installed: bool,
    pub service_running: bool,
    pub wsl_ip: Option<String>,
}

#[cfg(any(windows, test))]
#[derive(Debug, Clone, PartialEq, Eq)]
struct UbuntuDistribution {
    name: String,
    running: bool,
}

#[cfg(any(windows, test))]
impl UbuntuDistribution {
    fn is_ubuntu(&self) -> bool {
        self.name.eq_ignore_ascii_case("ubuntu")
            || self.name.to_ascii_lowercase().starts_with("ubuntu-")
    }
}

/// Decode the output of `wsl.exe -l -v` without accepting arbitrary error text.
#[cfg(any(windows, test))]
fn decode_wsl_output(output: &[u8]) -> String {
    let nul_high_bytes = output.chunks_exact(2).filter(|pair| pair[1] == 0).count();
    let utf16le = output.starts_with(&[0xff, 0xfe])
        || (output.len() >= 4 && nul_high_bytes >= output.len() / 4);
    if utf16le {
        let offset = usize::from(output.starts_with(&[0xff, 0xfe])) * 2;
        let units: Vec<u16> = output[offset..]
            .chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]]))
            .collect();
        return String::from_utf16_lossy(&units);
    }
    String::from_utf8_lossy(output)
        .trim_start_matches('\u{feff}')
        .to_string()
}

/// Parse the strict `wsl.exe -l -v` table shape.
///
/// Every non-empty line after the header must be a three-column record, or a
/// four-column record with the leading default `*`. This deliberately rejects
/// warnings, error text, missing state/version columns, and WSL 1 records.
#[cfg(any(windows, test))]
fn parse_wsl_table(output: &[u8]) -> Option<Vec<UbuntuDistribution>> {
    let mut distributions = Vec::new();
    let mut saw_header = false;
    for line in decode_wsl_output(output).lines() {
        let fields: Vec<&str> = line
            .trim()
            .trim_start_matches('\u{feff}')
            .split_whitespace()
            .collect();
        if fields.is_empty() {
            continue;
        }
        if fields.len() == 3
            && fields[0] == "NAME"
            && fields[1] == "STATE"
            && fields[2] == "VERSION"
        {
            if saw_header {
                return None;
            }
            saw_header = true;
            continue;
        }
        if !saw_header {
            return None;
        }

        let (name, state, version) = match fields.as_slice() {
            ["*", name, state, version] => (*name, *state, *version),
            [name, state, version] => (*name, *state, *version),
            _ => return None,
        };
        if name.is_empty() || !matches!(state, "Running" | "Stopped") || version != "2" {
            return None;
        }
        distributions.push(UbuntuDistribution {
            name: name.to_string(),
            running: state == "Running",
        });
    }
    (saw_header && !distributions.is_empty()).then_some(distributions)
}

#[cfg(any(windows, test))]
fn find_ubuntu_distribution(output: &[u8]) -> Option<UbuntuDistribution> {
    parse_wsl_table(output)?
        .into_iter()
        .find(UbuntuDistribution::is_ubuntu)
}

#[cfg(any(windows, test))]
fn first_ip(output: &[u8]) -> Option<String> {
    String::from_utf8_lossy(output)
        .split_whitespace()
        .find_map(|candidate| candidate.parse::<std::net::IpAddr>().ok())
        .map(|ip| ip.to_string())
}

#[cfg(any(windows, test))]
fn hidden_command(program: &str) -> std::process::Command {
    let mut command = std::process::Command::new(program);
    #[cfg(windows)]
    command.creation_flags(CREATE_NO_WINDOW);
    command
}

#[cfg(windows)]
fn run_wsl(args: &[&str]) -> Result<std::process::Output, String> {
    hidden_command("wsl.exe")
        .args(args)
        .output()
        .map_err(|error| format!("wsl_unavailable: {error}"))
}

#[cfg(windows)]
fn wsl_stdout(output: std::process::Output, failure: &str) -> Result<String, String> {
    if !output.status.success() {
        return Err(failure.to_string());
    }
    let value = String::from_utf8(output.stdout).map_err(|_| failure.to_string())?;
    let value = value.trim();
    (!value.is_empty() && !value.chars().any(char::is_control))
        .then(|| value.to_string())
        .ok_or_else(|| failure.to_string())
}

#[cfg(windows)]
fn resource_is_usable(path: &Path) -> bool {
    std::fs::metadata(path)
        .map(|metadata| metadata.is_file() && metadata.len() > 0)
        .unwrap_or(false)
}

#[cfg(any(windows, test))]
fn install_script() -> String {
    format!(
        r#"set -eu
src="$1"
nodeprobe_src="$2"
dst="$HOME/.local/bin/{AGENTMIRRORD_NAME}"
nodeprobe_dst="$HOME/.local/bin/nodeprobe"
version_file="$dst.version"
providers="$HOME/tools/nodeprobe/fixtures/providers.tsv"
titles="$HOME/tools/nodeprobe/fixtures/titles.tsv"
# Keep the compatibility plugin path and the canonical Pi extension path.
probe_dir="$HOME/.pi/agent/plugins/agentmirror-probe"
probe="$probe_dir/index.js"
extensions_dir="$HOME/.pi/agent/extensions"
extension="$extensions_dir/nodeprobe-pi-activity.js"
if test -x "$dst" \
    && test -f "$version_file" \
    && test "$(cat "$version_file")" = "{AGENTMIRRORD_VERSION}" \
    && test -x "$nodeprobe_dst" \
    && test "$(sha256sum "$nodeprobe_dst" | awk '{{print $1}}')" = "{NODEPROBE_SHA256}" \
    && test -s "$providers" \
    && test -s "$titles" \
    && test -f "$probe" \
    && test -f "$extension" \
    && test ! -e "$extensions_dir/agentmirror-probe.js"; then
    exit 0
fi
stop_service() {{
    name="$1"
    if ! pgrep -x "$name" >/dev/null 2>&1; then
        return 0
    fi
    pkill -TERM -x "$name" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x "$name" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.1
    done
    pkill -KILL -x "$name" 2>/dev/null || true
    ! pgrep -x "$name" >/dev/null 2>&1
}}
# Stop both generations before replacing the executable. The legacy name can
# otherwise keep port 9900 occupied when the new daemon is started.
stop_service agentmirrord
stop_service corral-core
mkdir -p "$(dirname "$dst")" "$(dirname "$providers")" "$probe_dir" "$extensions_dir"
chmod 0755 "$HOME/.pi" "$HOME/.pi/agent" "$HOME/.pi/agent/plugins" "$probe_dir" "$extensions_dir"
service_tmp="$dst.tmp.$$"
nodeprobe_tmp="$nodeprobe_dst.tmp.$$"
providers_tmp="$providers.tmp.$$"
titles_tmp="$titles.tmp.$$"
probe_tmp="$probe.tmp.$$"
extension_tmp="$extension.tmp.$$"
version_tmp="$version_file.tmp.$$"
trap 'rm -f "$service_tmp" "$nodeprobe_tmp" "$providers_tmp" "$titles_tmp" "$probe_tmp" "$extension_tmp" "$version_tmp"' EXIT
install -m 0755 -- "$src" "$service_tmp"
mv -f -- "$service_tmp" "$dst"
install -m 0755 -- "$nodeprobe_src" "$nodeprobe_tmp"
mv -f -- "$nodeprobe_tmp" "$nodeprobe_dst"
printf '%s\n' "{AGENTMIRRORD_VERSION}" > "$version_tmp"
chmod 0600 "$version_tmp"
mv -f -- "$version_tmp" "$version_file"
umask 077
printf '%s' {providers} | tr -d '\r' > "$providers_tmp"
mv -f -- "$providers_tmp" "$providers"
printf '%s' {titles} | tr -d '\r' > "$titles_tmp"
mv -f -- "$titles_tmp" "$titles"
printf '%s' {probe_base64} | base64 -d > "$probe_tmp"
test -s "$probe_tmp"
chmod 0644 "$probe_tmp"
mv -f -- "$probe_tmp" "$probe"
printf '%s' {probe_base64} | base64 -d > "$extension_tmp"
test -s "$extension_tmp"
chmod 0644 "$extension_tmp"
mv -f -- "$extension_tmp" "$extension"
# Remove the pre-#212 misnamed extension so Pi cannot load two copies.
rm -f -- "$extensions_dir/agentmirror-probe.js"
test -x "$dst"
test -x "$nodeprobe_dst"
test -s "$providers"
test -s "$titles"
test -d "$probe_dir"
test "$(stat -c '%a' "$probe_dir")" = 755
test -f "$probe"
test "$(stat -c '%a' "$probe")" = 644
test -f "$extension"
test "$(stat -c '%a' "$extension")" = 644
"#,
        providers = shell_single_quote(PROVIDERS_TSV),
        titles = shell_single_quote(TITLES_TSV),
        probe_base64 = base64_encode(PI_PROBE_SOURCE.as_bytes()),
    )
}

#[cfg(any(windows, test))]
fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\r', "").replace('\'', "'\\''"))
}

#[cfg(any(windows, test))]
fn base64_encode(value: &[u8]) -> String {
    const ALPHABET: &[u8; 64] =
        b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut output = String::with_capacity(value.len().div_ceil(3) * 4);
    for chunk in value.chunks(3) {
        let first = chunk[0];
        let second = *chunk.get(1).unwrap_or(&0);
        let third = *chunk.get(2).unwrap_or(&0);
        output.push(ALPHABET[(first >> 2) as usize] as char);
        output.push(ALPHABET[((first & 0x03) << 4 | (second >> 4)) as usize] as char);
        output.push(if chunk.len() > 1 {
            ALPHABET[((second & 0x0f) << 2 | (third >> 6)) as usize] as char
        } else {
            '='
        });
        output.push(if chunk.len() > 2 {
            ALPHABET[(third & 0x3f) as usize] as char
        } else {
            '='
        });
    }
    output
}

#[cfg(windows)]
fn install_wsl_service_windows(app: &tauri::AppHandle) -> Result<(), String> {
    let resource = app
        .path()
        .resolve(AGENTMIRRORD_RESOURCE, BaseDirectory::Resource)
        .map_err(|_| "agentmirrord_resource_unavailable".to_string())?;
    let nodeprobe_resource = app
        .path()
        .resolve(NODEPROBE_RESOURCE, BaseDirectory::Resource)
        .map_err(|_| "nodeprobe_resource_unavailable".to_string())?;
    if !resource_is_usable(&resource) {
        return Err("agentmirrord_resource_unavailable".to_string());
    }
    if !resource_is_usable(&nodeprobe_resource) {
        return Err("nodeprobe_resource_unavailable".to_string());
    }

    let list_output = run_wsl(&["-l", "-v"])?;
    if !list_output.status.success() {
        return Err("ubuntu_not_installed".to_string());
    }
    let ubuntu = find_ubuntu_distribution(&list_output.stdout)
        .ok_or_else(|| "ubuntu_not_installed".to_string())?;
    let windows_path = resource
        .to_str()
        .ok_or_else(|| "agentmirrord_resource_unavailable".to_string())?;
    let linux_path_output = run_wsl(&["-d", &ubuntu.name, "-e", "wslpath", "-u", windows_path])?;
    let linux_path = wsl_stdout(linux_path_output, "agentmirrord_resource_unavailable")?;
    if !linux_path.starts_with('/') || linux_path.contains("\n") {
        return Err("agentmirrord_resource_unavailable".to_string());
    }
    let nodeprobe_windows_path = nodeprobe_resource
        .to_str()
        .ok_or_else(|| "nodeprobe_resource_unavailable".to_string())?;
    let nodeprobe_path_output = run_wsl(&[
        "-d",
        &ubuntu.name,
        "-e",
        "wslpath",
        "-u",
        nodeprobe_windows_path,
    ])?;
    let nodeprobe_linux_path =
        wsl_stdout(nodeprobe_path_output, "nodeprobe_resource_unavailable")?;
    if !nodeprobe_linux_path.starts_with('/') || nodeprobe_linux_path.contains("\n") {
        return Err("nodeprobe_resource_unavailable".to_string());
    }

    let script = install_script();
    let output = run_wsl(&[
        "-d",
        &ubuntu.name,
        "-e",
        "sh",
        "-c",
        &script,
        "agentmirrord-install",
        &linux_path,
        &nodeprobe_linux_path,
    ])?;
    if !output.status.success() {
        return Err("agentmirrord_install_failed".to_string());
    }

    let verify_script = format!(
        "test -x \"$HOME/.local/bin/agentmirrord\" && test -x \"$HOME/.local/bin/nodeprobe\" && test \"$(sha256sum \"$HOME/.local/bin/nodeprobe\" | awk '{{print $1}}')\" = \"{NODEPROBE_SHA256}\" && test \"$(cat \"$HOME/.local/bin/agentmirrord.version\" 2>/dev/null)\" = \"{AGENTMIRRORD_VERSION}\" && test -s \"$HOME/tools/nodeprobe/fixtures/providers.tsv\" && test -f \"$HOME/tools/nodeprobe/fixtures/titles.tsv\""
    );
    let verify = run_wsl(&[
        "-d",
        &ubuntu.name,
        "-e",
        "sh",
        "-lc",
        &verify_script,
    ])?;
    if verify.status.success() {
        Ok(())
    } else {
        Err("agentmirrord_install_verification_failed".to_string())
    }
}

#[cfg(any(windows, test))]
fn service_probe_command(service: &str) -> Option<&'static str> {
    match service {
        "agentmirrord" => Some("command -v agentmirrord >/dev/null"),
        "corral-core" => Some("command -v corral-core >/dev/null"),
        _ => None,
    }
}

#[cfg(windows)]
fn service_command_installed(distribution: &str, service: &str) -> bool {
    let Some(probe) = service_probe_command(service) else {
        return false;
    };
    run_wsl(&["-d", distribution, "-e", "sh", "-lc", probe])
        .map(|output| output.status.success())
        .unwrap_or(false)
}

#[cfg(windows)]
fn bundled_service_current(distribution: &str) -> bool {
    let probe = format!(
        "test -x \"$HOME/.local/bin/{AGENTMIRRORD_NAME}\" && test -x \"$HOME/.local/bin/nodeprobe\" && test \"$(sha256sum \"$HOME/.local/bin/nodeprobe\" | awk '{{print $1}}')\" = \"{NODEPROBE_SHA256}\" && test \"$(cat \"$HOME/.local/bin/{AGENTMIRRORD_NAME}.version\" 2>/dev/null)\" = \"{AGENTMIRRORD_VERSION}\""
    );
    run_wsl(&["-d", distribution, "-e", "sh", "-lc", &probe])
        .map(|output| output.status.success())
        .unwrap_or(false)
}

#[cfg(any(windows, test))]
fn normalize_service_token(output: &[u8]) -> Result<String, String> {
    let token = std::str::from_utf8(output)
        .map_err(|_| "token_file_invalid".to_string())?
        .trim();
    if token.is_empty() {
        return Err("token_file_not_found".to_string());
    }
    if token.len() > 256
        || token
            .chars()
            .any(|ch| ch.is_control() || ch.is_whitespace())
    {
        return Err("token_file_invalid".to_string());
    }
    Ok(token.to_string())
}

#[cfg(windows)]
fn check_windows_environment() -> Result<WslEnvironmentStatus, String> {
    let list_output = match run_wsl(&["-l", "-v"]) {
        Ok(output) if output.status.success() => output,
        Ok(_) | Err(_) => return Ok(WslEnvironmentStatus::default()),
    };
    let Some(distributions) = parse_wsl_table(&list_output.stdout) else {
        return Ok(WslEnvironmentStatus::default());
    };
    let Some(ubuntu) = distributions
        .into_iter()
        .find(UbuntuDistribution::is_ubuntu)
    else {
        return Ok(WslEnvironmentStatus {
            wsl_installed: true,
            ..WslEnvironmentStatus::default()
        });
    };

    let tmux_installed = run_wsl(&["-d", &ubuntu.name, "-e", "which", "tmux"])
        .map(|output| output.status.success())
        .unwrap_or(false);
    // Only the bundled daemon satisfies the app contract. A legacy
    // corral-core binary is intentionally treated as missing so the next
    // startup installs agentmirrord instead of falling back into restart loops.
    let service_installed = bundled_service_current(&ubuntu.name);
    let service_running = run_wsl(&[
        "-d",
        &ubuntu.name,
        "-e",
        "sh",
        "-lc",
        "pgrep -x agentmirrord >/dev/null || pgrep -x corral-core >/dev/null",
    ])
    .map(|output| output.status.success())
    .unwrap_or(false);
    let wsl_ip = run_wsl(&["-d", &ubuntu.name, "-e", "hostname", "-I"])
        .ok()
        .and_then(|output| first_ip(&output.stdout));

    Ok(WslEnvironmentStatus {
        wsl_installed: true,
        ubuntu_installed: true,
        ubuntu_running: ubuntu.running,
        tmux_installed,
        service_installed,
        service_running,
        wsl_ip,
    })
}

/// Install the bundled Linux daemon and its provider table into the Ubuntu home.
#[tauri::command]
pub fn install_wsl_service(app: tauri::AppHandle) -> Result<(), String> {
    #[cfg(windows)]
    {
        return install_wsl_service_windows(&app);
    }

    #[cfg(not(windows))]
    {
        let _ = app;
        Err("unsupported_platform: WSL2 is available on Windows only".to_string())
    }
}

/// Return the local WSL 2/Ubuntu/tmux/agentmirrord state.
#[tauri::command]
pub fn check_wsl_environment() -> Result<WslEnvironmentStatus, String> {
    #[cfg(windows)]
    {
        return check_windows_environment();
    }

    #[cfg(not(windows))]
    {
        // Keep the command available in non-Windows builds so the frontend can
        // use one invoke path across desktop targets.
        Ok(WslEnvironmentStatus::default())
    }
}

/// Read the persisted local daemon token without exposing it to logs or errors.
#[cfg(any(windows, test))]
const RUNNING_SERVICE_TOKEN_SCRIPT: &str = r#"set -eu
for name in agentmirrord corral-core; do
    for pid in $(pgrep -x "$name" 2>/dev/null || true); do
        test -r "/proc/$pid/environ" || continue
        token=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^AGENTMIRROR_TOKEN=//p' | head -c 257)
        test -n "$token" || continue
        printf '%s' "$token"
        exit 0
    done
done
exit 1
"#;

#[cfg(any(windows, test))]
const SYSTEM_ENV_TOKEN_SCRIPT: &str = r#"set -eu
for path in /etc/agentmirror/*.env; do
    test -f "$path" || continue
    while IFS= read -r line; do
        case "$line" in
            AGENTMIRROR_TOKEN=*) printf '%s' "${line#AGENTMIRROR_TOKEN=}"; exit 0 ;;
            export\ AGENTMIRROR_TOKEN=*) printf '%s' "${line#export AGENTMIRROR_TOKEN=}"; exit 0 ;;
        esac
    done < "$path"
done
exit 1
"#;

#[cfg(windows)]
fn run_wsl_as_root(distribution: &str, script: &str) -> Result<std::process::Output, String> {
    // WSL's configured default user is not guaranteed to own the daemon's
    // 0600 token file. Read inside the distro as root and return only the
    // bounded token bytes to the caller.
    run_wsl(&["-d", distribution, "-u", "root", "-e", "sh", "-lc", script])
}

#[cfg(windows)]
fn read_token_from_wsl_script(distribution: &str, script: &str) -> Option<String> {
    run_wsl_as_root(distribution, script)
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| normalize_service_token(&output.stdout).ok())
}

#[tauri::command]
pub fn read_wsl_service_token() -> Result<String, String> {
    #[cfg(windows)]
    {
        let list_output = match run_wsl(&["-l", "-v"]) {
            Ok(output) if output.status.success() => output,
            Ok(_) => return Err("ubuntu_not_installed".to_string()),
            Err(_) => return Err("wsl_unavailable".to_string()),
        };
        let Some(ubuntu) = find_ubuntu_distribution(&list_output.stdout) else {
            return Err("ubuntu_not_installed".to_string());
        };
        if !ubuntu.running {
            return Err("ubuntu_not_running".to_string());
        }

        // Prefer the token from a running daemon: legacy systemd units may
        // source AGENTMIRROR_TOKEN from a root-owned env file without writing
        // the client token path. The script only returns that exact variable,
        // bounded to 257 bytes and never logs it.
        if let Some(token) = read_token_from_wsl_script(&ubuntu.name, RUNNING_SERVICE_TOKEN_SCRIPT)
        {
            return Ok(token);
        }

        // The normal client-owned token file remains the next source.
        let token_file = run_wsl_as_root(&ubuntu.name, TOKEN_READ_SCRIPT)
            .map_err(|_| "token_file_unavailable".to_string())?;
        if token_file.status.success() {
            if let Ok(token) = normalize_service_token(&token_file.stdout) {
                return Ok(token);
            }
        }

        // Last-resort compatibility for an existing systemd installation.
        if let Some(token) = read_token_from_wsl_script(&ubuntu.name, SYSTEM_ENV_TOKEN_SCRIPT) {
            return Ok(token);
        }
        Err("token_file_not_found".to_string())
    }

    #[cfg(not(windows))]
    {
        Err("unsupported_platform: WSL2 is available on Windows only".to_string())
    }
}

/// Compatibility command name used by fresh-install Windows bundles.
/// Keep the original command registered too because older desktop bundles
/// invoke `read_wsl_service_token`.
#[tauri::command]
pub fn get_wsl_pairing_token() -> Result<String, String> {
    read_wsl_service_token()
}

#[cfg(any(windows, test))]
fn service_binary(command: Option<&str>) -> Option<&'static str> {
    match command.unwrap_or("agentmirrord") {
        "agentmirrord" => Some("agentmirrord"),
        "corral-core" => Some("corral-core"),
        _ => None,
    }
}

#[cfg(any(windows, test))]
fn generate_service_token() -> Result<String, String> {
    const ALPHABET: &[u8; 32] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| "token_generation_failed".to_string())?;
    let mut token = String::with_capacity(26);
    let mut buffer = 0_u16;
    let mut bits = 0_u8;
    for byte in bytes {
        buffer = (buffer << 8) | u16::from(byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            token.push(ALPHABET[((buffer >> bits) & 31) as usize] as char);
        }
    }
    if bits > 0 {
        token.push(ALPHABET[((buffer << (5 - bits)) & 31) as usize] as char);
    }
    Ok(token)
}

#[cfg(any(windows, test))]
const SERVICE_START_SCRIPT: &str = "export NODEPROBE_FIXTURES=\"$HOME/tools/nodeprobe/fixtures/titles.tsv\" NODEPROBE_PROVIDERS=\"$HOME/tools/nodeprobe/fixtures/providers.tsv\" AGENTMIRROR_NODEPROBE_PI_EXTENSION=\"$HOME/.pi/agent/extensions/nodeprobe-pi-activity.js\"; test -s \"$NODEPROBE_FIXTURES\" && test -s \"$NODEPROBE_PROVIDERS\" && test -s \"$AGENTMIRROR_NODEPROBE_PI_EXTENSION\"; exec env -u AGENTMIRROR_TOKEN \"$1\" -listen 127.0.0.1:9900 -token \"$2\"";

#[cfg(any(windows, test))]
fn service_start_args<'a>(distribution: &'a str, service: &'a str, token: &'a str) -> [&'a str; 9] {
    [
        "-d",
        distribution,
        "-e",
        "sh",
        "-lc",
        SERVICE_START_SCRIPT,
        "--",
        service,
        token,
    ]
}

#[cfg(any(windows, test))]
const TOKEN_READ_SCRIPT: &str = r#"set -eu
read_token() {
    path="$1"
    if test -s "$path"; then
        head -c 257 "$path"
        exit 0
    fi
}

# Prefer the configured HOME, then the home of the running daemon's UID.
read_token "$HOME/.config/agentmirror/token"
for name in agentmirrord corral-core; do
    for pid in $(pgrep -x "$name" 2>/dev/null || true); do
        uid=$(awk '/^Uid:/{print $2; exit}' "/proc/$pid/status" 2>/dev/null || true)
        home=$(awk -F: -v uid="$uid" '$3 == uid {print $6; exit}' /etc/passwd 2>/dev/null || true)
        test -n "$home" || continue
        read_token "$home/.config/agentmirror/token"
    done
done

# Finally cover distros whose service user is not present in /proc anymore.
read_token "/root/.config/agentmirror/token"
for path in /home/*/.config/agentmirror/token; do
    read_token "$path"
done
exit 1
"#;

#[cfg(windows)]
const TOKEN_WRITE_SCRIPT: &str = r#"set -eu
token="$1"
path="$HOME/.config/agentmirror/token"
mkdir -p "$(dirname "$path")"
tmp="$path.tmp.$$"
trap 'rm -f "$tmp"' EXIT
umask 077
printf '%s\n' "$token" > "$tmp"
chmod 600 "$tmp"
mv -f -- "$tmp" "$path"
test -s "$path"
"#;

#[cfg(windows)]
fn read_wsl_service_token_for_start(distribution: &str) -> Result<Option<String>, String> {
    let output = run_wsl_as_root(distribution, TOKEN_READ_SCRIPT)
        .map_err(|_| "token_file_unavailable".to_string())?;
    if !output.status.success() {
        return Err("token_file_unavailable".to_string());
    }
    match normalize_service_token(&output.stdout) {
        Ok(token) => Ok(Some(token)),
        Err(error) if error == "token_file_not_found" => Ok(None),
        Err(error) => Err(error),
    }
}

#[cfg(windows)]
fn write_wsl_service_token(distribution: &str, token: &str) -> Result<(), String> {
    let output = run_wsl(&[
        "-d",
        distribution,
        "-e",
        "sh",
        "-c",
        TOKEN_WRITE_SCRIPT,
        "agentmirrord-token",
        token,
    ])
    .map_err(|_| "token_file_write_failed".to_string())?;
    if output.status.success() {
        Ok(())
    } else {
        Err("token_file_write_failed".to_string())
    }
}

#[cfg(windows)]
fn ensure_wsl_service_token(distribution: &str) -> Result<String, String> {
    if let Some(token) = read_wsl_service_token_for_start(distribution)? {
        return Ok(token);
    }
    let token = generate_service_token()?;
    write_wsl_service_token(distribution, &token)?;
    Ok(token)
}

#[cfg(windows)]
fn service_process_ready(distribution: &str, service: &str) -> bool {
    run_wsl(&["-d", distribution, "-e", "pgrep", "-x", service])
        .map(|output| output.status.success())
        .unwrap_or(false)
}

#[cfg(any(windows, test))]
fn http_status_code(response: &[u8]) -> Option<u16> {
    let line = response
        .split(|byte| *byte == b'\r' || *byte == b'\n')
        .next()?;
    let mut fields = line.split(|byte| *byte == b' ' || *byte == b'\t');
    let version = fields.next()?;
    let status = fields.next()?;
    if !matches!(version, b"HTTP/1.0" | b"HTTP/1.1")
        || status.len() != 3
        || !status.iter().all(u8::is_ascii_digit)
    {
        return None;
    }
    std::str::from_utf8(status).ok()?.parse().ok()
}

#[cfg(any(windows, test))]
fn http_response_is_ready(response: &[u8]) -> bool {
    // Readiness proves that the listener is serving HTTP, not that this
    // endpoint exists in every compatible daemon generation. A legacy daemon
    // may return 404 for /pair/whoami while /ws and auth are available.
    http_status_code(response).is_some()
}

#[cfg(windows)]
fn service_http_status() -> Option<u16> {
    let address = SocketAddr::from(([127, 0, 0, 1], SERVICE_READY_PORT));
    let Ok(mut stream) = TcpStream::connect_timeout(&address, std::time::Duration::from_millis(40))
    else {
        return None;
    };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(40)));
    let _ = stream.set_write_timeout(Some(std::time::Duration::from_millis(40)));
    if stream
        .write_all(b"GET /pair/whoami HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .is_err()
    {
        return None;
    }
    let mut response = [0_u8; 512];
    let Ok(read) = stream.read(&mut response) else {
        return None;
    };
    http_status_code(&response[..read])
}

#[cfg(windows)]
fn service_http_ready() -> bool {
    service_http_status().is_some_and(|status| status < 500)
}

#[cfg(windows)]
fn wait_for_service_ready() -> Result<(), String> {
    // Probe the real public endpoint immediately, then every 25ms. A process
    // being present is not readiness; the first successful HTTP response is.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while std::time::Instant::now() < deadline {
        match service_http_status() {
            Some(502) => return Err("service_port_occupied_502".to_string()),
            Some(status) if status < 500 => return Ok(()),
            _ => std::thread::sleep(std::time::Duration::from_millis(25)),
        }
    }
    Err("service_start_failed".to_string())
}

#[cfg(windows)]
fn service_token_ready(distribution: &str, expected: &str) -> bool {
    let output = run_wsl_as_root(distribution, TOKEN_READ_SCRIPT);
    output
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| normalize_service_token(&output.stdout).ok())
        .is_some_and(|token| token == expected)
}

#[cfg(windows)]
fn wait_for_service_token(distribution: &str, expected: &str) -> Result<(), String> {
    for _ in 0..40 {
        if service_token_ready(distribution, expected) {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(25));
    }
    Err("service_token_not_ready".to_string())
}

/// Start a whitelisted session service in the Ubuntu WSL distribution.
///
/// The daemon intentionally remains the foreground command owned by `wsl.exe`.
/// WSL tears down orphaned background jobs when the launcher exits, so `nohup`
/// alone cannot make the service survive a cold launch. The Windows launcher is
/// detached from the GUI process while its Linux child remains foreground.
/// The login shell loads the user's PATH so binaries installed under
/// `~/.local/bin` are resolvable; service and token stay positional arguments.
#[tauri::command]
pub fn start_wsl_service(app: tauri::AppHandle, service_cmd: Option<String>) -> Result<(), String> {
    #[cfg(windows)]
    {
        let _ = app;
        let Some(service) = service_binary(service_cmd.as_deref()) else {
            return Err("unsupported_service_command".to_string());
        };
        let list_output = match run_wsl(&["-l", "-v"]) {
            Ok(output) if output.status.success() => output,
            Ok(_) | Err(_) => return Err("ubuntu_not_installed".to_string()),
        };
        let Some(ubuntu) = find_ubuntu_distribution(&list_output.stdout) else {
            return Err("ubuntu_not_installed".to_string());
        };
        let installed = if service == AGENTMIRRORD_NAME {
            bundled_service_current(&ubuntu.name)
        } else {
            service_command_installed(&ubuntu.name, service)
        };
        if !installed {
            return Err(format!(
                "service_not_installed: {service} not found or out of date in WSL Ubuntu"
            ));
        }
        if service_http_status() == Some(502) {
            return Err("service_port_occupied_502".to_string());
        }
        let token = ensure_wsl_service_token(&ubuntu.name)?;
        if service_http_ready() {
            return Ok(());
        }

        // Reuse an existing process while it is coming up. Never stop a
        // healthy/starting daemon merely because the UI was reopened.
        if !service_process_ready(&ubuntu.name, service) {
            // Keep the daemon in the foreground inside a console-free wsl.exe process.
            // WSL therefore keeps the Linux session alive after this function and
            // the GUI process return.
            // DETACHED_PROCESS would make Windows ignore CREATE_NO_WINDOW.
            let _child = hidden_command("wsl.exe")
                .args(service_start_args(&ubuntu.name, service, &token))
                .stdin(std::process::Stdio::null())
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .spawn()
                .map_err(|error| format!("wsl_service_start_failed: {error}"))?;
        }

        wait_for_service_ready()?;
        // Ensure the token file is visible before returning so the frontend
        // can authenticate without a race.
        wait_for_service_token(&ubuntu.name, &token)
    }

    #[cfg(not(windows))]
    {
        let _ = (app, service_cmd);
        Err("unsupported_platform: WSL2 is available on Windows only".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        find_ubuntu_distribution, first_ip, generate_service_token, hidden_command,
        http_response_is_ready, http_status_code, install_script, normalize_service_token,
        parse_wsl_table, service_binary,
        service_probe_command, service_start_args, WslEnvironmentStatus, CREATE_NO_WINDOW,
        NODEPROBE_SHA256, PI_PROBE_SOURCE, RUNNING_SERVICE_TOKEN_SCRIPT, SERVICE_START_SCRIPT,
        SYSTEM_ENV_TOKEN_SCRIPT, TITLES_TSV, TOKEN_READ_SCRIPT,
    };

    #[test]
    fn windows_launcher_has_no_window_flag() {
        assert_eq!(CREATE_NO_WINDOW, 0x0800_0000);
    }

    #[test]
    fn http_ready_requires_an_http_status_line() {
        assert!(http_response_is_ready(b"HTTP/1.1 200 OK\r\n"));
        assert!(http_response_is_ready(b"HTTP/1.0 404 Not Found\r\n"));
        assert!(http_response_is_ready(b"HTTP/1.1 503 Busy\r\n"));
        assert_eq!(http_status_code(b"HTTP/1.1 502 Bad Gateway\r\n"), Some(502));
        assert!(http_response_is_ready(b"HTTP/1.1 401 Unauthorized\r\n"));
        assert!(!http_response_is_ready(b"HTTP/1.1 nope\r\n"));
        assert!(!http_response_is_ready(b"garbage"));
    }

    #[test]
    fn parses_running_ubuntu_from_wsl_table() {
        let output =
            b"  NAME            STATE           VERSION\n* Ubuntu-22.04    Running         2\n";
        assert_eq!(
            find_ubuntu_distribution(output),
            Some(super::UbuntuDistribution {
                name: "Ubuntu-22.04".to_string(),
                running: true,
            })
        );
    }

    #[test]
    fn parses_stopped_ubuntu_and_ip() {
        let output = b"NAME STATE VERSION\nUbuntu Stopped 2\n";
        let distribution = find_ubuntu_distribution(output).unwrap();
        assert!(!distribution.running);
        assert_eq!(
            first_ip(b"172.22.16.3 127.0.0.1\n"),
            Some("172.22.16.3".to_string())
        );
    }

    #[test]
    fn rejects_wsl_error_output() {
        let output = b"wsl: error Ubuntu is not installed\n";
        assert!(parse_wsl_table(output).is_none());
        assert!(find_ubuntu_distribution(output).is_none());
    }

    #[test]
    fn rejects_empty_and_malformed_tables() {
        assert!(parse_wsl_table(b"").is_none());
        assert!(parse_wsl_table(b"NAME STATE VERSION\n").is_none());
        assert!(parse_wsl_table(b"Ubuntu Stopped 2\n").is_none());
        assert!(parse_wsl_table(b"NAME STATE VERSION\n* Ubuntu Running\n").is_none());
        assert!(parse_wsl_table(b"* Ubuntu Running 1\n").is_none());
    }

    #[test]
    fn bundled_install_script_is_atomic_and_contains_provider_defaults() {
        let script = install_script();
        assert!(script.contains("version_file=\"$dst.version\""));
        assert!(script.contains("test \"$(cat \"$version_file\")\""));
        assert!(script.contains("exit 0"));
        assert!(script.contains("install -m 0755 -- \"$src\" \"$service_tmp\""));
        assert!(script.contains("install -m 0755 -- \"$nodeprobe_src\" \"$nodeprobe_tmp\""));
        assert!(script.contains("mv -f -- \"$nodeprobe_tmp\" \"$nodeprobe_dst\""));
        assert!(script.contains("mv -f -- \"$service_tmp\" \"$dst\""));
        assert!(script.contains("pkill -TERM -x \"$name\""));
        assert!(script.contains("stop_service agentmirrord"));
        assert!(script.contains("stop_service corral-core"));
        assert!(script.contains("cursor-agent\tcursor\tCursor\tpath-segment"));
        assert!(script.contains("pi\tpi\tPi"));
        assert!(script.contains("printf '%s' ") && script.contains("| tr -d '\\r' > \"$titles_tmp\""));
        assert!(script.contains("test -s \"$titles\""));
        assert!(script.contains("mv -f -- \"$titles_tmp\" \"$titles\""));
        assert!(script.contains("probe_dir=\"$HOME/.pi/agent/plugins/agentmirror-probe\""));
        assert!(script.contains("extension=\"$extensions_dir/nodeprobe-pi-activity.js\""));
        assert!(script.contains("install -m 0755 -- \"$src\" \"$service_tmp\""));
        assert!(script.contains("printf '%s' "));
        assert!(script.contains("| base64 -d > \"$probe_tmp\""));
        assert!(script.contains("chmod 0644 \"$probe_tmp\""));
        assert!(script.contains("test \"$(stat -c '%a' \"$probe_dir\")\" = 755"));
        assert!(script.contains("test \"$(stat -c '%a' \"$probe\")\" = 644"));
        assert!(PI_PROBE_SOURCE.contains("pi.on(\"agent_start\""));
        assert!(script.contains("test -x \"$dst\""));
        assert!(script.contains("test -x \"$nodeprobe_dst\""));
        assert!(script.contains(NODEPROBE_SHA256));
        assert!(script.contains("test -s \"$titles\""));
        assert!(!script.contains("touch \"$titles\""));
        assert!(!TITLES_TSV.contains('\r'));
        assert!(!TITLES_TSV.is_empty());
        assert!(script.contains("mv -f -- \"$version_tmp\" \"$version_file\""));
        let syntax = hidden_command("sh")
            .args(["-n", "-c", &script])
            .status()
            .expect("shell is available");
        assert!(syntax.success(), "generated install script must parse");
    }

    #[test]
    fn service_name_is_strictly_whitelisted() {
        assert_eq!(service_binary(None), Some("agentmirrord"));
        assert_eq!(service_binary(Some("agentmirrord")), Some("agentmirrord"));
        assert_eq!(service_binary(Some("corral-core")), Some("corral-core"));
        assert_eq!(service_binary(Some("rm -rf /")), None);
        assert_eq!(service_binary(Some("agentmirrord --config")), None);
    }

    #[test]
    fn legacy_token_scripts_are_bounded_and_do_not_log_values() {
        assert!(RUNNING_SERVICE_TOKEN_SCRIPT.contains("/proc/$pid/environ"));
        assert!(RUNNING_SERVICE_TOKEN_SCRIPT.contains("head -c 257"));
        assert!(SYSTEM_ENV_TOKEN_SCRIPT.contains("/etc/agentmirror/*.env"));
        assert!(SYSTEM_ENV_TOKEN_SCRIPT.contains("AGENTMIRROR_TOKEN="));
        assert!(TOKEN_READ_SCRIPT.contains("$HOME/.config/agentmirror/token"));
        assert!(TOKEN_READ_SCRIPT.contains("/proc/$pid/status"));
        assert!(TOKEN_READ_SCRIPT.contains("/home/*/.config/agentmirror/token"));
        let syntax = hidden_command("sh")
            .args(["-n", "-c", TOKEN_READ_SCRIPT])
            .status()
            .expect("shell is available");
        assert!(syntax.success(), "token read script must parse");
    }

    #[test]
    fn service_start_has_explicit_token_and_listen_flags() {
        assert!(SERVICE_START_SCRIPT.contains("-listen 127.0.0.1:9900"));
        assert!(!SERVICE_START_SCRIPT.contains("0.0.0.0"));
        assert!(SERVICE_START_SCRIPT.contains("export NODEPROBE_FIXTURES=\"$HOME/tools/nodeprobe/fixtures/titles.tsv\""));
        assert!(SERVICE_START_SCRIPT.contains("NODEPROBE_PROVIDERS=\"$HOME/tools/nodeprobe/fixtures/providers.tsv\""));
        assert!(SERVICE_START_SCRIPT.contains("AGENTMIRROR_NODEPROBE_PI_EXTENSION=\"$HOME/.pi/agent/extensions/nodeprobe-pi-activity.js\""));
        assert!(SERVICE_START_SCRIPT.contains("test -s \"$NODEPROBE_FIXTURES\""));
        assert!(SERVICE_START_SCRIPT.contains("test -s \"$NODEPROBE_PROVIDERS\""));
        assert!(SERVICE_START_SCRIPT.contains("test -s \"$AGENTMIRROR_NODEPROBE_PI_EXTENSION\""));
        assert_eq!(
            service_start_args("Ubuntu", "agentmirrord", "TOKEN123"),
            [
                "-d",
                "Ubuntu",
                "-e",
                "sh",
                "-lc",
                SERVICE_START_SCRIPT,
                "--",
                "agentmirrord",
                "TOKEN123",
            ]
        );
    }

    #[test]
    fn generated_service_token_is_128_bit_base32() {
        let token = generate_service_token().unwrap();
        assert_eq!(token.len(), 26);
        assert!(token
            .bytes()
            .all(|byte| byte.is_ascii_uppercase() || (b'2'..=b'7').contains(&byte)));
    }

    #[test]
    fn service_probe_is_strict_and_uses_command_v() {
        assert_eq!(
            service_probe_command("agentmirrord"),
            Some("command -v agentmirrord >/dev/null")
        );
        assert_eq!(
            service_probe_command("corral-core"),
            Some("command -v corral-core >/dev/null")
        );
        assert_eq!(service_probe_command("rm -rf /"), None);
    }

    #[test]
    fn default_status_reports_service_not_installed() {
        let status = WslEnvironmentStatus::default();
        assert!(!status.service_installed);
        assert_eq!(
            serde_json::to_value(status)
                .unwrap()
                .get("service_installed"),
            Some(&serde_json::Value::Bool(false))
        );
    }

    #[test]
    fn normalizes_service_token_without_exposing_invalid_content() {
        assert_eq!(
            normalize_service_token(b" ABCDEFGHIJKLMNOPQRSTUVWXYZ234567\n"),
            Ok("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".to_string())
        );
        assert_eq!(
            normalize_service_token(b""),
            Err("token_file_not_found".to_string())
        );
        assert_eq!(
            normalize_service_token(b"bad token\n"),
            Err("token_file_invalid".to_string())
        );
        assert_eq!(
            normalize_service_token(&vec![b'a'; 257]),
            Err("token_file_invalid".to_string())
        );
    }
}
