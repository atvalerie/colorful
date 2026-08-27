import { cp, mkdir } from "node:fs/promises";
import { dirname, resolve } from "node:path";

const repoRoot = resolve(import.meta.dir, "..");
const outfileArgument = process.argv[2]?.trim();
if (!outfileArgument) throw new Error("usage: bun scripts/build-provider.ts <output-file>");
const outfile = resolve(process.cwd(), outfileArgument);

const jsdomSyncWorker = /const syncWorkerFile = require\.resolve \? require\.resolve\("\.\/xhr-sync-worker\.js"\) : null;/;
const result = await Bun.build({
  entrypoints: [resolve(repoRoot, "packages/provider-host/src/main.ts")],
  compile: { outfile },
  bytecode: true,
  minify: true,
  plugins: [{
    name: "disable-unused-jsdom-sync-xhr-worker",
    setup(build) {
      build.onLoad({ filter: /XMLHttpRequest-impl\.js$/ }, async ({ path }) => {
        const source = await Bun.file(path).text();
        if (!jsdomSyncWorker.test(source)) {
          throw new Error(`jsdom sync-XHR worker declaration changed: ${path}`);
        }
        return {
          contents: source.replace(jsdomSyncWorker, "const syncWorkerFile = null;"),
          loader: "js",
        };
      });
    },
  }],
});

if (!result.success) {
  for (const message of result.logs) console.error(message);
  process.exit(1);
}

const dictionarySource = resolve(repoRoot, "packages/provider-host/node_modules/kuromoji/dict");
const dictionaryDestination = resolve(dirname(outfile), "colorful-provider-data/kuromoji");
await mkdir(dictionaryDestination, { recursive: true });
await cp(dictionarySource, dictionaryDestination, { recursive: true, force: true });

const smoke = Bun.spawn([outfile], {
  stdin: new Blob(['{"id":1,"type":"status","payload":{}}\n']),
  stdout: "pipe",
  stderr: "pipe",
});
const smokeTimeout = setTimeout(() => smoke.kill(9), 15_000);
const smokeErrorPromise = new Response(smoke.stderr).text();
const smokeReader = smoke.stdout.getReader();
const decoder = new TextDecoder();
let smokeOutput = "";
let status: { id?: number; ok?: boolean } | undefined;
for (;;) {
  const { done, value } = await smokeReader.read();
  if (done) break;
  smokeOutput += decoder.decode(value, { stream: true });
  status = smokeOutput.split(/\r?\n/).flatMap((line) => {
    try { return [JSON.parse(line) as { id?: number; ok?: boolean }]; }
    catch { return []; }
  }).find((message) => message.id === 1);
  if (status) break;
}
if (status) smoke.kill(9);
const smokeExitCode = await smoke.exited;
const smokeError = await smokeErrorPromise;
clearTimeout(smokeTimeout);
if (!status?.ok) {
  throw new Error(`compiled provider smoke test failed (exit ${smokeExitCode})\n${smokeError.trim()}`);
}
