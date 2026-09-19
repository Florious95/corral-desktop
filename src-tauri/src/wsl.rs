use serde::Serialize;

/// Snapshot of the WSL 2 environment used by the local AgentMirror daemon.
#[derive(Debug, Default, Serialize, PartialEq, Eq)]
pub struct WslEnvironmentStatus {
    pub wsl_installed: bool,
    pub ubuntu_installed: bool,
    pub ubuntu_running: bool,
    pub tmux_installed: bool,
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
        service_running,
        wsl_ip,
    })
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

#[cfg(any(windows, test))]
fn service_binary(command: Option<&str>) -> Option<&'static str> {
    match command.unwrap_or("agentmirrord") {
        "agentmirrord" => Some("agentmirrord"),
        "corral-core" => Some("corral-core"),
        _ => None,
    }
}

/// Start a whitelisted session service in the Ubuntu WSL distribution.
///
/// The service name is passed as a standalone argv element to `nohup`; no shell
/// is involved, so callers cannot turn this command into arbitrary WSL code.
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
        let _child = std::process::Command::new("wsl.exe")
            .args(["-d", &ubuntu.name, "-e", "nohup", service])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|error| format!("wsl_service_start_failed: {error}"))?;
        Ok(())
    }

    #[cfg(not(windows))]
    {
        let _ = service_cmd;
        Err("unsupported_platform: WSL2 is available on Windows only".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{find_ubuntu_distribution, first_ip, parse_wsl_table, service_binary};

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
    fn service_name_is_strictly_whitelisted() {
        assert_eq!(service_binary(None), Some("agentmirrord"));
        assert_eq!(service_binary(Some("agentmirrord")), Some("agentmirrord"));
        assert_eq!(service_binary(Some("corral-core")), Some("corral-core"));
        assert_eq!(service_binary(Some("rm -rf /")), None);
        assert_eq!(service_binary(Some("agentmirrord --config")), None);
    }
}
