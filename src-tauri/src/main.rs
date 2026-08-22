use std::fs;
use std::os::unix::fs::PermissionsExt;

use tauri::Manager;
use tauri_plugin_store::StoreExt;

#[cfg(target_os = "macos")]
use objc::{msg_send, sel, sel_impl};

/// Filename under $APP_DATA. Keep in sync with src/core/store.js.
const DEVICES_FILE: &str = "devices.json";

fn devices_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(dir.join(DEVICES_FILE))
}

fn chmod600(path: &std::path::Path) -> Result<(), String> {
    let mut perms = fs::metadata(path).map_err(|e| e.to_string())?.permissions();
    perms.set_mode(0o600);
    fs::set_permissions(path, perms).map_err(|e| e.to_string())
}

/// Ensure the store file exists with 0600 so a token never lands in a world-readable file.
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

/// Hide AppKit traffic lights; keep the standard buttons in the window so
/// Cmd+W / the Close menu still work. Do not set decorations=false.
#[cfg(target_os = "macos")]
#[allow(unexpected_cfgs)]
fn hide_native_traffic_lights(win: &tauri::WebviewWindow) {
    let Ok(ptr) = win.ns_window() else { return };
    let ns_window = ptr as *mut objc::runtime::Object;
    unsafe {
        // NSWindowCloseButton=0, Miniaturize=1, Zoom=2
        for id in [0_usize, 1, 2] {
            let btn: *mut objc::runtime::Object = msg_send![ns_window, standardWindowButton: id];
            if !btn.is_null() {
                let _: () = msg_send![btn, setHidden: true];
            }
        }
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::new().build())
        .setup(|app| {
            let _ = ensure_devices_store(app.handle());
            if let Some(w) = app.get_webview_window("main") {
                #[cfg(target_os = "macos")]
                hide_native_traffic_lights(&w);
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .invoke_handler(tauri::generate_handler![lock_devices_file])
        .run(tauri::generate_context!())
        .expect("error while running AgentMirror desktop");
}
