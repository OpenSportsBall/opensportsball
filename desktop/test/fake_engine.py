#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 The OpenSportsBall Authors
# SPDX-License-Identifier: Apache-2.0
"""A stand-in for osb-engine in the app's tests: the same commands, files
and progress lines (shared/schemas/engine-*), none of the work. prepare asks
for the pitch and the kits until answers approve them; run writes a game.mp4
and says, from its second chunk, that it doesn't know the ball; label makes a
ball set of three frames and stores the answers it is given."""
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


# A 1x1 PNG: the frames of a label set (the app only needs a picture it can decode).
PNG = bytes.fromhex("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c489"
                    "0000000d49444154789c6300010000000500010d0a2db40000000049454e44ae426082")


def ball(done):
    aim = [31, 2, 0, 1][:done]
    b = {"ballAimShare": round(sum(aim) / len(aim) / 100, 3), "ballAimByChunk": aim}
    if done >= 2:
        b["ballLow"] = True
    return b


def chunk_details(done):
    stage = lambda ok: {"status": "done", "seconds": 1500.0} if ok else {"status": "waiting"}  # noqa: E731
    return [{"chunk": k, "startS": 600.0 * k, "seconds": 600.0, "ball": stage(k < done), "follow": stage(k < done),
             **({"ballAimPct": [31, 2, 0, 1][k], "ballDetectedPct": 5} if k < done else {})} for k in range(4)]


if cmd == "status":
    out = rec / "fullgame" / "game.mp4"
    done = 4 if out.exists() else 0
    emit("status", prepared=(eng / "questions.json").exists(), pending=pending(), pieces=0,
         output=str(out) if out.exists() else None, chunkDetails=chunk_details(done) if done else [],
         **(ball(done) if done else {}))
elif cmd == "label" and args[:1] == ["ball"]:
    sd = eng / "labels" / "ball-1"
    (sd / "images").mkdir(parents=True, exist_ok=True)
    items = []
    for i in range(3):
        (sd / "images" / f"b{i}.jpg").write_bytes(PNG)
        items.append({"id": f"b{i}", "image": f"images/b{i}.jpg", "videoT": 100.0 * (i + 1), "width": 3840,
                      "height": 2160, "pick": "detected", "judged": False, "heldOut": False, "answered": False,
                      "suggestions": [{"x": 1000.0 + i, "y": 500.0, "conf": 0.6}] if i < 2 else []})
    (sd / "set.json").write_text(json.dumps({"schemaVersion": 1, "set": "ball-1", "kind": "ball", "labelled": 0,
                                             "items": items}))
    emit("labelset", set="ball-1", kind="ball", path=str(sd / "set.json"), items=3)
elif cmd == "label":
    sd = eng / "labels" / answers["set"]
    p = sd / "answers.json"
    merged = {**(json.loads(p.read_text()) if p.exists() else {}), **answers["ball"]}
    p.write_text(json.dumps(merged))
    s = json.loads((sd / "set.json").read_text())
    for it in s["items"]:
        it["answered"] = it["id"] in merged
    s["labelled"] = len(merged)
    (sd / "set.json").write_text(json.dumps(s))
    emit("labels", set=answers["set"], labelled=len(merged), items=len(s["items"]))
elif cmd == "share":
    (eng / "share").mkdir(exist_ok=True)
    (eng / "share" / "ball-1.json").write_text(json.dumps({"name": "ball-1", "kind": "ball"}))
    emit("share", name="ball-1", path=str(eng / "share" / "ball-1.json"), files=4)
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
        emit("ball", chunksDone=i, chunks=4, **ball(i))
        time.sleep(0.05)
    out = rec / "fullgame" / "game.mp4"
    out.parent.mkdir(exist_ok=True)
    out.write_bytes(b"not really a video")
    emit("done", output=str(out), seconds=1, **ball(4))
