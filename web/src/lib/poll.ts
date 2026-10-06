// SPDX-FileCopyrightText: 2026 The SportsBallVideo Authors
// SPDX-License-Identifier: Apache-2.0

/**
 * Calls `tick` every `intervalMs` (after the previous call finishes) while
 * `tick` returns true. Returns a stop function. Timers never overlap.
 */
export function poll(tick: () => Promise<boolean> | boolean, intervalMs: number): () => void {
	let stopped = false;
	let timer: ReturnType<typeof setTimeout> | undefined;
	const schedule = () => {
		if (stopped) return;
		timer = setTimeout(async () => {
			let again = false;
			try {
				again = await tick();
			} catch {
				again = true;
			}
			if (again) schedule();
		}, intervalMs);
	};
	schedule();
	return () => {
		stopped = true;
		clearTimeout(timer);
	};
}
