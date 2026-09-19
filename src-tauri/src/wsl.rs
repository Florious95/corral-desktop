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

/// Decode the output of `wsl.exe -l -v` and locate an Ubuntu distribution.
///
/// Older WSL builds emit this table as UTF-16LE even when stdout is captured by
/// a process. Removing the interleaved NUL bytes handles its ASCII table output
/// while keeping the parser independent from a Windows-only decoding crate.
#[cfg(any(windows, test))]
fn find_ubuntu_distribution(output: &[u8]) -> Option<UbuntuDistribution> {
    let text: String = String::from_utf8_lossy(output)
        .chars()
        .filter(|character| *character != '\0')
        .collect();

    text.lines().find_map(|line| {
        let fields: Vec<&str> = line.split_whitespace().collect();
        let name = fields.iter().find(|field| {
            field.eq_ignore_ascii_case(&"ubuntu")
                || field.to_ascii_lowercase().starts_with("ubuntu-")
        })?;
        Some(UbuntuDistribution {
            name: (*name).to_string(),
            running: fields
                .iter()
                .any(|field| field.eq_ignore_ascii_case("running")),
        })
    })
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
    let status_output = run_wsl(&["--status"]);
    let list_output = match run_wsl(&["-l", "-v"]) {
        Ok(output) => output,
        Err(_error) if status_output.is_err() => return Ok(WslEnvironmentStatus::default()),
        Err(error) => return Err(error),
    };

    let wsl_installed = status_output.is_ok() || list_output.status.success();
    if !wsl_installed {
        return Ok(WslEnvironmentStatus::default());
    }

    let Some(ubuntu) = find_ubuntu_distribution(&list_output.stdout) else {
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

#[cfg(windows)]
fn service_command_is_safe(command: &str) -> bool {
    !command.is_empty()
        && command.chars().all(|character| {
            character.is_ascii_alphanumeric()
                || matches!(character, '/' | '_' | '-' | '.' | ' ' | ':' | '=')
        })
}

/// Start agentmirrord (or corral-core) in the Ubuntu WSL distribution.
///
/// `service_cmd` may include ordinary command-line arguments, but shell control
/// characters are rejected before the command is passed to `sh -lc`.
#[tauri::command]
pub fn start_wsl_service(service_cmd: Option<String>) -> Result<(), String> {
    #[cfg(windows)]
    {
        let command = service_cmd.unwrap_or_else(|| "agentmirrord".to_string());
        if !service_command_is_safe(&command) {
            return Err("invalid_service_command".to_string());
        }

        let list_output = run_wsl(&["-l", "-v"])?;
        let ubuntu = find_ubuntu_distribution(&list_output.stdout)
            .ok_or_else(|| "ubuntu_not_installed".to_string())?;
        let script = format!("nohup {command} >/dev/null 2>&1 </dev/null &");
        let status = std::process::Command::new("wsl.exe")
            .args(["-d", &ubuntu.name, "-e", "sh", "-lc", &script])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map_err(|error| format!("wsl_unavailable: {error}"))?;
        if status.success() {
            Ok(())
        } else {
            Err(format!("wsl_service_start_failed: exit status {status}"))
        }
    }

    #[cfg(not(windows))]
    {
        let _ = service_cmd;
        Err("unsupported_platform: WSL2 is available on Windows only".to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{find_ubuntu_distribution, first_ip};

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
        let output = b"Ubuntu Stopped 2\n";
        let distribution = find_ubuntu_distribution(output).unwrap();
        assert!(!distribution.running);
        assert_eq!(
            first_ip(b"172.22.16.3 127.0.0.1\n"),
            Some("172.22.16.3".to_string())
        );
    }
}
