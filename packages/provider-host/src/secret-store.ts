const ATTRIBUTES = ["service", "colorful", "provider", "tidal"] as const;

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
  const result = await runSecretTool(["lookup", ...ATTRIBUTES]);
  const token = result.stdout.trim();
  return result.exitCode === 0 && token ? token : null;
}

export async function saveRefreshToken(token: string): Promise<boolean> {
  const result = await runSecretTool(["store", "--label=Colorful TIDAL account", ...ATTRIBUTES], token);
  return result.exitCode === 0;
}

export async function clearRefreshToken(): Promise<void> {
  await runSecretTool(["clear", ...ATTRIBUTES]);
}

