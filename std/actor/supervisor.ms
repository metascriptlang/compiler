// Supervisor — Erlang OTP supervision tree (MetaScript implementation)
//
// Production-grade supervisor with Erlang OTP parity:
// - 3 restart strategies (OneForOne, OneForAll, RestForOne)
// - Sliding-window restart intensity limiting
// - Per-child shutdown protocol (BrutalKill, Timeout, Infinity)
// - Dynamic child management (startChild, terminateChild, deleteChild, restartChild)
// - Child introspection (countChildren)
//
// Usage:
//   import { Supervisor, DynSupervisor, RestartStrategy, RestartType, ShutdownKind } from "std/actor/supervisor";

import { ExitReason, stop, link, unlink, clockMs, setIdleTimeout } from "std/actor";

export enum RestartStrategy {
	OneForOne,    // only crashed child restarts
	OneForAll,    // all children restart when one crashes
	RestForOne,   // crashed child + all children started after it restart
}

export enum RestartType {
	Permanent,    // always restart (any exit reason)
	Transient,    // restart only on abnormal exit (not Normal)
	Temporary,    // never restart
}

export enum ShutdownKind {
	BrutalKill,   // stop(pid, Killed) immediately — skip onTerminate
	Timeout,      // stop(pid, Normal), wait shutdownMs, then Killed if stuck
	Infinity,     // stop(pid, Normal), wait forever (for nested supervisors)
}

export interface ChildSpec {
	name: string;
	start: () => int64;
	restart: RestartType;
	shutdown: ShutdownKind;   // default: Timeout
	shutdownMs: number;       // default: 5000, only used if shutdown=Timeout
}

export actor Supervisor {
	private strategy: RestartStrategy;
	private maxRestarts: number;
	private maxSeconds: number;
	private specs: ChildSpec[];
	private pids: int64[];
	private restartTimes: number[];
	// Pending graceful shutdowns (timed shutdown protocol)
	private pendingPids: int64[];
	private pendingDeadlines: number[];

	constructor(strategy: RestartStrategy, maxRestarts: number, maxSeconds: number) {
		this.strategy = strategy;
		this.maxRestarts = maxRestarts;
		this.maxSeconds = maxSeconds;
		this.specs = [];
		this.pids = [];
		this.restartTimes = [];
		this.pendingPids = [];
		this.pendingDeadlines = [];
	}

	// ===== Static child setup (before start) =====

	addChild(spec: ChildSpec): void {
		this.specs.push(spec);
	}

	start(): void {
		for (let i = 0; i < this.specs.length; i = i + 1) {
			const pid = this.specs[i].start();
			this.pids.push(pid);
			link(this.pid, pid);
		}
	}

	// ===== Dynamic child management (Erlang: start_child/terminate_child/delete_child/restart_child) =====

	startChild(spec: ChildSpec): int64 {
		this.specs.push(spec);
		const pid = spec.start();
		this.pids.push(pid);
		link(this.pid, pid);
		return pid;
	}

	terminateChild(name: string): boolean {
		const idx = this.findChildByName(name);
		if (idx < 0) return false;
		if (this.pids[idx] === 0) return false;
		this.shutdownChild(idx);
		return true;
	}

	deleteChild(name: string): boolean {
		const idx = this.findChildByName(name);
		if (idx < 0) return false;
		if (this.pids[idx] !== 0) return false;
		this.removeChildAt(idx);
		return true;
	}

	restartChild(name: string): int64 {
		const idx = this.findChildByName(name);
		if (idx < 0) return 0;
		if (this.pids[idx] !== 0) return 0;
		const pid = this.specs[idx].start();
		this.pids[idx] = pid;
		link(this.pid, pid);
		return pid;
	}

	// ===== Introspection (Erlang: count_children/1) =====

	countChildren(): number {
		let count = 0;
		for (let i = 0; i < this.pids.length; i = i + 1) {
			if (this.pids[i] !== 0) count = count + 1;
		}
		return count;
	}

	// ===== System message handlers =====

	onExit(childPid: int64, reason: ExitReason): void {
		// Clear from pending shutdowns if this was a graceful shutdown in progress
		this.clearPendingShutdown(childPid);

		const childIdx = this.findChild(childPid);
		if (childIdx < 0) return;

		// Mark as stopped
		this.pids[childIdx] = 0;

		// Erlang do_restart parity: check restart type vs reason
		const shouldRestart = match (this.specs[childIdx].restart) {
			RestartType.Permanent => true,
			RestartType.Transient => reason !== ExitReason.Normal,
			RestartType.Temporary => false,
		};

		if (!shouldRestart) return;

		// Erlang add_restart parity: sliding window tolerance
		if (!this.checkTolerance()) {
			console.log("supervisor: max restart intensity reached, shutting down");
			stop(this.pid, ExitReason.Abnormal);
			return;
		}

		// Apply restart strategy
		match (this.strategy) {
			RestartStrategy.OneForOne => {
				const newPid = this.specs[childIdx].start();
				this.pids[childIdx] = newPid;
				link(this.pid, newPid);
			},
			RestartStrategy.OneForAll => { this.restartAll(); },
			RestartStrategy.RestForOne => { this.restartFrom(childIdx); },
		};
	}

	// Idle timeout tick — checks pending shutdown deadlines (Erlang: shutdown timeout)
	onIdle(): void {
		if (this.pendingPids.length === 0) {
			setIdleTimeout(this.pid, 0);
			return;
		}
		const now = clockMs();
		let i = 0;
		while (i < this.pendingPids.length) {
			if (now >= this.pendingDeadlines[i]) {
				// Deadline passed — force kill (Erlang: brutal_kill after timeout)
				const pid = this.pendingPids[i];
				this.removePendingAt(i);
				stop(pid, ExitReason.Killed);
			} else {
				i = i + 1;
			}
		}
		// Disable timer when no more pending shutdowns
		if (this.pendingPids.length === 0) {
			setIdleTimeout(this.pid, 0);
		}
	}

	onTerminate(reason: ExitReason): void {
		this.stopChildrenFrom(0);
	}

	// ===== Shutdown protocol (Erlang: shutdown spec per child) =====

	private shutdownChild(idx: number): void {
		const pid = this.pids[idx];
		if (pid === 0) return;
		const spec = this.specs[idx];
		match (spec.shutdown) {
			ShutdownKind.BrutalKill => {
				// Keep link — onExit will mark pids[idx] = 0
				stop(pid, ExitReason.Killed);
			},
			ShutdownKind.Infinity => {
				// Unlink so we don't get cascading EXIT, mark stopped immediately
				unlink(this.pid, pid);
				this.pids[idx] = 0;
				stop(pid, ExitReason.Normal);
			},
			ShutdownKind.Timeout => {
				// Unlink so we don't get cascading EXIT, mark stopped immediately
				unlink(this.pid, pid);
				this.pids[idx] = 0;
				stop(pid, ExitReason.Normal);
				// Record pending shutdown with deadline for force-kill
				this.pendingPids.push(pid);
				this.pendingDeadlines.push(clockMs() + spec.shutdownMs);
				// Enable idle timer to check deadlines
				setIdleTimeout(this.pid, 100);
			},
		};
	}

	private stopChildrenFrom(startIdx: number): void {
		let i = this.pids.length;
		while (i > startIdx) {
			i = i - 1;
			if (this.pids[i] !== 0) {
				this.shutdownChild(i);
			}
		}
	}

	private restartChildrenFrom(startIdx: number): void {
		for (let j = startIdx; j < this.specs.length; j = j + 1) {
			const newPid = this.specs[j].start();
			this.pids[j] = newPid;
			link(this.pid, newPid);
		}
	}

	private restartAll(): void {
		this.stopChildrenFrom(0);
		this.restartChildrenFrom(0);
	}

	private restartFrom(idx: number): void {
		this.stopChildrenFrom(idx);
		this.restartChildrenFrom(idx);
	}

	// ===== Internal helpers =====

	private checkTolerance(): boolean {
		const now = clockMs();
		const threshold = now - (this.maxSeconds * 1000);
		const recent: number[] = [];
		for (const t of this.restartTimes) {
			if (t >= threshold) recent.push(t);
		}
		recent.push(now);
		this.restartTimes = recent;
		return recent.length <= this.maxRestarts;
	}

	private findChild(childPid: int64): number {
		for (let i = 0; i < this.pids.length; i = i + 1) {
			if (this.pids[i] === childPid) return i;
		}
		return -1;
	}

	private findChildByName(name: string): number {
		for (let i = 0; i < this.specs.length; i = i + 1) {
			if (this.specs[i].name === name) return i;
		}
		return -1;
	}

	private removeChildAt(idx: number): void {
		// Shift-remove (not swap) to preserve ordering for RestForOne
		let i = idx;
		while (i < this.specs.length - 1) {
			this.specs[i] = this.specs[i + 1];
			this.pids[i] = this.pids[i + 1];
			i = i + 1;
		}
		this.specs.pop();
		this.pids.pop();
	}

	private clearPendingShutdown(pid: int64): void {
		for (let i = 0; i < this.pendingPids.length; i = i + 1) {
			if (this.pendingPids[i] === pid) {
				this.removePendingAt(i);
				return;
			}
		}
	}

	private removePendingAt(idx: number): void {
		const last = this.pendingPids.length - 1;
		if (idx !== last) {
			this.pendingPids[idx] = this.pendingPids[last];
			this.pendingDeadlines[idx] = this.pendingDeadlines[last];
		}
		this.pendingPids.pop();
		this.pendingDeadlines.pop();
	}
}

// ===== DynSupervisor — simple_one_for_one parity =====
//
// All children use the same spec. Dynamic add/remove only.
// Restart strategy is always OneForOne (each child is independent).

export actor DynSupervisor {
	private spec: ChildSpec;
	private maxRestarts: number;
	private maxSeconds: number;
	private pids: int64[];
	private restartTimes: number[];

	constructor(spec: ChildSpec, maxRestarts: number, maxSeconds: number) {
		this.spec = spec;
		this.maxRestarts = maxRestarts;
		this.maxSeconds = maxSeconds;
		this.pids = [];
		this.restartTimes = [];
	}

	startChild(): int64 {
		const pid = this.spec.start();
		this.pids.push(pid);
		link(this.pid, pid);
		return pid;
	}

	terminateChild(pid: int64): void {
		const idx = this.findChild(pid);
		if (idx < 0) return;
		unlink(this.pid, pid);
		this.removeChild(idx);
		stop(pid, ExitReason.Killed);
	}

	countChildren(): number {
		return this.pids.length;
	}

	onExit(childPid: int64, reason: ExitReason): void {
		const childIdx = this.findChild(childPid);
		if (childIdx < 0) return;

		this.removeChild(childIdx);

		// Check restart type
		const shouldRestart = match (this.spec.restart) {
			RestartType.Permanent => true,
			RestartType.Transient => reason !== ExitReason.Normal,
			RestartType.Temporary => false,
		};
		if (!shouldRestart) return;

		if (!this.checkTolerance()) {
			console.log("dyn-supervisor: max restart intensity reached, shutting down");
			stop(this.pid, ExitReason.Abnormal);
			return;
		}

		// Restart: start new instance, add to pool
		const newPid = this.spec.start();
		this.pids.push(newPid);
		link(this.pid, newPid);
	}

	onTerminate(reason: ExitReason): void {
		for (let i = this.pids.length - 1; i >= 0; i = i - 1) {
			stop(this.pids[i], ExitReason.Killed);
		}
	}

	private checkTolerance(): boolean {
		const now = clockMs();
		const threshold = now - (this.maxSeconds * 1000);
		const recent: number[] = [];
		for (const t of this.restartTimes) {
			if (t >= threshold) recent.push(t);
		}
		recent.push(now);
		this.restartTimes = recent;
		return recent.length <= this.maxRestarts;
	}

	private removeChild(idx: number): void {
		this.pids[idx] = this.pids[this.pids.length - 1];
		this.pids.pop();
	}

	private findChild(pid: int64): number {
		for (let i = 0; i < this.pids.length; i = i + 1) {
			if (this.pids[i] === pid) return i;
		}
		return -1;
	}
}
