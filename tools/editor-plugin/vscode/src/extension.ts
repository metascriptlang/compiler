import * as path from 'path';
import * as fs from 'fs';
import * as os from 'os';
import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  State,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let statusBarItem: vscode.StatusBarItem;
let outputChannel: vscode.OutputChannel;
let restartCount = 0;
const MAX_RESTARTS = 5;


// ---------------------------------------------------------------------------
// Material Icon Theme integration
// ---------------------------------------------------------------------------

// Per-extension icon colors (Material Design palette)
// .ms = blue (primary), .cms = orange (C backend), .jms = yellow (JS backend),
// .ems = purple (Erlang backend), .wms = teal (WASM), .rms = red (runtime)
const MS_ICON_CLONES = [
  { name: 'metascript',     base: 'typescript', color: 'deep-orange-400', lightColor: 'deep-orange-700', fileExtensions: ['ms'] },
  { name: 'metascript-cms', base: 'typescript', color: 'gray-700',        lightColor: 'gray-900',        fileExtensions: ['cms'] },
  { name: 'metascript-jms', base: 'typescript', color: 'amber-500',      lightColor: 'amber-800',       fileExtensions: ['jms'] },
  { name: 'metascript-ems', base: 'typescript', color: 'purple-300',     lightColor: 'purple-600',      fileExtensions: ['ems'] },
  { name: 'metascript-wms', base: 'typescript', color: 'teal-300',       lightColor: 'teal-600',        fileExtensions: ['wms'] },
  { name: 'metascript-rms', base: 'typescript', color: 'red-400',        lightColor: 'red-700',         fileExtensions: ['rms'] },
];

function configureMaterialIcons(): void {
  const materialIcons = vscode.extensions.getExtension('PKief.material-icon-theme');
  if (!materialIcons) return;

  const config = vscode.workspace.getConfiguration('material-icon-theme');
  const clones = config.get<any[]>('files.customClones') || [];

  // Check if already configured
  if (clones.some((c: any) => c.name === 'metascript')) return;

  for (const clone of MS_ICON_CLONES) {
    clones.push(clone);
  }

  config.update('files.customClones', clones, vscode.ConfigurationTarget.Global);
  log('Configured Material Icon Theme with MetaScript file icons');
}

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

export function activate(context: vscode.ExtensionContext): void {
  outputChannel = vscode.window.createOutputChannel('MetaScript');
  log('MetaScript extension activating...');

  statusBarItem = createStatusBarItem();
  context.subscriptions.push(statusBarItem);
  context.subscriptions.push(outputChannel);

  // --- Auto-configure file icons for Material Icon Theme ---
  configureMaterialIcons();

  // --- Register commands ---

  context.subscriptions.push(
    vscode.commands.registerCommand('metascript.restartServer', async () => {
      await restartServer();
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('metascript.expandMacro', async () => {
      await expandMacroAtCursor();
    }),
  );

  context.subscriptions.push(
    vscode.commands.registerCommand('metascript.showOutput', () => {
      outputChannel.show(true);
    }),
  );

  // --- Start server ---

  startClient(context);

  // --- Configuration change listener ---

  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (
        e.affectsConfiguration('metascript.path') ||
        e.affectsConfiguration('metascript.trace.server')
      ) {
        log('Configuration changed, restarting server...');
        restartServer();
      }
    }),
  );

  log('MetaScript extension activated');
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) {
    return undefined;
  }
  return client.stop();
}

// ---------------------------------------------------------------------------
// Client lifecycle
// ---------------------------------------------------------------------------

async function startClient(context: vscode.ExtensionContext): Promise<void> {
  const serverPath = findServerPath();
  const config = vscode.workspace.getConfiguration();
  const lspArgs = config.get<string[]>('metascript.lsp.args') || ['lsp'];
  log(`Command: ${serverPath} ${lspArgs.join(' ')}`);

  const serverOptions: ServerOptions = {
    run: {
      command: serverPath,
      args: lspArgs,
    },
    debug: {
      command: serverPath,
      args: [...lspArgs, '--debug'],
    },
  };

  // --- Client options ---

  const semanticHighlighting = config.get<boolean>('semanticHighlighting.enable', true);

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: 'file', language: 'metascript' },
      { scheme: 'untitled', language: 'metascript' },
    ],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{ms,cms,jms,ems,wms,rms}'),
    },
    outputChannel,
    traceOutputChannel: outputChannel,
    initializationOptions: {
      diagnostics: config.get<boolean>('diagnostics.enable', true),
      inlayHints: config.get<boolean>('inlayHints.enable', true),
      semanticHighlighting,
      completionSnippets: config.get<boolean>('completion.snippets', true),
    },
    middleware: {
      // Pass-through — extend here for future custom handling
    },
  };

  // --- Create and start the client ---

  client = new LanguageClient(
    'metascript',
    'MetaScript Language Server',
    serverOptions,
    clientOptions,
  );

  // --- State change handling ---

  client.onDidChangeState((event) => {
    switch (event.newState) {
      case State.Starting:
        setStatus('starting', 'Starting...');
        log('Language server starting...');
        break;
      case State.Running:
        setStatus('ready', 'Ready');
        restartCount = 0; // Reset on successful start
        log('Language server started successfully');
        break;
      case State.Stopped:
        log('Language server stopped');
        handleServerStopped(context);
        break;
    }
  });

  setStatus('starting', 'Starting...');

  client.start().then(
    () => {
      log('Language client connected');
    },
    async (error: Error) => {
      log(`Failed to start language client: ${error.message}`);
      setStatus('error', 'Failed to start');
      const choice = await vscode.window.showErrorMessage(
        `Failed to start MetaScript language server: ${error.message}`,
        'Install msc',
        'Open Settings',
      );
      if (choice === 'Install msc') {
        const installed = await downloadMsc();
        if (installed) {
          startClient(context);
        }
      } else if (choice === 'Open Settings') {
        vscode.commands.executeCommand('workbench.action.openSettings', 'metascript.path');
      }
    },
  );
}

/**
 * Handle unexpected server stop with auto-restart logic.
 */
function handleServerStopped(context: vscode.ExtensionContext): void {
  if (restartCount >= MAX_RESTARTS) {
    setStatus('error', 'Crashed (max restarts)');
    log(
      `Language server has crashed ${MAX_RESTARTS} times. ` +
        'Not restarting. Use "MetaScript: Restart Language Server" to try again.',
    );
    vscode.window
      .showErrorMessage(
        `MetaScript language server crashed ${MAX_RESTARTS} times. Not restarting automatically.`,
        'Restart',
        'Show Output',
      )
      .then((choice) => {
        if (choice === 'Restart') {
          restartCount = 0;
          startClient(context);
        } else if (choice === 'Show Output') {
          outputChannel.show(true);
        }
      });
    return;
  }

  restartCount++;
  const delay = Math.min(1000 * restartCount, 5000);
  setStatus('error', `Restarting (${restartCount}/${MAX_RESTARTS})...`);
  log(`Language server stopped unexpectedly. Restarting in ${delay}ms (attempt ${restartCount}/${MAX_RESTARTS})...`);

  setTimeout(() => {
    startClient(context);
  }, delay);
}

/**
 * Restart the language server manually. Resets the crash counter.
 */
async function restartServer(): Promise<void> {
  log('Restart requested by user');
  restartCount = 0;

  if (client) {
    setStatus('starting', 'Restarting...');
    try {
      await client.restart();
      vscode.window.showInformationMessage('MetaScript language server restarted');
    } catch (error: unknown) {
      const msg = error instanceof Error ? error.message : String(error);
      log(`Restart failed: ${msg}`);
      setStatus('error', 'Restart failed');
      vscode.window.showErrorMessage(`Failed to restart MetaScript language server: ${msg}`);
    }
  } else {
    log('No client to restart — server was never started');
  }
}

// ---------------------------------------------------------------------------
// Expand macro command
// ---------------------------------------------------------------------------

async function expandMacroAtCursor(): Promise<void> {
  const editor = vscode.window.activeTextEditor;
  if (!editor) {
    vscode.window.showWarningMessage('No active editor');
    return;
  }
  if (editor.document.languageId !== 'metascript') {
    vscode.window.showWarningMessage('Not a MetaScript file');
    return;
  }
  if (!client || client.state !== State.Running) {
    vscode.window.showWarningMessage('MetaScript language server is not running');
    return;
  }

  try {
    const position = editor.selection.active;
    const result = await client.sendRequest('metascript/expandMacro', {
      textDocument: { uri: editor.document.uri.toString() },
      position: { line: position.line, character: position.character },
    });

    if (result && typeof result === 'object' && 'expansion' in result) {
      const doc = await vscode.workspace.openTextDocument({
        content: (result as { expansion: string }).expansion,
        language: 'metascript',
      });
      await vscode.window.showTextDocument(doc, { viewColumn: vscode.ViewColumn.Beside });
    } else {
      vscode.window.showInformationMessage('No macro at cursor position');
    }
  } catch (error: unknown) {
    const msg = error instanceof Error ? error.message : String(error);
    log(`Expand macro failed: ${msg}`);
    vscode.window.showErrorMessage(`Macro expansion failed: ${msg}`);
  }
}

// ---------------------------------------------------------------------------
// Server discovery
// ---------------------------------------------------------------------------

function findServerPath(): string {
  // 1. User setting (always wins)
  const config = vscode.workspace.getConfiguration('metascript');
  const configuredPath = config.get<string>('path', '');

  if (configuredPath.length > 0) {
    const resolved = resolveHome(configuredPath);
    log(`Using configured path: ${resolved}`);
    return resolved;
  }

  // 2. ~/.metascript/bin/msc — the canonical install location
  //    (install.sh on mac/linux, install.ps1 on windows both write here)
  const installed = canonicalInstallPath();
  if (fs.existsSync(installed)) {
    log(`Found msc at canonical install location: ${installed}`);
    return installed;
  }

  // 3. Fallback: msc on PATH (for users who manage PATH manually)
  log('Using default: msc');
  return 'msc';
}

/**
 * The single canonical install location written by install.sh / install.ps1.
 */
function canonicalInstallPath(): string {
  const home = process.env.HOME || process.env.USERPROFILE || os.homedir();
  const binName = process.platform === 'win32' ? 'msc.exe' : 'msc';
  return path.join(home, '.metascript', 'bin', binName);
}

/**
 * Expand ~ to home directory in paths.
 */
function resolveHome(filePath: string): string {
  if (filePath.startsWith('~/') || filePath === '~') {
    const home = process.env.HOME || process.env.USERPROFILE || '';
    return path.join(home, filePath.slice(1));
  }
  return filePath;
}

// ---------------------------------------------------------------------------
// Auto-download msc
// ---------------------------------------------------------------------------


async function downloadMsc(): Promise<string | undefined> {
  const isWindows = process.platform === 'win32';
  const installCommand = isWindows
    ? 'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://metascriptlang.org/install.ps1 | iex"'
    : 'curl -fsSL https://metascriptlang.org/install.sh | sh';

  return vscode.window.withProgress(
    { location: vscode.ProgressLocation.Notification, title: 'Installing MetaScript compiler...' },
    async (progress) => {
      try {
        progress.report({ message: 'Running install script...' });
        const { execSync } = require('child_process');
        const output = execSync(installCommand, { encoding: 'utf-8', timeout: 180000 });
        log(`install script output: ${output}`);

        const installed = canonicalInstallPath();
        if (fs.existsSync(installed)) {
          log(`Installed msc to ${installed}`);
          vscode.window.showInformationMessage('MetaScript compiler installed successfully.');
          return installed;
        }

        throw new Error(`msc binary not found at ${installed} after installation`);
      } catch (err: unknown) {
        const msg = err instanceof Error ? err.message : String(err);
        log(`Installation failed: ${msg}`);
        vscode.window.showErrorMessage(`Failed to install msc: ${msg}`);
        return undefined;
      }
    },
  );
}

// ---------------------------------------------------------------------------
// Status bar
// ---------------------------------------------------------------------------

function createStatusBarItem(): vscode.StatusBarItem {
  const item = vscode.window.createStatusBarItem(
    vscode.StatusBarAlignment.Right,
    100,
  );
  item.name = 'MetaScript';
  item.command = 'metascript.restartServer';
  item.tooltip = 'MetaScript Language Server — click to restart';
  setStatusItem(item, 'starting', 'Initializing...');
  item.show();
  return item;
}

type StatusKind = 'starting' | 'ready' | 'error';

function setStatus(kind: StatusKind, detail: string): void {
  if (statusBarItem) {
    setStatusItem(statusBarItem, kind, detail);
  }
}

function setStatusItem(
  item: vscode.StatusBarItem,
  kind: StatusKind,
  detail: string,
): void {
  switch (kind) {
    case 'starting':
      item.text = '$(sync~spin) MS';
      item.backgroundColor = undefined;
      item.tooltip = `MetaScript: ${detail}`;
      break;
    case 'ready':
      item.text = '$(check) MS';
      item.backgroundColor = undefined;
      item.tooltip = `MetaScript: ${detail} — click to restart`;
      break;
    case 'error':
      item.text = '$(error) MS';
      item.backgroundColor = new vscode.ThemeColor(
        'statusBarItem.errorBackground',
      );
      item.tooltip = `MetaScript: ${detail} — click to restart`;
      break;
  }
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

function log(msg: string): void {
  const timestamp = new Date().toISOString().replace('T', ' ').replace('Z', '');
  outputChannel.appendLine(`[${timestamp}] ${msg}`);
}
