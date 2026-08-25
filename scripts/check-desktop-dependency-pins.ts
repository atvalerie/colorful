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

if (!/^[0-9a-f]{40}$/.test(pins.mpv.sourceCommit)) {
  failures.push("mpv.sourceCommit must be a full 40-character Git commit");
}
const mpvVersionCommit = pins.mpv.sourceVersion.match(/-g([0-9a-f]{7,40})$/)?.[1];
if (!mpvVersionCommit || !pins.mpv.sourceCommit.startsWith(mpvVersionCommit)) {
  failures.push("mpv.sourceVersion must identify mpv.sourceCommit");
}
if (!/^\d+\.\d+\.\d+$/.test(pins.mpv.minimumClientApi)) {
  failures.push("mpv.minimumClientApi must be a three-part version");
}
if (!pins.windows.mpv.url.includes(pins.mpv.sourceCommit.slice(0, 10))) {
  failures.push("the Windows libmpv archive must identify the shared mpv source commit");
}
for (const [label, hash] of [
  ["Windows 7-Zip", pins.windows.sevenZip.sha256],
  ["mpv source archive", pins.mpv.sourceArchiveSha256],
  ["Linux libmpv FFmpeg", pins.linux.libmpv.ffmpeg.sha256],
  ["Linux libplacebo", pins.linux.libmpv.libplacebo.sha256],
  ["Linux fast_float", pins.linux.libmpv.fastFloat.sha256],
  ["Linux Vulkan-Headers", pins.linux.libmpv.vulkanHeaders.sha256],
]) {
  if (!/^[0-9a-f]{64}$/.test(hash)) failures.push(`${label} must have a lowercase SHA-256 pin`);
}

requireText("rust-toolchain.toml", `channel = "${pins.toolchains.rust}"`);
requireText("packaging/linux/Dockerfile", `FROM ${pins.linux.baseImage}`);
requireText("packaging/linux/Dockerfile", `ARG QT_VERSION=${pins.toolchains.qt}`);
requireText("packaging/linux/Dockerfile", `ARG AQT_VERSION=${pins.toolchains.aqtinstall}`);
requireText("packaging/linux/Dockerfile", `ARG CMAKE_VERSION=${pins.toolchains.cmake}`);
requireText("packaging/linux/Dockerfile", `ARG MESON_VERSION=${pins.toolchains.meson}`);
requireText("packaging/linux/Dockerfile", `ARG RUST_VERSION=${pins.toolchains.rust}`);
requireText("packaging/linux/Dockerfile", `ARG BUN_VERSION=${pins.toolchains.bun}`);
requireText("packaging/linux/Dockerfile", `ARG BUN_SHA256=${pins.linux.bun.sha256}`);
requireText("packaging/linux/Dockerfile", "COPY packaging/desktop-dependencies.json /tmp/desktop-dependencies.json");
requireText("packaging/linux/build-mpv-source.sh", "pin mpv.sourceCommit");
requireText("packaging/linux/build-mpv-source.sh", "mpv-source-version");
requireText("packaging/linux/build-mpv-source.sh", "pin linux.libmpv.ffmpeg.sha256");
requireText("packaging/linux/build-mpv-source.sh", "pin linux.libmpv.vulkanHeaders.sha256");
requireText("scripts/provision-windows-qt.ps1", "$pins.mpv.sourceVersion");
requireText("scripts/build-windows-qt.ps1", "-DCOLORFUL_EXPECTED_MPV_VERSION");
requireText("scripts/build-linux.sh", "-DCOLORFUL_EXPECTED_MPV_VERSION");

for (const workflow of [
  ".github/workflows/dev-build.yml",
  ".github/workflows/release.yml",
  ".github/workflows/cache-warm.yml",
]) {
  requireText(workflow, `dtolnay/rust-toolchain@${pins.toolchains.rust}`);
  requireText(workflow, `bun-version: ${pins.toolchains.bun}`);
  requireText(workflow, "COLORFUL_MPV_MODE: official");
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
