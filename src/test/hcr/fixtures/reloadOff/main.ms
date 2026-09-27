import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";

for (let i = 0; i < 3; i += 1) {
	const kind = reload();
	if (kind != ReloadKind.NoChange) console.log(`unexpected ${reloadKindName(kind)} ${lastReload().reason}`);
}
console.log(`reload without --hcr: ${reloadKindName(reload())}`);
