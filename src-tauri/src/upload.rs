use serde::{Deserialize, Serialize};
use tauri::Manager;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

#[cfg(target_os = "macos")]
use objc::{class, msg_send, sel, sel_impl};
#[cfg(target_os = "macos")]
use objc::runtime::Object;

#[derive(Debug, Serialize)]
pub struct ClipboardImage {
    pub name: String,
    pub mime: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Deserialize)]
struct UploadResponse { path: String }

fn scrub_url(url: &str) -> String {
    let no_query = url.split(['?', '#']).next().unwrap_or(url);
    if let Some(scheme) = no_query.find("://") {
        let head = &no_query[..scheme + 3];
        let rest = &no_query[scheme + 3..];
        let host = rest.rsplit_once('@').map(|(_, h)| h).unwrap_or(rest);
        return format!("{head}{host}");
    }
    "<invalid-url>".to_string()
}

fn safe_filename(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("image");
    let clean: String = base.chars().map(|c| if c == '\r' || c == '\n' || c == '"' { '_' } else { c }).collect();
    if clean.is_empty() { "image".to_string() } else { clean }
}

fn multipart(filename: &str, mime: &str, bytes: &[u8], boundary: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes.len() + 256);
    out.extend_from_slice(format!(
        "--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{}\"\r\nContent-Type: {mime}\r\n\r\n",
        safe_filename(filename)
    ).as_bytes());
    out.extend_from_slice(bytes);
    out.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    out
}

fn upload_once<F>(url: &str, token: &str, filename: &str, mime: &str, bytes: &[u8], mut log: F) -> Result<String, String>
where F: FnMut(&str, Option<u16>, Option<&str>, Option<&str>) {
    if bytes.is_empty() { return Err("invalid_file: empty image".to_string()); }
    let boundary = format!("AgentMirrorBoundary{}", unix_ms());
    let body = multipart(filename, mime, bytes, &boundary);
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .build();
    let safe_url = scrub_url(url);
    log(&safe_url, None, None, None);
    let request = agent.request("POST", url)
        .set("Authorization", &format!("Bearer {token}"))
        .set("Content-Type", &format!("multipart/form-data; boundary={boundary}"));
    let response = match request.send_bytes(&body) {
        Ok(r) => r,
        Err(ureq::Error::Status(status, response)) => {
            let code = if status == 401 { "unauthorized" } else { "http_status" };
            log(&safe_url, Some(status), Some(code), None);
            let _ = response.into_string();
            return Err(format!("{code}: HTTP {status}"));
        }
        Err(ureq::Error::Transport(err)) => {
            log(&safe_url, None, Some("unreachable"), Some(&err.to_string()));
            return Err("unreachable: daemon unavailable".to_string());
        }
    };
    let status = response.status();
    let text = response.into_string().map_err(|e| format!("invalid_response: {e}"))?;
    let parsed: UploadResponse = serde_json::from_str(&text)
        .map_err(|_| "invalid_response: upload response is not JSON".to_string())?;
    if !Path::new(&parsed.path).is_absolute() {
        return Err("invalid_response: upload path is not absolute".to_string());
    }
    log(&safe_url, Some(status), Some("ok"), None);
    Ok(parsed.path)
}

fn unix_ms() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis()
}

fn append_log(app: &tauri::AppHandle, url: &str, status: Option<u16>, code: Option<&str>, exception: Option<&str>) {
    let Ok(dir) = app.path().app_data_dir() else { return };
    let _ = fs::create_dir_all(&dir);
    let path = dir.join("upload.log");
    let line = format!("time={} attempt=1 url={} status={} exception={} info={}\n",
        unix_ms(), url, status.map_or("none".to_string(), |x| x.to_string()),
        code.unwrap_or("none"), exception.unwrap_or("none").replace(['\r', '\n'], " "));
    if let Ok(mut file) = OpenOptions::new().create(true).append(true).open(&path) {
        let _ = file.write_all(line.as_bytes());
        #[cfg(unix)] {
            use std::os::unix::fs::PermissionsExt;
            if let Ok(meta) = file.metadata() {
                let mut perms = meta.permissions();
                perms.set_mode(0o600);
                let _ = fs::set_permissions(&path, perms);
            }
        }
    }
}

#[tauri::command]
pub fn upload_http(app: tauri::AppHandle, url: String, token: String, filename: String, mime: String, bytes: Vec<u8>) -> Result<String, String> {
    upload_once(&url, &token, &filename, &mime, &bytes,
        |safe_url, status, code, info| append_log(&app, safe_url, status, code, info))
}

#[tauri::command]
pub fn read_clipboard_image() -> Result<ClipboardImage, String> {
    #[cfg(target_os = "macos")]
    { return read_macos_clipboard(); }
    #[cfg(not(target_os = "macos"))]
    { Err("unsupported_platform: clipboard image reader is macOS-only".to_string()) }
}

#[cfg(target_os = "macos")]
fn read_macos_clipboard() -> Result<ClipboardImage, String> {
    let formats = [("public.png", "image/png", "clipboard.png"), ("public.jpeg", "image/jpeg", "clipboard.jpg"), ("public.tiff", "image/tiff", "clipboard.tiff")];
    unsafe {
        let pb: *mut Object = msg_send![class!(NSPasteboard), generalPasteboard];
        if pb.is_null() { return Err("clipboard_unavailable: pasteboard unavailable".to_string()); }
        for (ut_type, mime, name) in formats {
            let c = std::ffi::CString::new(ut_type).unwrap();
            let s: *mut Object = msg_send![class!(NSString), stringWithUTF8String: c.as_ptr()];
            let data: *mut Object = msg_send![pb, dataForType: s];
            if data.is_null() { continue; }
            let len: usize = msg_send![data, length];
            let ptr: *const u8 = msg_send![data, bytes];
            if ptr.is_null() || len == 0 { continue; }
            return Ok(ClipboardImage { name: name.to_string(), mime: mime.to_string(), bytes: std::slice::from_raw_parts(ptr, len).to_vec() });
        }
    }
    Err("no_image: pasteboard has no image item".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;

    fn server(response: &'static str, check_request: bool) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = Vec::new();
            let mut chunk = [0; 1024];
            loop {
                let n = stream.read(&mut chunk).unwrap();
                if n == 0 { break; }
                request.extend_from_slice(&chunk[..n]);
                let Some(header_end) = request.windows(4).position(|x| x == b"\r\n\r\n").map(|x| x + 4) else { continue; };
                let headers = String::from_utf8_lossy(&request[..header_end]);
                let length = headers.lines().find_map(|line| line.strip_prefix("Content-Length:")?.trim().parse::<usize>().ok()).unwrap_or(0);
                if request.len() >= header_end + length { break; }
            }
            if check_request {
                let request = String::from_utf8_lossy(&request);
                assert!(request.contains("Authorization: Bearer test-token"));
                assert!(request.contains("multipart/form-data"));
            }
            stream.write_all(response.as_bytes()).unwrap();
        });
        format!("http://{addr}/upload")
    }

    #[test]
    fn upload_http_sends_multipart_and_returns_absolute_path() {
        let url = server("HTTP/1.1 200 OK\r\nContent-Length: 25\r\n\r\n{\"path\":\"/tmp/image.png\"}", true);
        let path = upload_once(&url, "test-token", "x.png", "image/png", b"PNG", |_, _, _, _| {}).unwrap();
        assert_eq!(path, "/tmp/image.png");
    }

    #[test]
    fn upload_http_maps_401_to_unauthorized() {
        let url = server("HTTP/1.1 401 Unauthorized\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx", false);
        let err = upload_once(&url, "test-token", "x.png", "image/png", b"PNG", |_, _, _, _| {}).unwrap_err();
        assert!(err.starts_with("unauthorized:"));
    }

    #[test]
    fn upload_http_maps_connection_failure_to_unreachable() {
        assert!(upload_once("http://127.0.0.1:1/upload", "test-token", "x.png", "image/png", b"PNG", |_, _, _, _| {}).unwrap_err().starts_with("unreachable:"));
    }
}
