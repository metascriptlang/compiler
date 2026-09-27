export enum HcrReloadKind {
	NoChange,
	Reloaded,
	Pending,
	Rejected,
	RestartRequired,
}

export struct HcrReloadResult {
	kind: HcrReloadKind;
	modules: string[];
	reason: string;
}

export function reloadKindName(kind: HcrReloadKind): string {
	return match (kind) {
		HcrReloadKind.NoChange => "no change",
		HcrReloadKind.Reloaded => "reloaded",
		HcrReloadKind.Pending => "pending",
		HcrReloadKind.Rejected => "rejected",
		HcrReloadKind.RestartRequired => "restart required",
	};
}
