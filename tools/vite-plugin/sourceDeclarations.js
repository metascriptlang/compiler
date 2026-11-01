import { randomUUID } from "node:crypto";
import { existsSync, lstatSync, mkdirSync, readFileSync, renameSync, rmdirSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, join, parse, resolve, win32 } from "node:path";
import { canonicalPath, sourceRootOfOutput } from "./compilerCore.js";

const ledgerName = ".msc-source-ledger.json";
const leaseName = ".msc-source-lease";

function safePath(file) {
 const { root } = parse(file);
 let current = root;
 for (const part of file.slice(root.length).split(/[\\/]/).filter(Boolean)) {
  current = join(current, part);
  let stat;
  try { stat = lstatSync(current); } catch (error) { if (error.code === "ENOENT") continue; throw error; }
  if (stat.isSymbolicLink()) throw new Error(`Source declaration symlink refused: ${current}`);
  if (current !== file && !stat.isDirectory()) throw new Error(`Source declaration parent is not a directory: ${current}`);
 }
 return file;
}

function relativeOutput(out) {
 if (typeof out !== "string" || !out || out.includes("\0") || isAbsolute(out) || win32.isAbsolute(out) || out.includes("\\") || out.split("/").some(part => !part || part === "." || part === ".." || part.includes(":") || part.startsWith(".msc-"))) {
  throw new Error(`Source declaration reserved or invalid path: ${out}`);
 }
 if (out !== "package.json" && !/\.d\.(?:ms\.ts|jms\.ts|ts)$/.test(out)) throw new Error(`Invalid source declaration family path: ${out}`);
 return out;
}

export function createSourceDeclarationPublisher(options, projectRoot) {
 const sourceRoot = canonicalPath(resolve(projectRoot, options.rootDir ?? projectRoot));
 safePath(sourceRoot);
 if (!lstatSync(sourceRoot).isDirectory()) throw new Error("Source declaration rootDir must be an existing directory");
 const root = safePath(resolve(projectRoot, options.outDir));
 mkdirSync(root, {recursive:true});
 const lease = join(root, leaseName);
 try { mkdirSync(lease); } catch (error) {
  throw new Error(`Source declaration exclusive lifetime lease held or exists: ${lease}; leases are never automatically reclaimed, even after an ungraceful exit`, {cause:error});
 }
 const token = randomUUID();
 const ownerPath = join(lease, "owner.json");
 const ownerText = JSON.stringify({pid:process.pid, token});
 let closed = false;
 let owned = [];
 const pathOf = out => safePath(join(root, relativeOutput(out)));
 const ledgerPath = join(root, ledgerName);
 const metadata = files => JSON.stringify({schema:1, sourceRoot, files});
 const assertOwner = () => {
  if (closed || readFileSync(safePath(ownerPath), "utf8") !== ownerText) throw new Error(`Source declaration lease is not owned: ${lease}`);
 };
 const onExit = () => { try { close(); } catch {} };
 const close = () => {
  if (closed) return;
  try {
   try { safePath(ownerPath); if (readFileSync(ownerPath, "utf8") !== ownerText) return; } catch { return; }
   unlinkSync(ownerPath);
   rmdirSync(lease);
  } finally {
   closed = true;
   process.off("exit", onExit);
  }
 };
 const validateOwned = () => {
  for (const out of owned) {
   const file = pathOf(out);
   if (existsSync(file) && !lstatSync(file).isFile()) throw new Error(`Owned source declaration is not a file: ${file}`);
  }
  safePath(ledgerPath);
 };
 const invalidate = () => {
  assertOwner(); validateOwned();
  const errors = [];
  for (const out of owned) {
   try { const file = pathOf(out); if (existsSync(file)) unlinkSync(file); }
   catch (error) { errors.push(`${out}: ${error.message}`); }
  }
  if (errors.length) throw new Error(`Source declaration invalidation failed: ${errors.join("; ")}`);
 };
 const atomicWrite = (file, text) => {
  safePath(file); mkdirSync(dirname(file), {recursive:true});
  const temporary = safePath(join(dirname(file), `.msc-${token}-${randomUUID()}.tmp`));
  try { writeFileSync(temporary, text, {flag:"wx"}); renameSync(temporary, safePath(file)); }
  finally { if (existsSync(temporary)) unlinkSync(temporary); }
 };
 try {
  writeFileSync(ownerPath, ownerText, {flag:"wx"});
  process.on("exit", onExit);
  safePath(ledgerPath);
  if (existsSync(ledgerPath)) {
   const ledger = JSON.parse(readFileSync(ledgerPath, "utf8"));
   if (ledger.schema !== 1 || ledger.sourceRoot !== sourceRoot || !Array.isArray(ledger.files) || new Set(ledger.files).size !== ledger.files.length) throw new Error(`Source declaration ledger identity mismatch: ${ledgerPath}`);
   owned = ledger.files.map(relativeOutput);
  }
  invalidate();
 } catch (error) { close(); throw error; }
 return Object.freeze({
  sourceRoot,
  invalidate,
  close,
  publish(graph) {
   assertOwner(); validateOwned();
   if (graph.sourceDeclarationRoot !== "_source_declarations" || !graph.sourceDeclarationPackage) throw new Error("Missing compiler source declaration family");
   const family = [graph.sourceDeclarationPackage, ...graph.sourceDeclarations];
   const plan = family.map(artifact => ({out:relativeOutput(sourceRootOfOutput(graph.sourceDeclarationRoot, artifact.out)), text:artifact.text}));
   if (plan[0].out !== "package.json" || plan[0].text.trim() !== '{"type":"module"}') {
    const metadata = JSON.parse(plan[0].text);
    if (plan[0].out !== "package.json" || metadata?.type !== "module" || Object.keys(metadata).length !== 1) throw new Error("Invalid compiler source declaration package");
   }
   const names = new Set();
   for (const item of plan) {
    if (names.has(item.out)) throw new Error(`Duplicate source declaration output collision: ${item.out}`);
    names.add(item.out);
    const file = pathOf(item.out);
    if (typeof item.text !== "string") throw new Error(`Invalid source declaration text: ${item.out}`);
    if (existsSync(file) && (!owned.includes(item.out) || !lstatSync(file).isFile())) throw new Error(`Unowned source declaration collision: ${file}`);
   }
   for (const out of names) for (const other of names) if (other.startsWith(`${out}/`)) throw new Error(`Source declaration path collision: ${out}`);
   invalidate();
   const written = [];
   try {
    for (const item of plan) { atomicWrite(pathOf(item.out), item.text); written.push(item.out); }
    atomicWrite(ledgerPath, metadata([...names]));
    owned = [...names];
   } catch (error) {
    const failures = [];
    for (const out of written) try { unlinkSync(pathOf(out)); } catch (rollback) { failures.push(`${out}: ${rollback.message}`); }
    throw new Error(`Source declaration publication failed: ${error.message}${failures.length ? `; rollback failed: ${failures.join("; ")}` : ""}`, {cause:error});
   }
  },
 });
}

export function sourceDeclarationWatchRoots(projectRoot, sourceRoot, dependencies = []) {
 const roots = new Set([canonicalPath(resolve(projectRoot)), sourceRoot]);
 for (const file of dependencies) {
  if (![...roots].some(root => file === root || file.startsWith(`${root}/`))) {
   const parent = dirname(file);
   if (parent !== parse(parent).root) roots.add(parent);
  }
 }
 return [...roots];
}

export function sourceDeclarationOutputPattern(options, projectRoot, workspace) {
 const paths = [resolve(projectRoot, options.outDir), resolve(projectRoot, workspace ?? "node_modules/.metascript")];
 return new RegExp(`^(?:${paths.map(path => path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("|")})(?:[\\\\/]|$)`);
}
