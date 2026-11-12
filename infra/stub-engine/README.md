# stub-engine

A stand-in for the engine's container, so cloud processing can be deployed
and tried before the real engine exists. License: Apache-2.0. The real
engine is in the opensportsball-processing repository (AGPL-3.0-only);
nothing here comes from it.

It keeps the container's side of the contract in `docs/API.md` ("The
engine's container"), in the real engine's formats: started with
`prepare`, `refit` or `run` and the `OSB_*` variables, it writes
`questions/questions.json` (engine-questions) and its pictures, applies
`answers.json` (engine-answers), writes `game.mp4`, reports progress on
the job record, and exits 0, or non-zero with an error on the record. Like
the real engine it asks the kit question again, with the reason, when an
answer leaves fewer than two kit groups. It reads no footage; it only
checks the manifest is there, and it never asks the cameras question.

| File | What |
|---|---|
| `stub.mjs` | The three commands |
| `scene.mjs` | The made-up game: a drawn pitch whose first fit is off at one end, and five kit groups, one of them two kits mixed |
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
