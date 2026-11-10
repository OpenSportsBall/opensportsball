#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for osb-engine in the app's tests: the same commands, files
and progress lines (shared/schemas/engine-*), none of the work. prepare asks
for the pitch and the kits until answers approve them; run writes a game.mp4."""
import json
import sys
import time
from pathlib import Path

cmd, job_path = sys.argv[1], Path(sys.argv[2])
args = sys.argv[3:]
job = json.loads(job_path.read_text())
rec = Path(job["recording"])
eng = rec / "engine"
eng.mkdir(parents=True, exist_ok=True)
answers = json.loads(Path(args[args.index("--answers") + 1]).read_text()) if "--answers" in args else {}
(eng / "calls.jsonl").open("a").write(json.dumps({"cmd": cmd, "answers": answers, "job": job}) + "\n")


def emit(event, **kw):
    print(json.dumps({"event": event, "at": "2026-11-10T12:00:00-0800", **kw}), flush=True)


def pending():
    p = []
    if (answers.get("pitch") or {}).get("approve") is not True:
        p.append("pitch")
    if "kits" not in answers:
        p.append("kits")
    return p


if cmd == "status":
    out = rec / "fullgame" / "game.mp4"
    emit("status", prepared=(eng / "questions.json").exists(), pending=pending(), pieces=0,
         output=str(out) if out.exists() else None)
elif cmd == "prepare":
    for s in ("verify-footage", "sync", "pitch"):
        emit("step", step=s, status="started", log=f"engine/logs/{s}.log")
        emit("step", step=s, status="done", seconds=0.1)
    (rec / "pitch").mkdir(exist_ok=True)
    q = {
        "schemaVersion": 1, "recording": str(rec), "pending": pending(),
        "pitch": {"round": 1, "status": "pending" if "pitch" in pending() else "approved",
                  "background": "pitch/background.png", "overlay": "pitch/overlay.jpg",
                  "panorama": {"image": "background.png", "degPerPx": 0.5, "yawRange": [-50, 50], "pitchRange": [0, 20]},
                  "fit": {}, "lines": [[[-40, 10], [40, 10]]], "goals": [],
                  "points": {"left corner flag": {"yaw": -40, "pitch": 10}}, "approveAllowed": True},
        "kits": {"round": 1, "status": "pending" if "kits" in pending() else "answered", "k": 8, "splitAllowed": True,
                 "groups": [{"component": 0, "people": 10, "perMoment": 5, "proposed": "A",
                             "crops": [{"id": "c0_00", "image": "engine/crops/c0_00.jpg", "frame": "f", "box": [0, 0, 1, 1]}]}]},
    }
    (eng / "questions.json").write_text(json.dumps(q))
    emit("questions", path="engine/questions.json", pending=pending())
elif cmd == "run":
    if pending():
        emit("needs_answers", pending=pending(), questions="engine/questions.json")
        sys.exit(3)
    for i in range(1, 4):
        emit("progress", stage="game", fraction=i / 4, chunks=4, elapsedS=i, etaS=4 - i)
        time.sleep(0.05)
    out = rec / "fullgame" / "game.mp4"
    out.parent.mkdir(exist_ok=True)
    out.write_bytes(b"not really a video")
    emit("done", output=str(out), seconds=1)
