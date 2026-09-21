use serde::Serialize;
#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::path::Path;

#[cfg(windows)]
use tauri::{path::BaseDirectory, Manager};

#[cfg(windows)]
const AGENTMIRRORD_RESOURCE: &str = "resources/agentmirrord-linux-amd64";
const AGENTMIRRORD_NAME: &str = "agentmirrord";
const PROVIDERS_TSV: &str = "# comm-basename\tprovider-id\tdisplay-name\t[match]\n# match empty = basename only; path-segment = also hit when raw comm contains /<comm-basename>/ as a directory.\nclaude\tclaude_code\tClaude Code\ncodex\tcodex\tCodex\ncopilot\tcopilot\tCopilot\ngrok\tgrok\tGrok\ncursor-agent\tcursor\tCursor\tpath-segment\npi\tpi\tPi\n";

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

#[cfg(windows)]
fn run_wsl(args: &[&str]) -> Result<std::process::Output, String> {
    std::process::Command::new("wsl.exe")
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
dst="$HOME/.local/bin/{AGENTMIRRORD_NAME}"
providers="$HOME/tools/nodeprobe/fixtures/providers.tsv"
titles="$HOME/tools/nodeprobe/fixtures/titles.tsv"
mkdir -p "$(dirname "$dst")" "$(dirname "$providers")"
service_tmp="$dst.tmp.$$"
providers_tmp="$providers.tmp.$$"
trap 'rm -f "$service_tmp" "$providers_tmp"' EXIT
install -m 0755 -- "$src" "$service_tmp"
mv -f -- "$service_tmp" "$dst"
umask 077
printf '%s' {providers} > "$providers_tmp"
mv -f -- "$providers_tmp" "$providers"
touch "$titles"
test -x "$dst"
test -s "$providers"
test -f "$titles"
"#,
        providers = shell_single_quote(PROVIDERS_TSV),
    )
}

#[cfg(any(windows, test))]
fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(windows)]
fn install_wsl_service_windows(app: &tauri::AppHandle) -> Result<(), String> {
    let resource = app
        .path()
        .resolve(AGENTMIRRORD_RESOURCE, BaseDirectory::Resource)
        .map_err(|_| "agentmirrord_resource_unavailable".to_string())?;
    if !resource_is_usable(&resource) {
        return Err("agentmirrord_resource_unavailable".to_string());
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
    ])?;
    if !output.status.success() {
        return Err("agentmirrord_install_failed".to_string());
    }

    let verify = run_wsl(&[
        "-d",
        &ubuntu.name,
        "-e",
        "sh",
        "-lc",
        "test -x \"$HOME/.local/bin/agentmirrord\" && test -s \"$HOME/tools/nodeprobe/fixtures/providers.tsv\" && test -f \"$HOME/tools/nodeprobe/fixtures/titles.tsv\"",
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
    let service_installed = run_wsl(&[
        "-d",
        &ubuntu.name,
        "-e",
        "sh",
        "-lc",
        "command -v agentmirrord >/dev/null || command -v corral-core >/dev/null",
    ])
    .map(|output| output.status.success())
    .unwrap_or(false);
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
fn read_token_from_wsl_script(distribution: &str, script: &str) -> Option<String> {
    run_wsl(&["-d", distribution, "-e", "sh", "-c", script])
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
        let token_file = run_wsl(&[
            "-d",
            &ubuntu.name,
            "-e",
            "sh",
            "-lc",
            "test -f \"$HOME/.config/agentmirror/token\" && head -c 257 \"$HOME/.config/agentmirror/token\"",
        ])
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
const SERVICE_START_SCRIPT: &str =
    "exec env -u AGENTMIRROR_TOKEN \"$1\" -listen 0.0.0.0:9900 -token \"$2\"";

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

#[cfg(windows)]
const TOKEN_READ_SCRIPT: &str =
    "if test -f \"$HOME/.config/agentmirror/token\"; then head -c 257 \"$HOME/.config/agentmirror/token\"; fi";

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
    let output = run_wsl(&["-d", distribution, "-e", "sh", "-lc", TOKEN_READ_SCRIPT])
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

#[cfg(windows)]
fn wait_for_service_process(distribution: &str, service: &str) -> Result<(), String> {
    // WSL cold starts can take over a second on a fresh distribution. Poll the
    // Linux process instead of treating a successful wsl.exe spawn as ready.
    for _ in 0..15 {
        if service_process_ready(distribution, service) {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    Err("service_start_failed".to_string())
}

#[cfg(windows)]
fn service_token_ready(distribution: &str, expected: &str) -> bool {
    let output = run_wsl(&["-d", distribution, "-e", "sh", "-lc", TOKEN_READ_SCRIPT]);
    output
        .ok()
        .filter(|output| output.status.success())
        .and_then(|output| normalize_service_token(&output.stdout).ok())
        .is_some_and(|token| token == expected)
}

#[cfg(windows)]
fn wait_for_service_token(distribution: &str, expected: &str) -> Result<(), String> {
    for _ in 0..50 {
        if service_token_ready(distribution, expected) {
            return Ok(());
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
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
pub fn start_wsl_service(service_cmd: Option<String>) -> Result<(), String> {
    #[cfg(windows)]
    {
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
        if !service_command_installed(&ubuntu.name, service) {
            return Err(format!(
                "service_not_installed: {service} not found in WSL Ubuntu PATH"
            ));
        }
        let token = ensure_wsl_service_token(&ubuntu.name)?;

        // Keep the daemon in the foreground inside a detached wsl.exe process.
        // WSL therefore keeps the Linux session alive after this function and
        // the GUI process return.
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        let _child = std::process::Command::new("wsl.exe")
            .args(service_start_args(&ubuntu.name, service, &token))
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP)
            .spawn()
            .map_err(|error| format!("wsl_service_start_failed: {error}"))?;
        wait_for_service_process(&ubuntu.name, service)?;

        // Ensure the token file is visible before returning so the frontend
        // can authenticate without a race.
        wait_for_service_token(&ubuntu.name, &token)
    }

    #[cfg(not(windows))]
    {
        let _ = service_cmd;
        Err("unsupported_platform: WSL2 is available on Windows only".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        find_ubuntu_distribution, first_ip, generate_service_token, install_script,
        normalize_service_token, parse_wsl_table, service_binary, service_probe_command,
        service_start_args, WslEnvironmentStatus, RUNNING_SERVICE_TOKEN_SCRIPT,
        SERVICE_START_SCRIPT, SYSTEM_ENV_TOKEN_SCRIPT,
    };

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
        assert!(script.contains("install -m 0755 -- \"$src\" \"$service_tmp\""));
        assert!(script.contains("mv -f -- \"$service_tmp\" \"$dst\""));
        assert!(script.contains("cursor-agent\tcursor\tCursor\tpath-segment"));
        assert!(script.contains("pi\tpi\tPi"));
        assert!(script.contains("touch \"$titles\""));
        assert!(script.contains("test -x \"$dst\""));
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
    }

    #[test]
    fn service_start_has_explicit_token_and_listen_flags() {
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
