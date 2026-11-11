# stub-engine

A stand-in for the engine's container, so cloud processing can be deployed
and tried before the real engine exists. License: Apache-2.0. The real
engine is in the opensportsball-processing repository (AGPL-3.0-only);
nothing here comes from it.

It keeps the container's side of the contract in `docs/API.md` ("The
engine's container"): started with `prepare`, `refit` or `run` and the
`OSB_*` variables, it writes `questions/questions.json` and its pictures,
or `game.mp4`, under the job's output folder, reports progress on the job
record, and exits 0, or non-zero with an error on the record. It reads no
footage; it only checks the manifest is there.

| File | What |
|---|---|
| `stub.mjs` | The three commands |
| `scene.mjs` | The made-up game: a drawn pitch whose first fit is off at one end, and three kit groups, one of them two kits mixed |
| `video.mjs` | A 3-second test pattern, standing in for the game video |

Build and push it with `../scripts/push-stub-engine.sh` (see
`../README.md`, "Cloud processing").

| Variable | Default | Meaning |
|---|---|---|
| `OSB_STUB_SECONDS` | `20` | How long `prepare` and `run` pretend to work |
| `OSB_STUB_FAIL` | none | Fail halfway with this error code, to see a failed job |

`run` writes a checkpoint under the work prefix after each step and
resumes from it, as the real engine must when a Spot instance is taken
away.
