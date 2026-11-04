import {
	RaiserOpcode, RaiserRegClass, RaiserInstruction, raiserABC, raiserABx,
} from "../../raiser/bytecode";
import {
	RaiserValue, RaiserValueKind, createClassType, raiserConstString,
	raiserInt, raiserBool, raiserNil,
} from "../../raiser/value";
import {
	createRaiserFunction, createRaiserModule,
} from "../../raiser/module";
import { RaiserVM, execModule } from "../../raiser/vm";
import { disasmInst } from "../../raiser/disasm";

function readField(
	laid: boolean, required: boolean, fields: string[],
	values: RaiserValue[], name: string,
): RaiserVM {
	const constants: RaiserValue[] = [raiserConstString(name)];
	const code: RaiserInstruction[] = [
		raiserABC(RaiserOpcode.NewObject, 0, laid ? 1 : 0, 0),
	];
	const kinds: RaiserRegClass[] = [];
	const classes = [RaiserRegClass.Ref, RaiserRegClass.Dyn];
	for (let i = 0; i < fields.length; i += 1) {
		const key = constants.length;
		constants.push(raiserConstString(fields[i]));
		const value = constants.length;
		constants.push(values[i]);
		const temporary = classes.length;
		const kind = values[i].kind;
		classes.push(kind == RaiserValueKind.Int ? RaiserRegClass.Word
			: kind == RaiserValueKind.Bool ? RaiserRegClass.Bool
			: kind == RaiserValueKind.Float ? RaiserRegClass.Float
			: RaiserRegClass.Ref);
		code.push(raiserABx(RaiserOpcode.LoadConst, temporary, value));
		code.push(raiserABC(RaiserOpcode.StoreField, 0, key, temporary));
		kinds.push(RaiserRegClass.Dyn);
	}
	code.push(raiserABC(required ? RaiserOpcode.LoadFieldRequired
		: RaiserOpcode.LoadField, 1, 0, 0));
	code.push(raiserABC(RaiserOpcode.Halt, 1, 0, 0));
	const fn = createRaiserFunction("requiredField", code, constants, 0, 0,
		classes.length, classes);
	if (laid) fn.classTypes.push(createClassType("", -1, [], fields, kinds));
	return execModule(createRaiserModule("requiredField", [fn], 0));
}

test "required field: a missing nullable member errors for laid and unlaid objects" {
	for (const laid of [false, true]) {
		let loaded: RaiserVM | null = null;
		let failure = "";
		try { loaded = readField(laid, true, ["other"], [raiserInt(7)], "maybe"); }
		catch (error) { failure = error.message; }
		assert loaded != null, `laid=${laid}: ${failure}`;
		const vm = loaded!;
		assert vm.error.includes("required field 'maybe' is missing"), vm.error;
	}
}

test "required field: explicit nil false and zero are present values" {
	for (const laid of [false, true]) {
		for (const value of [raiserNil(), raiserBool(false), raiserInt(0)]) {
			let loaded: RaiserVM | null = null;
			let failure = "";
			try { loaded = readField(laid, true, ["maybe"], [value], "maybe"); }
			catch (error) { failure = error.message; }
			assert loaded != null, `laid=${laid} kind=${value.kind}: ${failure}`;
			const vm = loaded!;
			assert vm.error == "", vm.error;
			assert vm.exitValue.kind == value.kind;
			assert vm.exitValue.intVal == value.intVal;
		}
	}
}

test "required field: optional LoadField still returns nil for a missing member" {
	for (const laid of [false, true]) {
		let loaded: RaiserVM | null = null;
		let failure = "";
		try { loaded = readField(laid, false, ["other"], [raiserInt(7)], "maybe"); }
		catch (error) { failure = error.message; }
		assert loaded != null, `laid=${laid}: ${failure}`;
		const vm = loaded!;
		assert vm.error == "", vm.error;
		assert vm.exitValue.kind == RaiserValueKind.Nil;
	}
}

test "required field: a cached name follows reordered laid fields" {
	const reader = createRaiserFunction("readValue", [
		raiserABC(RaiserOpcode.LoadFieldRequired, 1, 0, 0),
		raiserABC(RaiserOpcode.Ret, 1, 0, 0),
	], [raiserConstString("value")], 1, 0, 2,
		[RaiserRegClass.Ref, RaiserRegClass.Dyn]);
	const entry = createRaiserFunction("entry", [
		raiserABC(RaiserOpcode.NewObject, 2, 1, 0),
		raiserABx(RaiserOpcode.LoadConst, 4, 0),
		raiserABC(RaiserOpcode.StoreField, 2, 2, 4),
		raiserABx(RaiserOpcode.LoadConst, 4, 4),
		raiserABC(RaiserOpcode.StoreField, 2, 3, 4),
		raiserABC(RaiserOpcode.NewObject, 3, 2, 0),
		raiserABx(RaiserOpcode.LoadConst, 4, 1),
		raiserABC(RaiserOpcode.StoreField, 3, 2, 4),
		raiserABx(RaiserOpcode.LoadConst, 4, 4),
		raiserABC(RaiserOpcode.StoreField, 3, 3, 4),
		raiserABC(RaiserOpcode.Move, 1, 2, 0),
		raiserABC(RaiserOpcode.Call, 0, 1, 1),
		raiserABC(RaiserOpcode.Move, 1, 3, 0),
		raiserABC(RaiserOpcode.Call, 0, 1, 1),
		raiserABC(RaiserOpcode.Halt, 0, 0, 0),
	], [raiserInt(19), raiserInt(29), raiserConstString("value"),
		raiserConstString("other"), raiserInt(101)], 0, 0, 5,
		[RaiserRegClass.Dyn, RaiserRegClass.Ref, RaiserRegClass.Ref,
			RaiserRegClass.Ref, RaiserRegClass.Word]);
	entry.classTypes.push(createClassType("", -1, [], ["value", "other"],
		[RaiserRegClass.Word, RaiserRegClass.Word]));
	entry.classTypes.push(createClassType("", -1, [], ["other", "value"],
		[RaiserRegClass.Word, RaiserRegClass.Word]));
	const vm = execModule(createRaiserModule("reordered", [entry, reader], 0));
	assert vm.error == "", vm.error;
	assert vm.exitValue.intVal == 29;
	assert reader.fieldCache[0] == 1;
}

test "required field: name constants are validated at declaration" {
	for (const name of [-1, 0.5, NaN, Infinity, -Infinity, 1]) {
		let message = "";
		try {
			createRaiserFunction("invalidName", [
				raiserABC(RaiserOpcode.LoadFieldRequired, 0, 1, name),
			], [raiserConstString("value")], 0, 0, 2,
				[RaiserRegClass.Dyn, RaiserRegClass.Ref]);
		} catch (error) { message = error.message; }
		assert message.includes("invalid required field name"), message;
	}
	let message = "";
	try {
		createRaiserFunction("nonStringName", [
			raiserABC(RaiserOpcode.LoadFieldRequired, 0, 1, 0),
		], [raiserInt(7)], 0, 0, 2,
			[RaiserRegClass.Dyn, RaiserRegClass.Ref]);
	} catch (error) { message = error.message; }
	assert message.includes("invalid required field name"), message;
}

test "required field: a nil receiver is refused before field lookup" {
	const fn = createRaiserFunction("nilReceiver", [
		raiserABC(RaiserOpcode.LoadNil, 0, 0, 0),
		raiserABC(RaiserOpcode.LoadFieldRequired, 1, 0, 0),
		raiserABC(RaiserOpcode.Halt, 1, 0, 0),
	], [raiserConstString("value")], 0, 0, 2,
		[RaiserRegClass.Ref, RaiserRegClass.Dyn]);
	const vm = execModule(createRaiserModule("nilReceiver", [fn], 0));
	assert vm.error == "attempt to access a nil address", vm.error;
}

test "required field: disassembly identifies the named-load boundary" {
	assert disasmInst(raiserABC(RaiserOpcode.LoadFieldRequired, 0, 1, 2))
		== "LoadFieldRequired W0 R1 K2";
}
