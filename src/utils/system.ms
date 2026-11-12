import * as os from "std/fs";
import { cwd as osCwd, env as osEnv, execPath as osExecPath } from "std/process";
import { IoError } from "std/io/errors";
import { Buffer } from "std/core/buffer";

export interface System {
	readFile: (path: string) => Result<string, IoError>;
	readFileBytes: (path: string) => Result<Buffer, IoError>;
	writeFile: (path: string, content: string) => Result<void, IoError>;
	appendFile: (path: string, content: string) => Result<void, IoError>;
	exists: (path: string) => boolean;
	isFile: (path: string) => boolean;
	isDir: (path: string) => boolean;
	isExecutable: (path: string) => boolean;
	readDir: (path: string) => string[];
	realpath: (path: string) => string;
	ensureDir: (path: string) => Result<void, IoError>;
	mkdir: (path: string) => Result<void, IoError>;
	remove: (path: string) => Result<void, IoError>;
	removeAll: (path: string) => Result<void, IoError>;
	rmdir: (path: string) => Result<void, IoError>;
	rename: (oldPath: string, newPath: string) => Result<void, IoError>;
	symlink: (target: string, path: string) => Result<void, IoError>;
	copyFile: (src: string, dst: string) => Result<void, IoError>;
	fileSize: (path: string) => number;
	modifiedTime: (path: string) => number;
	changedTime: (path: string) => number;
	changeStamp: (path: string) => string;
	getEnv: (name: string) => string;
	cwd: () => string;
	execPath: () => string;
}

export function machineSystem(): System {
	return {
		readFile: (path: string): Result<string, IoError> => os.readFile(path),
		readFileBytes: (path: string): Result<Buffer, IoError> => os.readFileBytes(path),
		writeFile: (path: string, content: string): Result<void, IoError> => os.writeFile(path, content),
		appendFile: (path: string, content: string): Result<void, IoError> => os.appendFile(path, content),
		exists: (path: string): boolean => os.exists(path),
		isFile: (path: string): boolean => os.isFile(path),
		isDir: (path: string): boolean => os.isDir(path),
		isExecutable: (path: string): boolean => os.isExecutable(path),
		readDir: (path: string): string[] => os.readDir(path),
		realpath: (path: string): string => os.realpath(path),
		ensureDir: (path: string): Result<void, IoError> => os.ensureDir(path),
		mkdir: (path: string): Result<void, IoError> => os.mkdir(path),
		remove: (path: string): Result<void, IoError> => os.remove(path),
		removeAll: (path: string): Result<void, IoError> => os.removeAll(path),
		rmdir: (path: string): Result<void, IoError> => os.rmdir(path),
		rename: (oldPath: string, newPath: string): Result<void, IoError> => os.rename(oldPath, newPath),
		symlink: (target: string, path: string): Result<void, IoError> => os.symlink(target, path),
		copyFile: (src: string, dst: string): Result<void, IoError> => os.copyFile(src, dst),
		fileSize: (path: string): number => os.fileSize(path),
		modifiedTime: (path: string): number => os.modifiedTime(path),
		changedTime: (path: string): number => os.changedTime(path),
		changeStamp: (path: string): string => os.changeStamp(path),
		getEnv: (name: string): string => osEnv.get(name),
		cwd: (): string => osCwd(),
		execPath: (): string => osExecPath,
	};
}

let _active: System | null = null;

export function activeSystem(): System | null {
	return _active;
}

export function setActiveSystem(system: System | null): void {
	_active = system;
}

export function readFile(path: string): Result<string, IoError> {
	return _active != null ? _active.readFile(path) : os.readFile(path);
}

export function readFileBytes(path: string): Result<Buffer, IoError> {
	return _active != null ? _active.readFileBytes(path) : os.readFileBytes(path);
}

export function writeFile(path: string, content: string): Result<void, IoError> {
	return _active != null ? _active.writeFile(path, content) : os.writeFile(path, content);
}

export function appendFile(path: string, content: string): Result<void, IoError> {
	return _active != null ? _active.appendFile(path, content) : os.appendFile(path, content);
}

export function exists(path: string): boolean {
	return _active != null ? _active.exists(path) : os.exists(path);
}

export function isFile(path: string): boolean {
	return _active != null ? _active.isFile(path) : os.isFile(path);
}

export function isDir(path: string): boolean {
	return _active != null ? _active.isDir(path) : os.isDir(path);
}

export function isExecutable(path: string): boolean {
	return _active != null ? _active.isExecutable(path) : os.isExecutable(path);
}

export function readDir(path: string): string[] {
	return _active != null ? _active.readDir(path) : os.readDir(path);
}

export function realpath(path: string): string {
	return _active != null ? _active.realpath(path) : os.realpath(path);
}

export function ensureDir(path: string): Result<void, IoError> {
	return _active != null ? _active.ensureDir(path) : os.ensureDir(path);
}

export function mkdir(path: string): Result<void, IoError> {
	return _active != null ? _active.mkdir(path) : os.mkdir(path);
}

export function remove(path: string): Result<void, IoError> {
	return _active != null ? _active.remove(path) : os.remove(path);
}

export function removeAll(path: string): Result<void, IoError> {
	return _active != null ? _active.removeAll(path) : os.removeAll(path);
}

export function rmdir(path: string): Result<void, IoError> {
	return _active != null ? _active.rmdir(path) : os.rmdir(path);
}

export function rename(oldPath: string, newPath: string): Result<void, IoError> {
	return _active != null ? _active.rename(oldPath, newPath) : os.rename(oldPath, newPath);
}

export function symlink(target: string, path: string): Result<void, IoError> {
	return _active != null ? _active.symlink(target, path) : os.symlink(target, path);
}

export function copyFile(src: string, dst: string): Result<void, IoError> {
	return _active != null ? _active.copyFile(src, dst) : os.copyFile(src, dst);
}

export function fileSize(path: string): number {
	return _active != null ? _active.fileSize(path) : os.fileSize(path);
}

export function modifiedTime(path: string): number {
	return _active != null ? _active.modifiedTime(path) : os.modifiedTime(path);
}

export function changedTime(path: string): number {
	return _active != null ? _active.changedTime(path) : os.changedTime(path);
}

export function changeStamp(path: string): string {
	return _active != null ? _active.changeStamp(path) : os.changeStamp(path);
}

export function cwd(): string {
	return _active != null ? _active.cwd() : osCwd();
}

export function execPath(): string {
	return _active != null ? _active.execPath() : osExecPath;
}

export class env {
	static get(name: string): string {
		return _active != null ? _active.getEnv(name) : osEnv.get(name);
	}
}
