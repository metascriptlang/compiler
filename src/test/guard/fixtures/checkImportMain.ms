import { checkImportHelper } from "./checkImportDep";

export function checkImportUse(): int32 {
	return checkImportHelper() + 1;
}
