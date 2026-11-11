# Cloud processing plan

The paid cloud path: a game's footage, already in S3, becomes the followed
game video on a Spot GPU, with the pitch and kit checks answered on the
website. It runs the same engine as the Mac app
([MAC-APP-PLAN.md](MAC-APP-PLAN.md), step F there). The overall plan is in
[PLAN.md](PLAN.md); open work in [BACKLOG.md](BACKLOG.md).

## Where things stand

- Built: uploads, the merged manifest, the `RecordingReady` event (logged
  only), signed footage links, deletion.
- Built 2026-11-10, steps 1-3 below: the job record and API, the Batch
  stack, a stub engine, and the website's job flow and checks. Tested
  locally (API against moto, the stack by synthesis, the website against
  its mock API). **Not deployed yet:** nothing has run in AWS.
- Not built: the real engine in a container (step 4).
- The engine is still the spikes (`fullgame.py` and the steps before it),
  with `-hwaccel videotoolbox` and `h264_videotoolbox` hard-coded in
  `follow.py` and `fullgame.py`. `osb-engine prepare / run` is the Mac
  plan's step A, not started. CUDA has never been run: the 2-3 h per game
  is an estimate.
- The GPU Spot quota for G instances in `us-west-2` was granted on
  2026-11-10 (8 vCPUs requested). There is no on-demand quota yet.

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

### Left from steps 1-3

- **Deploy and try it** (`infra/README.md`, "Cloud processing"): deploy
  the stack, push the stub image, switch cloud processing on for an
  account on the Admin page, and take a game from the button to the
  stub's test-pattern video. This is step 2's "done when", and the first
  time the IAM policies, the Fargate network and the Batch events are
  exercised for real.
- **Emails need a sender.** They go out only when the stack has
  `emailFrom`, an address SES has verified (and SES out of its sandbox to
  reach other people).
- **The fixture is drawn, not rec7.** The stub engine and the website's
  mock show a made-up pitch and kit groups. A replay of a real run comes
  with the engine commands (Mac plan step A).
- **No share switches.** The Mac plan's "share this pitch map / these
  groups" switches are left off the website until the contributions
  backend and its privacy section exist (Mac plan step C).
- **No alarm.** Instead of an alarm for a job waiting over an hour, the
  GPU queue fails a job that cannot start (1 hour for a job no instance
  fits, 12 hours without Spot capacity) and its owner is emailed. Nobody
  is told on our side; that comes with the admin page of jobs (step 6).
- **The privacy policy** says nothing yet about the rendered video or the
  checks' pictures (kept 180 days from when they are made). It needs that
  line before cloud processing is switched on for anyone but us.

## Cost

Per game, to be measured in step 4: 2-3 h of one `g5.xlarge` or
`g6.xlarge` on Spot at roughly $0.30-0.45 an hour, so about $1-1.50, or
$2-3 on demand. The scratch disk is cents. Nothing runs between games: no
NAT gateway, Batch at zero instances, the image in ECR (a few GB, cents a
month).

Guards: 8 vCPUs maximum, job timeouts, 5 attempts, and a billing alarm.
Each job records its instance time so cost per game is known from the
first run.

## Risks

- **CUDA is unmeasured.** Decode through an ffmpeg subprocess per phone
  should carry over; the detector on a 24 GB A10G or L4 may need smaller
  batches or fp16 to reach the estimate. If a game takes 5 h instead of
  2-3, the cost doubles but the design holds.
- **Refit wait.** Marking the pitch or splitting a kit group means a
  container start (1-2 minutes for a multi-GB image) before the user sees
  the result, against seconds on the Mac. If that is too slow, build a
  small CPU-only image for refits.
- **Spot capacity.** A queued job can wait when no G instances are on
  offer. The alarm tells us; an admin can resubmit to on-demand.
- **Two UIs for the checks.** The website and the Mac app each draw the
  pitch and kit checks. The question files carry the geometry and the
  images so both only draw, but changes to the checks land twice.

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
