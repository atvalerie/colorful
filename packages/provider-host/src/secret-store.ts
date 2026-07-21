function attributes(provider: string): string[] {
  return ["service", "colorful", "provider", provider];
}

async function runSecretTool(args: string[], stdin?: string): Promise<{ exitCode: number; stdout: string }> {
  try {
    const process = Bun.spawn(["secret-tool", ...args], {
      stdin: stdin === undefined ? "ignore" : new Blob([stdin]),
      stdout: "pipe",
      stderr: "ignore",
      env: processEnvWithoutToken(),
    });
    const [exitCode, stdout] = await Promise.all([process.exited, new Response(process.stdout).text()]);
    return { exitCode, stdout };
  } catch {
    return { exitCode: 127, stdout: "" };
  }
}

function processEnvWithoutToken(): Record<string, string> {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) if (value !== undefined) env[key] = value;
  return env;
}

export async function loadRefreshToken(): Promise<string | null> {
  return loadProviderSecret("tidal");
}

export async function loadProviderSecret(provider: string): Promise<string | null> {
  const result = await runSecretTool(["lookup", ...attributes(provider)]);
  const token = result.stdout.trim();
  return result.exitCode === 0 && token ? token : null;
}

export async function saveRefreshToken(token: string): Promise<boolean> {
  return saveProviderSecret("tidal", "colorful TIDAL account", token);
}

export async function saveProviderSecret(provider: string, label: string, secret: string): Promise<boolean> {
  const result = await runSecretTool(["store", `--label=${label}`, ...attributes(provider)], secret);
  return result.exitCode === 0;
}

export async function clearRefreshToken(): Promise<void> {
  await clearProviderSecret("tidal");
}

export async function clearProviderSecret(provider: string): Promise<void> {
  await runSecretTool(["clear", ...attributes(provider)]);
}
