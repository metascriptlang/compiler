import { Node, bindSym } from "std/meta";
import { ReloadKind, ReloadResult } from "./types";

export { ReloadKind, ReloadResult, reloadKindName } from "./types";

when (hcr) {
	import { engineReload, engineLastReload, engineStep } from "./engine";

	export macro reload(): Node {
		return quote { ${bindSym("engineReload")}() };
	}

	export function lastReload(): ReloadResult {
		return engineLastReload();
	}

	export function step(body: () => void): ReloadKind {
		return engineStep(body);
	}
} else {
	export macro reload(): Node {
		return quote { ${bindSym("ReloadKind")}.NoChange };
	}

	export function lastReload(): ReloadResult {
		return { kind: ReloadKind.NoChange, modules: [], reason: "" };
	}

	export function step(body: () => void): ReloadKind {
		body();
		return ReloadKind.NoChange;
	}
}
