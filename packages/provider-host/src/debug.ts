type DebugFields = Record<string, string | number | boolean | null | undefined>;

export function debugLog(scope: string, event: string, fields: DebugFields = {}): void {
  const safeFields = Object.fromEntries(Object.entries(fields)
    .filter((entry): entry is [string, string | number | boolean | null] => entry[1] !== undefined));
  process.stderr.write(`[colorful-debug] ${JSON.stringify({ scope, event, ...safeFields })}\n`);
}
