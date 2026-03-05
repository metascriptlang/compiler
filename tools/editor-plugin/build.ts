import { join, dirname } from 'path';
import { copyFile, mkdir, readdir, readFile, writeFile } from 'fs/promises';

const ROOT = import.meta.dir; // tools/editor-plugin
const COMMON_DIR = join(ROOT, 'common');
const NVIM_DIR = join(ROOT, 'metascript.nvim');
const VSCODE_DIR = join(ROOT, 'vscode');
const ZED_DIR = join(ROOT, 'zed');

async function syncSnippets() {
  console.log('Syncing snippets...');
  const snippetSource = join(COMMON_DIR, 'snippets', 'metascript.json');
  const nvimDest = join(NVIM_DIR, 'snippets', 'metascript.json');
  const vscodeDest = join(VSCODE_DIR, 'snippets', 'metascript.json');

  await ensureDir(dirname(nvimDest));
  await ensureDir(dirname(vscodeDest));

  await copyFile(snippetSource, nvimDest);
  await copyFile(snippetSource, vscodeDest);
  console.log('  Snippets synced to nvim, vscode.');
}

async function syncQueries() {
  console.log('Syncing queries...');
  const nvimQueryDir = join(NVIM_DIR, 'queries', 'metascript');
  const tsQueryDir = join(NVIM_DIR, 'tree-sitter', 'queries');

  await ensureDir(tsQueryDir);

  const files = await readdir(nvimQueryDir);
  for (const file of files) {
    if (file.endsWith('.scm')) {
      await copyFile(join(nvimQueryDir, file), join(tsQueryDir, file));
    }
  }
  console.log(`  ${files.filter(f => f.endsWith('.scm')).length} query files synced to tree-sitter/queries/.`);
}

async function syncZed() {
  console.log('Syncing Zed assets...');
  const nvimQueryDir = join(NVIM_DIR, 'queries', 'metascript');
  const zedQueryDir = join(ZED_DIR, 'languages', 'metascript');

  await ensureDir(zedQueryDir);

  // Zed uses: highlights, indents, injections (not folds, locals, textobjects)
  const zedQueryFiles = ['highlights.scm', 'indents.scm', 'injections.scm'];

  for (const file of zedQueryFiles) {
    const src = join(nvimQueryDir, file);
    const dest = join(zedQueryDir, file);
    let content = await readFile(src, 'utf-8');

    // Adapt Neovim-specific predicates for Zed
    content = content.replace(/#lua-match\?/g, '#match?');

    // Remove @spell captures (Neovim-only)
    content = content.replace(/ @spell/g, '');

    await writeFile(dest, content);
  }
  console.log(`  ${zedQueryFiles.length} query files synced to zed/ (adapted for Zed).`);
}

async function ensureDir(path: string) {
  try {
    await mkdir(path, { recursive: true });
  } catch (e: any) {
    if (e.code !== 'EEXIST') throw e;
  }
}

async function main() {
  console.log('Building MetaScript Editor Plugins Assets...');

  await syncSnippets();
  await syncQueries();
  await syncZed();

  // Future: Sync keywords from src/lexer/token.ms to TextMate and Grammar.js
  // Future: Sync configuration (indentation, comments) from common config

  console.log('Done.');
}

main().catch(console.error);
