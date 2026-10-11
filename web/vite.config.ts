// SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
// SPDX-License-Identifier: Apache-2.0
import { readFileSync } from 'node:fs';
import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig, type Plugin } from 'vite';

/**
 * `npm run dev:mock` runs `vite dev --mode mock`. In that mode the dev server
 * answers `/config.json` with `config.mock.json` (apiUrl "mock"), so no AWS is
 * needed and a real `static/config.json` is left untouched.
 */
function mockConfig(mode: string): Plugin {
	return {
		name: 'osb-mock-config',
		apply: 'serve',
		configureServer(server) {
			if (mode !== 'mock') return;
			server.middlewares.use((req, res, next) => {
				if (req.url?.split('?')[0] !== '/config.json') return next();
				res.setHeader('Content-Type', 'application/json');
				res.setHeader('Cache-Control', 'no-store');
				res.end(readFileSync(new URL('./config.mock.json', import.meta.url)));
			});
		}
	};
}

export default defineConfig(({ mode }) => ({
	plugins: [
		mockConfig(mode),
		sveltekit({
			// Pure SPA: nothing is prerendered; S3 + CloudFront serve index.html
			// for every route (see README).
			adapter: adapter({ pages: 'build', assets: 'build', fallback: 'index.html' })
		})
	],
	test: {
		include: ['tests/**/*.test.ts'],
		environment: 'node'
	}
}));
