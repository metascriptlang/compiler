// @stdout: direct new 7; callback new 7; callback close 7/1; local new 7; nested close 7/1; literal 9 null
// @exit: 0

type HostId = distinct int32;
struct HostPane { host: HostId; pane: int32; }
enum Kind { NewTab, ClosePane }
struct Cmd = match (kind: Kind) {
	Kind.NewTab => { host: HostId | null },
	Kind.ClosePane => { pane: HostPane | null },
};
interface Commands { run: (command: Cmd) => void; }

let seen = "";

function describe(command: Cmd): string {
	return match (command.kind) {
		Kind.NewTab => command.host !== null ? `new ${command.host as int32}` : "new none",
		Kind.ClosePane => command.pane !== null ? `close ${command.pane.host as int32}/${command.pane.pane}` : "close none",
	};
}

function direct(command: Cmd): void { seen += `direct ${describe(command)}; `; }

function nested(apply: (command: Cmd) => void, pane: HostPane): void {
	apply({ kind: Kind.ClosePane, pane: pane });
}

function main(): void {
	const commands: Commands = { run: (command: Cmd): void => { seen += `callback ${describe(command)}; `; } };
	const host = 7 as HostId;
	const pane: HostPane = { host: host, pane: 1 };
	direct({ kind: Kind.NewTab, host: host });
	commands.run({ kind: Kind.NewTab, host: host });
	commands.run({ kind: Kind.ClosePane, pane: pane });
	const local = (command: Cmd): void => { seen += `local ${describe(command)}; `; };
	local({ kind: Kind.NewTab, host: host });
	nested((command: Cmd): void => { seen += `nested ${describe(command)}; `; }, pane);
	const wide: Cmd = { kind: Kind.NewTab, host: 9 as HostId };
	const empty: Cmd = { kind: Kind.ClosePane, pane: null };
	console.log(`${seen}literal ${describe(wide).slice(4)} ${empty.kind == Kind.ClosePane && describe(empty) == "close none" ? "null" : "set"}`);
}

main();
