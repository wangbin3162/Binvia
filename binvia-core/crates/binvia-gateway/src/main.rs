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
    if let Err(error) = server::start(state).await {
        eprintln!("gateway stopped: {error}");
        drop(pid_file);
        std::process::exit(1);
    }
}
