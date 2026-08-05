use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::config::RouteConfig;

pub struct ConfigStore {
    path: PathBuf,
}

impl ConfigStore {
    pub fn new() -> Self {
        let path = Self::default_path();
        Self { path }
    }

    pub fn with_path(path: PathBuf) -> Self {
        Self { path }
    }

    fn default_path() -> PathBuf {
        if let Ok(env_path) = std::env::var("BINVIA_CONFIG") {
            return PathBuf::from(env_path);
        }
        let base = dirs::config_dir().unwrap_or_else(|| PathBuf::from("~/.config"));
        base.join("binvia").join("config.json")
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load(&self) -> Result<RouteConfig, ConfigStoreError> {
        if !self.path.exists() {
            return Ok(RouteConfig::default());
        }

        let file = std::fs::File::open(&self.path).map_err(|e| ConfigStoreError::Io(e))?;
        let reader = std::io::BufReader::new(file);

        let mut config: RouteConfig =
            serde_json::from_reader(reader).map_err(|e| ConfigStoreError::Parse(e))?;

        if config.version < 2 {
            let backup = self.path.with_extension("json.v1.bak");
            std::fs::copy(&self.path, &backup).map_err(|e| ConfigStoreError::Io(e))?;

            config.version = 2;
            self.save_inner(&config)?;
        }

        Ok(config)
    }

    pub fn save(&self, config: &RouteConfig) -> Result<(), ConfigStoreError> {
        self.save_inner(config)
    }

    fn save_inner(&self, config: &RouteConfig) -> Result<(), ConfigStoreError> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| ConfigStoreError::Io(e))?;
        }

        let file = std::fs::File::create(&self.path).map_err(|e| ConfigStoreError::Io(e))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(std::fs::Permissions::from_mode(0o600))
                .map_err(|e| ConfigStoreError::Io(e))?;
        }

        let writer = std::io::BufWriter::new(file);
        let formatter = serde_json::ser::PrettyFormatter::with_indent(b"  ");
        let mut ser = serde_json::Serializer::with_formatter(writer, formatter);
        config
            .serialize(&mut ser)
            .map_err(|e| ConfigStoreError::Serialize(e))?;

        Ok(())
    }
}

impl Default for ConfigStore {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug)]
pub enum ConfigStoreError {
    Io(std::io::Error),
    Parse(serde_json::Error),
    Serialize(serde_json::Error),
}

impl std::fmt::Display for ConfigStoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ConfigStoreError::Io(e) => write!(f, "IO error: {}", e),
            ConfigStoreError::Parse(e) => write!(f, "parse error: {}", e),
            ConfigStoreError::Serialize(e) => write!(f, "serialize error: {}", e),
        }
    }
}

impl std::error::Error for ConfigStoreError {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_and_loads_config() {
        let path =
            std::env::temp_dir().join(format!("binvia-config-{}.json", uuid::Uuid::new_v4()));
        let store = ConfigStore::with_path(path.clone());
        let config = RouteConfig::default();
        store.save(&config).expect("save config");
        let loaded = store.load().expect("load config");
        assert_eq!(loaded.host, config.host);
        assert_eq!(loaded.port, config.port);
        let _ = std::fs::remove_file(path);
    }
}
