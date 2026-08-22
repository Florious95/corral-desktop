use std::fs;
use std::fs::OpenOptions;
use std::io::Write;
use std::os::unix::fs::PermissionsExt;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tauri::Manager;
use tauri_plugin_store::StoreExt;

/// Filename under $APP_DATA. Keep in sync with src/core/store.js.
const DEVICES_FILE: &str = "devices.json";
const UPLOAD_LOG: &str = "upload.log";

fn devices_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(dir.join(DEVICES_FILE))
}

fn upload_log_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(dir.join(UPLOAD_LOG))
}

fn chmod600(path: &std::path::Path) -> Result<(), String> {
    let mut perms = fs::metadata(path).map_err(|e| e.to_string())?.permissions();
    perms.set_mode(0o600);
    fs::set_permissions(path, perms).map_err(|e| e.to_string())
}

fn looks_like_secret(s: &str) -> bool {
    let l = s.to_ascii_lowercase();
    if l.contains("bearer ") || l.contains("authkey=") || l.contains("authorization:") {
        return true;
    }
    let mut run = 0usize;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() {
            run += 1;
            if run >= 32 {
                return true;
            }
        } else {
            run = 0;
        }
    }
    false
}

fn scrub(s: &str) -> String {
    let mut out = String::new();
    let bytes = s.as_bytes();
    let lower = s.to_ascii_lowercase();
    let needle = b"bearer ";
    let mut i = 0;
    while i < bytes.len() {
        if i + needle.len() <= bytes.len() && lower.as_bytes()[i..].starts_with(needle) {
            out.push_str("Bearer ***");
            i += needle.len();
            while i < bytes.len() && !bytes[i].is_ascii_whitespace() {
                i += 1;
            }
            continue;
        }
        out.push(s[i..].chars().next().unwrap_or('?'));
        i += s[i..].chars().next().map(|c| c.len_utf8()).unwrap_or(1);
    }
    out
}

/// Ensure the store file exists with 0600 so a pairing secret never lands in a world-readable file.
fn ensure_devices_store(app: &tauri::AppHandle) -> Result<(), String> {
    let path = devices_path(app)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    if !path.exists() {
        fs::write(&path, "{}").map_err(|e| e.to_string())?;
    }
    chmod600(&path)?;
    let _ = app.store(DEVICES_FILE).map_err(|e| e.to_string())?;
    chmod600(&path)?;
    Ok(())
}

#[tauri::command]
fn lock_devices_file(app: tauri::AppHandle) -> Result<(), String> {
    chmod600(&devices_path(&app)?)
}

#[tauri::command]
fn append_upload_log(app: tauri::AppHandle, line: String) -> Result<(), String> {
    if looks_like_secret(&line) {
        return Err("refused".into());
    }
    let path = upload_log_path(&app)?;
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| e.to_string())?;
    writeln!(f, "{line}").map_err(|e| e.to_string())?;
    chmod600(&path)?;
    Ok(())
}

#[derive(Serialize)]
struct UploadHttpResult {
    ok: bool,
    status: u16,
    body: String,
    unreachable: bool,
    err_name: String,
    err_message: String,
}

fn multipart(boundary: &str, filename: &str, mime: &str, data: &[u8]) -> Vec<u8> {
    let safe: String = filename
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '.' || c == '-' || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect();
    let name = if safe.is_empty() {
        "paste.png".into()
    } else {
        safe
    };
    let mut out = Vec::with_capacity(data.len() + 256);
    out.extend_from_slice(
        format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\nContent-Type: {mime}\r\n\r\n"
        )
        .as_bytes(),
    );
    out.extend_from_slice(data);
    out.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    out
}

fn post_upload(
    url: &str,
    authorization: &str,
    filename: &str,
    mime: &str,
    data: &[u8],
) -> UploadHttpResult {
    let boundary = format!(
        "----am{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0)
    );
    let body = multipart(&boundary, filename, mime, data);
    let agent = ureq::AgentBuilder::new()
        .timeout(std::time::Duration::from_secs(60))
        .build();
    match agent
        .post(url)
        .set("Authorization", authorization)
        .set(
            "Content-Type",
            &format!("multipart/form-data; boundary={boundary}"),
        )
        .send_bytes(&body)
    {
        Ok(resp) => {
            let status = resp.status();
            let text = resp.into_string().unwrap_or_default();
            UploadHttpResult {
                ok: (200..300).contains(&status),
                status,
                body: text,
                unreachable: false,
                err_name: String::new(),
                err_message: String::new(),
            }
        }
        Err(ureq::Error::Status(status, resp)) => {
            let text = resp.into_string().unwrap_or_default();
            UploadHttpResult {
                ok: false,
                status,
                body: text,
                unreachable: false,
                err_name: String::new(),
                err_message: String::new(),
            }
        }
        Err(e) => UploadHttpResult {
            ok: false,
            status: 0,
            body: String::new(),
            unreachable: true,
            err_name: "Transport".into(),
            err_message: scrub(&e.to_string()),
        },
    }
}

#[tauri::command]
fn upload_http(
    url: String,
    authorization: String,
    filename: String,
    mime: String,
    data: Vec<u8>,
) -> Result<UploadHttpResult, String> {
    Ok(post_upload(&url, &authorization, &filename, &mime, &data))
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::new().build())
        .setup(|app| {
            let _ = ensure_devices_store(app.handle());
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            lock_devices_file,
            append_upload_log,
            upload_http
        ])
        .run(tauri::generate_context!())
        .expect("error while running AgentMirror desktop");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn post_upload_is_post_not_options() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let h = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = vec![0u8; 8192];
            let n = s.read(&mut buf).unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).into_owned();
            let body = r#"{"path":"/host/uploads/a.png"}"#;
            let resp = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            let _ = s.write_all(resp.as_bytes());
            req
        });
        let r = post_upload(
            &format!("http://{addr}/upload"),
            "Bearer test-secret",
            "a.png",
            "image/png",
            &[1, 2, 3],
        );
        let req = h.join().unwrap();
        assert!(r.ok, "status={} body={}", r.status, r.body);
        assert_eq!(r.status, 200);
        assert!(req.starts_with("POST "), "{req}");
        assert!(!req.contains("OPTIONS"));
        assert!(req.to_ascii_lowercase().contains("authorization:"));
        assert!(req.contains("multipart/form-data"));
    }

    #[test]
    fn secret_shape_refuses_long_blob() {
        assert!(looks_like_secret("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"));
        assert!(looks_like_secret("Authorization: Bearer x"));
        assert!(!looks_like_secret(
            r#"{"n":1,"url":"http://127.0.0.1:9/upload","name":"TypeError"}"#
        ));
    }
}
