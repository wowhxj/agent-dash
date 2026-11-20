// Import into the authenticated local DSH Host before retiring a Claude source.
import { execFileSync } from 'node:child_process';
import { closeSync, fstatSync, readFileSync, realpathSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { openRegular, retireClaude, validateMigrationPaths } from './agent-dash-convert.mjs';

function runHelper(name, args, input) {
  const script = fileURLToPath(new URL(name, import.meta.url));
  try {
    return JSON.parse(execFileSync(process.execPath, [script, ...args], {
      input, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 16 * 1024 * 1024,
    }));
  } catch (error) {
    throw new Error(error.stderr?.trim() || `Could not run ${name}`);
  }
}

export function migrate(args, credentials, importZip = (zip, cwd) =>
  runHelper('./agent-dash-dsh-import.mjs', [zip, cwd], credentials)) {
  const [backend, source, sourceId, cwd, piRoot, archiveRoot] = args;
  if (args.length !== 6 || !['claude', 'codex'].includes(backend)) throw new Error('Expected native source and destination directories');
  if (backend === 'claude') validateMigrationPaths(source, sourceId, piRoot, archiveRoot);
  const fd = backend === 'claude' ? openRegular(source) : undefined;
  try {
    const initial = fd === undefined ? null : fstatSync(fd, { bigint: true });
    const raw = initial && readFileSync(fd);
    const report = runHelper('./agent-dash-dsh-export.mjs', args);
    if (raw && !raw.equals(readFileSync(report.archive))) throw new Error('Claude transcript changed during export; source retained');
    const zip = readFileSync(report.file);
    const target = importZip(report.file, cwd);
    if (!target || typeof target.id !== 'string' || !target.id || target.id === report.id ||
        !target.workspaceId || target.zipSha256 !== createHash('sha256').update(zip).digest('hex') ||
        realpathSync(target.cwd) !== realpathSync(cwd)) {
      throw new Error('DSH did not verify a native session in the requested workspace; source retained');
    }
    report.id = target.id;
    report.workspaceId = target.workspaceId;
    if (initial) {
      try {
        retireClaude(source, initial, raw, report.archive, report.file, bytes => bytes.equals(zip), report.notes);
        report.migration = 'moved';
      } catch (error) {
        report.migration = 'retained';
        report.migrationError = error.message;
      }
    }
    return report;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  try { console.log(JSON.stringify(migrate(process.argv.slice(2), readFileSync(0)))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
