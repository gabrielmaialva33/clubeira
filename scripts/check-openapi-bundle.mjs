import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const projectRoot = resolve(import.meta.dirname, "..");
const temporaryDirectory = mkdtempSync(join(tmpdir(), "clubeira-openapi-"));
const generatedBundle = join(temporaryDirectory, "v1.json");
const publishedBundle = join(projectRoot, "priv/static/openapi/v1.json");
const redocly = join(
  projectRoot,
  "node_modules",
  ".bin",
  process.platform === "win32" ? "redocly.cmd" : "redocly",
);

try {
  const result = spawnSync(
    redocly,
    ["bundle", "clubeira@v1", "--output", generatedBundle, "--ext", "json"],
    { cwd: projectRoot, stdio: "inherit" },
  );

  if (result.error) throw result.error;
  if (result.status !== 0) process.exitCode = result.status ?? 1;

  if (process.exitCode === undefined) {
    const current = readFileSync(publishedBundle);
    const generated = readFileSync(generatedBundle);

    if (!current.equals(generated)) {
      console.error(
        "OpenAPI bundle is stale. Run `npm run api:bundle` and include the result.",
      );
      process.exitCode = 1;
    }
  }
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
