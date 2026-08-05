#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
npm --prefix "$root_dir/web" install
npm --prefix "$root_dir/web" run build
mkdir -p "$root_dir/binvia-core/web/dist"
cp -R "$root_dir/web/dist/." "$root_dir/binvia-core/web/dist/"
cargo build --manifest-path "$root_dir/binvia-core/Cargo.toml" --release
mkdir -p "$root_dir/bin"
cp "$root_dir/binvia-core/target/release/binvia" "$root_dir/bin/binvia"
