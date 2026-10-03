export enum ReloadKind {
	NoChange,
	Reloaded,
	Pending,
	Rejected,
	RestartRequired,
	RolledBack,
}

export struct ReloadResult {
	kind: ReloadKind;
	modules: string[];
	reason: string;
}

export function reloadKindName(kind: ReloadKind): string {
	return match (kind) {
		ReloadKind.NoChange => "no change",
		ReloadKind.Reloaded => "reloaded",
		ReloadKind.Pending => "pending",
		ReloadKind.Rejected => "rejected",
		ReloadKind.RestartRequired => "restart required",
		ReloadKind.RolledBack => "rolled back",
	};
}
