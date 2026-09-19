import { Type, TypeKind } from "../../ast/node";
import { RaiserCopyPlan, RaiserCopyKind } from "../../raiser/valueCopy";
import { RaiserOpcode, raiserABC } from "../../raiser/bytecode";
import { RaiserCompState, emitInst, allocReg } from "./context";

function copyPlan(s: RaiserCompState, valueType: Type | null): int32 {
	if (valueType != null && (valueType.kind == TypeKind.Alias || valueType.kind == TypeKind.Distinct)) {
		return copyPlan(s, valueType.typeReturn);
	}
	if (valueType == null) return -1;
	for (let i = 0; i < s.copyTypes.length; i += 1) {
		if (s.copyTypes[i] == valueType) return i;
	}
	const plan: RaiserCopyPlan = { kind: RaiserCopyKind.Preserve, names: [], children: [] };
	const index = s.copyPlans.length;
	s.copyTypes.push(valueType);
	s.copyPlans.push(plan);
	if (valueType.kind == TypeKind.Array) {
		plan.kind = RaiserCopyKind.Array;
		plan.children.push(copyPlan(s, valueType.typeReturn));
	} else if (valueType.kind == TypeKind.Struct) {
		plan.kind = RaiserCopyKind.Object;
		for (let i = 0; i < valueType.typeNames.length; i += 1) {
			plan.names.push(valueType.typeNames[i]);
			plan.children.push(copyPlan(s, valueType.typeChildren[i]));
		}
	}
	return index;
}

export function emitValueCopy(
	s: RaiserCompState,
	source: int32,
	valueType: Type | null,
): int32 {
	const index = copyPlan(s, valueType);
	if (index < 0 || s.copyPlans[index].kind == RaiserCopyKind.Preserve) return source;
	const destination = allocReg(s);
	emitInst(s, raiserABC(RaiserOpcode.CopyValue, destination, source, index));
	return destination;
}
