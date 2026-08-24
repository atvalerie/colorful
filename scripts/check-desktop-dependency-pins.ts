import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const read = (path: string) => readFileSync(resolve(root, path), "utf8");
const pins = JSON.parse(read("packaging/desktop-dependencies.json"));
const failures: string[] = [];

function requireText(path: string, text: string): void {
  if (!read(path).includes(text)) failures.push(`${path} must contain ${JSON.stringify(text)}`);
}

function reject(path: string, pattern: RegExp, label: string): void {
  if (pattern.test(read(path))) failures.push(`${path} contains a floating ${label}`);
}

requireText("rust-toolchain.toml", `channel = "${pins.toolchains.rust}"`);
requireText("packaging/linux/Dockerfile", `FROM ${pins.linux.baseImage}`);
requireText("packaging/linux/Dockerfile", `ARG QT_VERSION=${pins.toolchains.qt}`);
requireText("packaging/linux/Dockerfile", `ARG AQT_VERSION=${pins.toolchains.aqtinstall}`);
requireText("packaging/linux/Dockerfile", `ARG CMAKE_VERSION=${pins.toolchains.cmake}`);
requireText("packaging/linux/Dockerfile", `ARG RUST_VERSION=${pins.toolchains.rust}`);
requireText("packaging/linux/Dockerfile", `ARG BUN_VERSION=${pins.toolchains.bun}`);
requireText("packaging/linux/Dockerfile", `ARG BUN_SHA256=${pins.linux.bun.sha256}`);

for (const workflow of [
  ".github/workflows/dev-build.yml",
  ".github/workflows/release.yml",
  ".github/workflows/cache-warm.yml",
]) {
  requireText(workflow, `dtolnay/rust-toolchain@${pins.toolchains.rust}`);
  requireText(workflow, `bun-version: ${pins.toolchains.bun}`);
  reject(workflow, /dtolnay\/rust-toolchain@stable/, "Rust toolchain");
}
for (const workflow of [
  ".github/workflows/dev-build.yml",
  ".github/workflows/release.yml",
]) {
  requireText(workflow, `choco install innosetup --version=${pins.toolchains.innoSetup}`);
}

const providerKit = JSON.parse(read("packages/provider-kit/package.json"));
if (providerKit.devDependencies["@types/bun"] !== pins.toolchains.bun) {
  failures.push("packages/provider-kit must pin @types/bun to the Bun toolchain version");
}
if (!/^\d+\.\d+\.\d+$/.test(providerKit.devDependencies.typescript)) {
  failures.push("packages/provider-kit TypeScript must be an exact version");
}

for (const path of [
  "scripts/provision-linux-packaging.sh",
  "scripts/provision-windows-qt.ps1",
]) {
  reject(path, /releases\/latest|\/download\/latest|\/continuous\//i, "download URL");
  reject(path, /pip install[^\r\n]*--upgrade/i, "pip dependency");
}

if (failures.length) {
  for (const failure of failures) console.error(`dependency pin error: ${failure}`);
  process.exit(1);
}
console.log(`desktop dependency pins are consistent (Rust ${pins.toolchains.rust}, Bun ${pins.toolchains.bun}, Qt ${pins.toolchains.qt})`);
