import * as path from 'path';
import * as fs from 'fs';
import * as vscode from 'vscode';
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
  State,
} from 'vscode-languageclient/node';

let client: LanguageClient | undefined;
let statusBarItem: vscode.StatusBarItem;
let outputChannel: vscode.OutputChannel;
let restartCount = 0;
const MAX_RESTARTS = 5;

// ---------------------------------------------------------------------------
// Activation
// ---------------------------------------------------------------------------

export function activate(context: vscode.ExtensionContext): void {
  outputChannel = vscode.window.createOutputChannel('MetaScript');
  log('MetaScript extension activating...');

  statusBarItem = createStatusBarItem();
  context.subscriptions.push(statusBarItem);
  context.subscriptions.push(outputChannel);

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
        e.affectsConfiguration('metascript.serverPath') ||
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

function startClient(context: vscode.ExtensionContext): void {
  const serverPath = findServerPath(context);

  if (!serverPath) {
    const msg =
      'MetaScript language server (msc) not found. ' +
      'Install it and ensure it is on your PATH, or set metascript.serverPath in settings.';
    log(msg);
    vscode.window
      .showErrorMessage(msg, 'Open Settings')
      .then((choice) => {
        if (choice === 'Open Settings') {
          vscode.commands.executeCommand(
            'workbench.action.openSettings',
            'metascript.serverPath',
          );
        }
      });
    setStatus('error', 'Server not found');
    return;
  }

  log(`Using language server: ${serverPath}`);

  // --- Server options ---

  const serverOptions: ServerOptions = {
    run: {
      command: serverPath,
      args: ['lsp'],
      transport: TransportKind.stdio,
    },
    debug: {
      command: serverPath,
      args: ['lsp', '--debug'],
      transport: TransportKind.stdio,
    },
  };

  // --- Client options ---

  const config = vscode.workspace.getConfiguration('metascript');
  const semanticHighlighting = config.get<boolean>('semanticHighlighting.enable', true);

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: 'file', language: 'metascript' },
      { scheme: 'untitled', language: 'metascript' },
    ],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher('**/*.{ms,mts}'),
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
    (error: Error) => {
      log(`Failed to start language client: ${error.message}`);
      setStatus('error', 'Failed to start');
      vscode.window.showErrorMessage(
        `Failed to start MetaScript language server: ${error.message}`,
      );
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

function findServerPath(context: vscode.ExtensionContext): string | undefined {
  // 1. User-configured path (highest priority)
  const config = vscode.workspace.getConfiguration('metascript');
  const configuredPath = config.get<string>('serverPath');

  if (configuredPath && configuredPath.length > 0) {
    const resolved = resolveHome(configuredPath);
    if (fs.existsSync(resolved)) {
      log(`Server found via settings: ${resolved}`);
      return resolved;
    }
    log(`Configured server path not found: ${resolved}`);
  }

  // 2. Workspace-relative paths (for development)
  const workspaceFolders = vscode.workspace.workspaceFolders;
  if (workspaceFolders) {
    for (const folder of workspaceFolders) {
      const candidates = [
        path.join(folder.uri.fsPath, 'zig-out', 'bin', 'msc'),
        path.join(folder.uri.fsPath, 'zig-out', 'bin', 'msc.exe'),
        path.join(folder.uri.fsPath, 'bin', 'msc'),
        path.join(folder.uri.fsPath, 'bin', 'msc.exe'),
        path.join(folder.uri.fsPath, 'node_modules', '.bin', 'msc'),
      ];
      for (const p of candidates) {
        if (fs.existsSync(p)) {
          log(`Server found in workspace: ${p}`);
          return p;
        }
      }
    }
  }

  // 3. Relative to extension directory (bundled or sibling build)
  const extensionCandidates = [
    path.join(context.extensionPath, 'bin', 'msc'),
    path.join(context.extensionPath, 'bin', 'msc.exe'),
    path.join(context.extensionPath, '..', 'zig-out', 'bin', 'msc'),
    path.join(context.extensionPath, '..', 'zig-out', 'bin', 'msc.exe'),
  ];
  for (const p of extensionCandidates) {
    if (fs.existsSync(p)) {
      log(`Server found relative to extension: ${p}`);
      return p;
    }
  }

  // 4. System PATH
  const pathDirs = (process.env.PATH || '').split(path.delimiter);
  for (const dir of pathDirs) {
    const exeNames = process.platform === 'win32'
      ? ['msc.exe', 'msc.cmd', 'msc']
      : ['msc'];
    for (const exe of exeNames) {
      const p = path.join(dir, exe);
      if (fs.existsSync(p)) {
        log(`Server found on PATH: ${p}`);
        return p;
      }
    }
  }

  log('Server not found in any location');
  return undefined;
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
