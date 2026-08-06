use std::process::Command;
use std::sync::Arc;

use binvia_core::config::store::ConfigStore;
use binvia_core::server::{self, state::AppState};

struct PidFile(std::path::PathBuf);

impl Drop for PidFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

fn stop_gateway(path: &std::path::Path) {
    let Ok(pid) = std::fs::read_to_string(path) else {
        println!("binvia is not running");
        return;
    };
    let pid = pid.trim();
    if !pid.is_empty() {
        #[cfg(unix)]
        let _ = Command::new("kill").args(["-TERM", pid]).status();
        #[cfg(windows)]
        let _ = Command::new("taskkill").args(["/PID", pid, "/T"]).status();
    }
    let _ = std::fs::remove_file(path);
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let store = ConfigStore::new();
    let pid_path = store.path().with_file_name("binvia.pid");
    if std::env::args().nth(1).as_deref() == Some("stop") {
        stop_gateway(&pid_path);
        return;
    }
    let config = match store.load() {
        Ok(config) => config,
        Err(error) => {
            eprintln!("failed to load config: {error}");
            std::process::exit(1);
        }
    };

    if let Some(parent) = pid_path.parent() {
        if let Err(error) = std::fs::create_dir_all(parent) {
            eprintln!("failed to create runtime directory: {error}");
            std::process::exit(1);
        }
    }
    let pid_file = PidFile(pid_path.clone());
    if let Err(error) = std::fs::write(&pid_path, std::process::id().to_string()) {
        eprintln!("failed to write pid file: {error}");
        std::process::exit(1);
    }
    let state = Arc::new(AppState::new(config));
    // 启动 5min 用量定时刷新（首次立即刷新，之后每 5min 一次）。
    {
        let state = Arc::clone(&state);
        tokio::spawn(async move {
            binvia_core::api::usage::refresh_all(&state).await;
            let mut interval = tokio::time::interval(std::time::Duration::from_secs(300));
            interval.tick().await; // 跳过首个立即触发点（已手动刷新）。
            loop {
                interval.tick().await;
                binvia_core::api::usage::refresh_all(&state).await;
            }
        });
    }
    if let Err(error) = server::start(state).await {
        eprintln!("gateway stopped: {error}");
        drop(pid_file);
        std::process::exit(1);
    }
}
