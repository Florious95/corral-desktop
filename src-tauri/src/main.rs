#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs;

use tauri::Manager;
use tauri_plugin_store::StoreExt;

mod upload;
mod wsl;

/// Filename under $APP_DATA. Keep in sync with src/core/store.js.
const DEVICES_FILE: &str = "devices.json";
const LEGACY_APP_IDENTIFIER: &str = "com.agentmirror.desktop";

fn devices_path(app: &tauri::AppHandle) -> Result<std::path::PathBuf, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    Ok(dir.join(DEVICES_FILE))
}

#[cfg(unix)]
fn chmod600(path: &std::path::Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;

    let mut perms = fs::metadata(path).map_err(|e| e.to_string())?.permissions();
    perms.set_mode(0o600);
    fs::set_permissions(path, perms).map_err(|e| e.to_string())
}

#[cfg(windows)]
fn chmod600(_path: &std::path::Path) -> Result<(), String> {
    // The app-data directory is ACL-protected by Windows for the logged-in user.
    Ok(())
}

fn migrate_legacy_store(
    target_dir: &std::path::Path,
    legacy_dir: &std::path::Path,
) -> Result<(), String> {
    if target_dir.exists() {
        return Ok(());
    }
    let legacy_file = legacy_dir.join(DEVICES_FILE);
    if !legacy_file.is_file() {
        return Ok(());
    }
    fs::create_dir_all(target_dir).map_err(|e| e.to_string())?;
    let target_file = target_dir.join(DEVICES_FILE);
    fs::copy(&legacy_file, &target_file).map_err(|e| e.to_string())?;
    chmod600(&target_file)?;
    Ok(())
}

fn migrate_legacy_app_data(app: &tauri::AppHandle) -> Result<(), String> {
    let target_dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let parent = target_dir
        .parent()
        .ok_or_else(|| "invalid_app_data_path".to_string())?;
    migrate_legacy_store(&target_dir, &parent.join(LEGACY_APP_IDENTIFIER))
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn migrates_legacy_devices_store_without_overwriting_new_data() {
        let root = std::env::temp_dir().join(format!(
            "corral-app-data-{}",
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let legacy = root.join("com.agentmirror.desktop");
        let current = root.join("com.corral.desktop");
        fs::create_dir_all(&legacy).unwrap();
        fs::write(legacy.join(DEVICES_FILE), b"legacy").unwrap();

        migrate_legacy_store(&current, &legacy).unwrap();
        assert_eq!(fs::read(current.join(DEVICES_FILE)).unwrap(), b"legacy");
        fs::write(current.join(DEVICES_FILE), b"new").unwrap();
        migrate_legacy_store(&current, &legacy).unwrap();
        assert_eq!(fs::read(current.join(DEVICES_FILE)).unwrap(), b"new");
        let _ = fs::remove_dir_all(root);
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_store::Builder::new().build())
        .setup(|app| {
            migrate_legacy_app_data(app.handle())?;
            ensure_devices_store(app.handle())?;
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            lock_devices_file,
            wsl::check_wsl_environment,
            wsl::install_wsl_service,
            wsl::read_wsl_service_token,
            wsl::get_wsl_pairing_token,
            wsl::start_wsl_service,
            upload::upload_http,
            upload::read_clipboard_image,
            upload::read_clipboard_files,
        ])
        .run(tauri::generate_context!())
        .expect("error while running Corral desktop");
}
