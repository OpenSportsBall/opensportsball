# Cloud processing plan

The paid cloud path: a game's footage, already in S3, becomes the followed
game video on a Spot GPU, with the pitch and kit checks answered on the
website. It runs the same engine as the Mac app
([MAC-APP-PLAN.md](MAC-APP-PLAN.md), step F there). The overall plan is in
[PLAN.md](PLAN.md); open work in [BACKLOG.md](BACKLOG.md).

## Where things stand

- Built: uploads, the merged manifest, the `RecordingReady` event (logged
  only), signed footage links, deletion.
- Steps 1-3, built and **deployed 2026-11-10** with the stub engine: the
  job record and API, the Batch stack, the website's job flow and checks.
  In AWS so far only a smoke test has run (the stub on Fargate with a
  made-up job); no recording has gone through.
- Step 4, built 2026-11-11 and **not deployed, not run on a GPU**: the
  real engine's cloud wrapper and image (opensportsball-processing,
  branch `cloud-engine`), and this repo moved onto the engine's own
  question and answer formats. See "Step 4 so far".
- The Spot quota for G instances in `us-west-2` was granted on 2026-11-10
  (8 vCPUs requested). There is no on-demand quota yet.

## Decisions

The first three were agreed on 2026-11-10 and are in PLAN.md; the rest
are proposed here.

| Decision | Choice | Why |
|---|---|---|
| What starts a job | The user, with "Process in the cloud" on the game's page. `RecordingReady` no longer starts anything | The cloud is paid and never pushed, and the pitch check needs the user anyway. An account setting to start automatically can come with payments |
| Orchestration | No Step Functions. The API submits Batch jobs; one EventBridge rule on Batch state changes updates the job record | The flow stops for a person for hours or days between prepare and run. The job record both plans need already holds that state; a state machine would hold it twice |
| Two jobs per game | `prepare` (minutes), then `run` (hours) after the answers | Same split as the Mac app. No GPU is held while the user is asleep |
| Who may use it, before payments | Accounts with a `cloudProcessing` flag an admin sets | Lets it ship and be tested before pricing is decided. Payments are a separate plan |
| Compute | Batch managed EC2, Spot, `g5.xlarge` / `g6.xlarge` (24 GB GPU, 16 GB RAM), min 0, max 8 vCPUs (two games at once, the quota). 200 GB gp3 scratch disk | Mac peak was 8.4 GB. A game is 40-50 GB in, ~22 GB out, plus pieces |
| Network | A new VPC with public subnets only, no NAT gateway, an S3 gateway endpoint, no inbound rules | A NAT gateway is ~$32 a month idle. Footage comes from S3 in the same region, free, not through CloudFront |
| Engine image | Built from opensportsball-processing by its CI, pushed to an ECR repository this stack creates. The stack takes the tag as context (`engineImage`). The S3 and status wrapper lives in that repo (AGPL) | The one-way boundary in [LICENSING.md](LICENSING.md): this repo names an image and reads files, nothing else |
| Models | Pulled at job start from `models/<version>/` in the footage bucket; the image pins names and sha256 | A new ball colour needs a retrain, not an image build, and the weights stay out of the image |
| Outputs | `outputs/<accountId>/games/<gameId>/recordings/<recordingId>/jobs/<jobId>/` in the footage bucket. Checkpoints in `work/...` with a 7-day expiry | Not under `accounts/`: everything there counts as uploaded footage (the admin page's storage, the 180-day expiry from upload), and every `.mp4` created there wakes the ingest Lambda |
| Status | The server owns `status`: it follows Batch's state changes and looks in S3 for what the container left (questions or the video). The container may only add `progress` and `error` to the job record, limited by IAM to job items | A container that dies without a word still ends the job; "job status records" are already an allowed contract across the license boundary |
| Spot interruption | Each finished chunk's piece and ball candidates are copied to `work/`; a retry restores them and `fullgame.py`'s skip-if-exists resumes. Batch retries up to 5 times on host termination only | At most one 10-minute chunk of work is lost |
| YouTube | Not here. The job ends with `game.mp4` in S3, watched or downloaded from the website | Phase 5's upload task reads the same file, for cloud and local games |

## Flow

```
website: "Process in the cloud"
   POST .../jobs {where: "cloud"}      job: queued
        |
   Batch: osb-engine prepare           job: preparing
     manifest + segments from S3 -> sync, background panorama,
     pitch guess, kit groups -> questions/ in outputs/
        |                              job: needs_answers  (email)
website: pitch check, kit check
   PUT .../jobs/{id}/answers
     pitch marked or a kit group split -> short refit job, questions again
        |
   Batch: osb-engine run               job: running (stage, %, time left)
     chunks -> work/ ; game.mp4 -> outputs/
        |                              job: done  (email)
website: watch, download              (Phase 5: send to YouTube)
```

Job states: `queued`, `preparing`, `needs_answers`, `refitting`,
`running`, `done`, `failed` (with the engine's error code), `cancelled`.
A local run writes the same record with `where: "local"`, so the website
shows "processing on your Mac" and doesn't offer the cloud for that game
while it runs.

Cases the record has to handle:

- **Second `RecordingReady`** (a Secondary that got permission later). A
  job in flight is cancelled; a finished one is kept and the game's page
  offers "Process again with both phones". Nothing reruns unasked. This
  replaces BACKLOG.md's "the second run replaces the first".
- **Deleted while processing.** Deleting a recording, game or account
  terminates its Batch jobs and deletes `outputs/` and `work/` with the
  footage. The engine also stops at the next chunk if the manifest is gone.
- **One active job per recording**, enforced with a conditional write.

## What gets built

Steps 1-3 don't need the real engine: they run against a stub image that replays a recorded run. That is the replay fixture the Mac
plan already calls for (rec7), built once and used by both.

| Step | Work | Done when |
|---|---|---|
| 0. Now | File a quota request for on-demand G instances (the fallback when Spot has none; the Spot quota is granted). Agree the remaining decisions above | Request filed |
| 1. Job record and API (1-1.5 wk) | `job`, `questions`, `answers`, `progress` schemas in `shared/schemas/` (the Mac plan's, written once). `JOB#<gameId>#<recordingId>#<jobId>` items. Routes: start, get, cancel, questions (with signed image links), answers, output link; job state in `GET /games/{id}`. The `cloudProcessing` flag and an admin route to set it. Deletion covers `outputs/`, `work/` and running jobs. `footageUrls` signs an account's own outputs | API tests pass for every state change, the second-ready case and deletion mid-job |
| 2. Batch stack (1-1.5 wk) | VPC, Spot compute environment, queue, `prepare` / `run` / `refit` job definitions (timeouts 1 h / 12 h / 15 min), ECR repository, job role (read `accounts/` and `models/`, write `outputs/` and `work/`, update job items), launch template with the scratch disk, the state-change Lambda, lifecycle rules, log retention, an alarm for a job waiting over an hour. A CPU queue (Fargate) for the stub and for refits | From the API, the stub image goes queued to done in the deployed stack, and a killed job shows `failed` |
| 3. Website (2-3 wk) | Game page: start, progress, cancel, watch and download. Pitch check (approve, or drag the named keypoints and refit) and kit check (tap the wrong ones, merge or split), drawn from the question files as the Mac app draws them. Emails for "check the pitch" and "video ready" through SES (already on the backlog for Cognito) | With the mock API and the rec7 fixture, a test walks start to done through both checks |
| 4. Engine on CUDA (2-3 wk, processing repo, after the Mac plan's step A) | The platform module's CUDA side: NVDEC decode, `h264_nvenc`, PyTorch on CUDA for the detectors (fp16, ONNX Runtime or TensorRT later). The image: CUDA base, ffmpeg with NVDEC/NVENC, `NVIDIA_DRIVER_CAPABILITIES=compute,video,utility`. The cloud entrypoint: fetch from S3, models by pin, checkpoints to `work/`, progress to the job record, outputs up. The image carries its commit, and the website links to that source (AGPL section 13) | The must-see bench run on a GPU instance is within its rerun noise of the Mac's 34/46, and a whole game's time and cost are measured |
| 5. First real games (1 wk) | rec7 from the website's button to a watched video. Stop the instance mid-run and see it resume. A late Secondary. Delete mid-run. Write the measured time and cost into PLAN.md | A non-author's game goes through with no one touching AWS |
| 6. Later | Payments and price, start automatically per account, an admin page of jobs with retry and cost per job, the cost dashboard, self-host docs for the Batch part (Phase 6) | |

Step 4 waits on the engine commands, so the Mac plan's step A is the
critical path for a real cloud game; step B (the engine side of the
checks) is needed before step 5.

### Step 4 so far

The engine arrived (the Mac plan's steps A, B and D) with its own
commands and file formats, so step 4 became two things.

**In opensportsball-processing** (branch `cloud-engine`):

- `processing/spikes/cloud.py`, the only part of the engine that knows S3,
  DynamoDB and Batch. It fetches the footage to the scratch disk, runs
  `engine.py` as on a Mac, publishes the questions with their pictures or
  `game.mp4`, and keeps the recording folder's state in the job's work
  folder so the next command, or the next attempt after a reclaimed Spot
  instance, carries on.
- `engine.py prepare --answers --no-footage`: applying an answer reads the
  pictures the first prepare left, so a refit runs on a small CPU task
  without fetching the footage again (with it, if a step wants the video).
- `packaging/cloud/`: the image (Ubuntu 24.04, its ffmpeg with NVENC and
  the cuda hwaccel, pinned Linux packages; 3.6 GB), the models it expects
  by SHA-256, and what the first GPU run has to check.

**Here:**

- The API passes the engine's `questions.json` through (a signed link
  next to every picture) and takes answers in the engine's format. The
  engine decides what is still open (`pending`); the server no longer
  guesses. A refit that leaves nothing to ask starts the run, and a run
  the engine won't start (it refused an answer) sends the job back to the
  user with the engine's reason.
- The website's checks are redone on those formats, asked as the Mac app
  asks them: the pitch in panorama degrees, the kit groups with what each
  group is (a kit, keepers or referee, not a kit), and the cameras
  question for games whose views couldn't be stitched.
- The stub engine speaks the same formats, so the deployed stack can be
  tried end to end before a GPU is paid for.
- The stack: the job-events function may start the run; GPU jobs carry
  `OSB_REQUIRE_GPU=1`; refits have room for the footage.

Tested locally only: the wrapper against a local S3 and DynamoDB with a
stand-in engine, the API against moto, the stack by synthesis, the
website against its mock and in a browser. The image builds and starts.

### Left

- **Deploy this step** (the API, website and stack changes, and the stub
  image rebuilt in the new formats). Until then the deployed website and
  stub still use the first formats and work together.
- **A recording through the stub**, from the website's button to the
  test-pattern video: still not done.
- **The first GPU run**, in the order in opensportsball-processing's
  `packaging/cloud/README.md`: the GPU is seen, the driver is new enough
  for the PyTorch build, hardware decode and encode work, one chunk of
  one game (`OSB_JOB_OPTIONS`), then the bench and a whole game.
- **Models in the bucket.** The image fetches them from `models/`; they
  are not uploaded yet.
- **The line colour question** (`lineColour`, for pitches with lines of
  two colours) is not on the website; the engine's own choice stands.
- **Share switches.** The website always answers `share: false`. The Mac
  app has the switches and the approved wording; the website needs both
  before it may offer them.
- **Emails need a sender.** Set (`emailFrom`); not yet seen to arrive.
- **The fixture is drawn, not a real game.** The stub and the website's
  mock show a made-up pitch and kit groups.
- **No alarm.** A GPU job that cannot start fails after 1 hour (no
  instance fits) or 12 (no Spot capacity) and its owner is emailed. Nobody
  is told on our side; that comes with the admin page of jobs (step 6).
- **The privacy policy** says nothing yet about the rendered video or the
  checks' pictures (kept 180 days from when they are made). It needs that
  line before cloud processing is switched on for anyone but us.

## Cost

Not measured: nothing has run on a GPU. What the first runs can cost at
most, from the stack's own limits. Spot prices are what AWS quoted in
us-west-2 on 2026-11-11: `g5.xlarge` (one A10G, 24 GB) $0.56-0.64 an hour,
`g6.xlarge` (one L4, 24 GB) $0.45-0.75 depending on the zone. They move;
on-demand is about $1.01 and $0.80 (from memory, not checked):

| Run | Machine time | About |
|---|---|---|
| One chunk of one game (`maxChunks: 1`), with prepare | Under an hour of one `g5.xlarge` / `g6.xlarge` | $0.45-0.75 on Spot, about $1 on demand |
| A whole game, if the 2-3 h estimate holds | 2-3 h | $1-2.25 on Spot |
| A whole game at the job's time limit | 12 h (the `run` timeout), 13 with prepare | $6-10 on Spot, $10-13 on demand |
| A refit | Minutes of Fargate (2 vCPU, 8 GB) | Cents |

Also: the 200 GB scratch disk is about 2 cents an hour while an instance
is up; a finished game's video is ~22 GB in S3 (about $0.50 a month until
it expires); checkpoints are up to ~11 GB for 7 days. Footage moves
between S3 and the instance in the same region, free.

Nothing runs between games: no NAT gateway, both compute environments at
zero, the image in ECR (3.6 GB, about 36 cents a month).

Guards: at most 8 vCPUs (two instances), job timeouts (1 h, 12 h, 15 min),
5 attempts and only for a reclaimed Spot instance, a job that came up
without its GPU stops at once, and a queued job that can't get a machine
is cancelled. There is no billing alarm yet. Each job records its machine
time, so cost per game is known from the first run.

## Risks

- **CUDA is unmeasured.** Decode through an ffmpeg subprocess per phone
  should carry over; the detector on a 24 GB A10G or L4 may need smaller
  batches or fp16 to reach the estimate. If a game takes 5 h instead of
  2-3, the cost doubles but the design holds.
- **The Mac runs the detectors in Core ML; the cloud runs them in
  PyTorch.** They gave the same detections on the Mac bench, but the GPU
  result has to be benched on its own before a cloud video is trusted to
  match a local one.
- **The PyTorch build wants a recent NVIDIA driver** (CUDA 13). If the ECS
  GPU image's driver is older, the image needs a CUDA 12 build pinned.
- **Refit wait.** Marking the pitch or splitting a kit group means a
  Fargate task pulling a 3.6 GB image (a few minutes, to be measured)
  before the user sees the result, against seconds on the Mac. If that is
  too slow, build a small CPU-only image for refits: they need no PyTorch
  CUDA libraries.
- **Spot capacity.** A queued job can wait when no G instances are on
  offer. The alarm tells us; an admin can resubmit to on-demand.
- **Two UIs for the checks.** The website and the Mac app each draw the
  engine's questions. Both only draw, and both read the same files, but
  changes to the checks land twice (the line colour question is already
  on the Mac only).

## Open questions

- **How long outputs are kept.** The privacy policy covers footage (180
  days from upload). The rendered video needs its own line: the same 180
  days, or until the user deletes it.
- **Deleting raw footage after a render** (BACKLOG.md, Phase 3). With
  local processing and "process again", the raw footage is still wanted
  after the first render. Suggest dropping the rule and keeping the flat
  180 days.
- **Self-hosters.** The Batch part now deploys with every stack (it costs
  nothing idle, and no account can use it until an admin switches it on).
  Still open: whether it should sit behind a context flag, and whether a
  public engine image is published for them.
- **Price**, and whether prepare alone is free.
