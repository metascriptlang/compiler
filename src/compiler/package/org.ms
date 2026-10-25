// msc org — organization management.
//
// Usage:
//   msc org create <name>              — create an organization
//   msc org invite <org> <username>    — add a member
//   msc org remove <org> <username>    — remove a member
//   msc org list                       — list your organizations
//   msc org members <org>              — list org members
//   msc org role <org> <user> <role>   — change member role (owner|member)

import { HttpResponse } from "std/http/types";
import { parseJson, getDynamicField, asString, stringify, jsonObject, jsonString } from "std/core/json";
import { arrayField } from "./json";
import { loadToken } from "./credentials";
import { registryRequest, registryErrorText } from "./registry";
import { error as errStyle, bold, green, cyan, dim } from "../../utils/color";

// `{ "<key>": "<value>" }`, with the value escaped.
function fieldBody(key: string, value: string): string {
	return stringify(jsonObject([key], [jsonString(value)]));
}

// Sends one call; null after printing why it could not be sent.
function orgCall(method: string, path: string, body: string, needsLogin: boolean): HttpResponse | null {
	let token = "";
	if (needsLogin) {
		token = loadToken();
		if (token == "") {
			console.log(`${errStyle("error")}: not logged in — run ${cyan("msc login")} first`);
			return null;
		}
	}
	const sent = registryRequest(method, path, body, token, body != "" ? "application/json" : "");
	if (!sent.ok) {
		console.log(`${errStyle("error")}: failed to reach registry`);
		return null;
	}
	return sent.value;
}

// A call that changes an org: prints `done` on `okStatus`, else the registry's error.
function orgChange(method: string, path: string, body: string, okStatus: int32, done: string): boolean {
	const resp = orgCall(method, path, body, true);
	if (resp == null) return false;
	if (resp.status == okStatus) {
		console.log(done);
		return true;
	}
	console.log(`${errStyle("error")}: ${registryErrorText(resp)}`);
	return false;
}

export function cmdOrg(args: string[]): boolean {
	if (args.length == 0) {
		printUsage();
		return false;
	}

	const sub = args[0];
	match (sub) {
		"create" => { return orgCreate(args); },
		"invite" => { return orgInvite(args); },
		"remove" => { return orgRemove(args); },
		"list" => { return orgList(); },
		"members" => { return orgMembers(args); },
		"role" => { return orgRole(args); },
		_ => {
			console.log(`${errStyle("error")}: unknown org command: ${sub}`);
			printUsage();
			return false;
		},
	};
}

function printUsage(): void {
	console.log("usage: msc org <command>");
	console.log("");
	console.log("commands:");
	console.log("  create <name>              create an organization");
	console.log("  invite <org> <username>    add a member");
	console.log("  remove <org> <username>    remove a member");
	console.log("  list                       list your organizations");
	console.log("  members <org>              list org members");
	console.log("  role <org> <user> <role>   change member role");
}

function orgCreate(args: string[]): boolean {
	if (args.length < 2) {
		console.log(`${errStyle("error")}: usage: msc org create <name>`);
		return false;
	}
	const name = args[1];
	return orgChange("POST", "/orgs", fieldBody("name", name), 201, `${green("created")} organization ${cyan("@" + name)}`);
}

function orgInvite(args: string[]): boolean {
	if (args.length < 3) {
		console.log(`${errStyle("error")}: usage: msc org invite <org> <username>`);
		return false;
	}
	const orgName = args[1];
	const username = args[2];
	return orgChange("POST", "/orgs/" + orgName + "/members", fieldBody("username", username), 201, `${green("added")} ${cyan(username)} to ${cyan("@" + orgName)}`);
}

function orgRemove(args: string[]): boolean {
	if (args.length < 3) {
		console.log(`${errStyle("error")}: usage: msc org remove <org> <username>`);
		return false;
	}
	const orgName = args[1];
	const username = args[2];
	return orgChange("DELETE", "/orgs/" + orgName + "/members/" + username, "", 200, `${green("removed")} ${cyan(username)} from ${cyan("@" + orgName)}`);
}

function orgList(): boolean {
	const resp = orgCall("GET", "/orgs", "", true);
	if (resp == null) return false;

	if (resp.status != 200) {
		console.log(`${errStyle("error")}: failed to list organizations`);
		return false;
	}

	const parsed = parseJson(resp.body);
	if (!parsed.ok) {
		console.log(`${errStyle("error")}: invalid response`);
		return false;
	}

	const orgs = arrayField(parsed.value, "organizations");
	if (orgs.length == 0) {
		console.log("no organizations — create one with " + cyan("msc org create <name>"));
		return true;
	}

	let i = 0;
	while (i < orgs.length) {
		const name = orgs[i].getDynamicField("orgName").asString();
		const role = orgs[i].getDynamicField("role").asString();
		console.log(`  ${cyan("@" + name)}  ${dim(role)}`);
		i = i + 1;
	}
	return true;
}

function orgMembers(args: string[]): boolean {
	if (args.length < 2) {
		console.log(`${errStyle("error")}: usage: msc org members <org>`);
		return false;
	}
	const orgName = args[1];

	const resp = orgCall("GET", "/orgs/" + orgName, "", false);
	if (resp == null) return false;
	if (resp.status == 404) {
		console.log(`${errStyle("error")}: organization not found: @${orgName}`);
		return false;
	}
	if (resp.status != 200) {
		console.log(`${errStyle("error")}: failed to fetch org`);
		return false;
	}

	const parsed = parseJson(resp.body);
	if (!parsed.ok) {
		console.log(`${errStyle("error")}: invalid response`);
		return false;
	}

	const members = arrayField(parsed.value, "members");
	console.log(`${bold("@" + orgName)} — ${members.length.toString()} member(s)`);
	let i = 0;
	while (i < members.length) {
		const username = members[i].getDynamicField("username").asString();
		const role = members[i].getDynamicField("role").asString();
		console.log(`  ${cyan(username)}  ${dim(role)}`);
		i = i + 1;
	}
	return true;
}

function orgRole(args: string[]): boolean {
	if (args.length < 4) {
		console.log(`${errStyle("error")}: usage: msc org role <org> <username> <owner|member>`);
		return false;
	}
	const orgName = args[1];
	const username = args[2];
	const role = args[3];

	if (role != "owner" && role != "member") {
		console.log(`${errStyle("error")}: role must be "owner" or "member"`);
		return false;
	}

	return orgChange("PATCH", "/orgs/" + orgName + "/members/" + username, fieldBody("role", role), 200, `${green("updated")} ${cyan(username)} → ${cyan(role)} in ${cyan("@" + orgName)}`);
}

test "a request body escapes a quote and a backslash in the value" {
	const quoted = parseJson(fieldBody("name", 'a"b'));
	assert quoted.ok;
	if (quoted.ok) assert quoted.value.getDynamicField("name").asString() == 'a"b';
	const slashed = parseJson(fieldBody("username", "a\\b"));
	assert slashed.ok;
	if (slashed.ok) assert slashed.value.getDynamicField("username").asString() == "a\\b";
}
