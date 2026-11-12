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
    copy = out.with_name("game-youtube.mp4")
    done = 4 if out.exists() else 0
    emit("status", prepared=(eng / "questions.json").exists(), pending=pending(), pieces=0,
         output=str(out) if out.exists() else None, youtubeOutput=str(copy) if copy.exists() else None,
         chunkDetails=chunk_details(done) if done else [],
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
    import hashlib

    # The answers prepare was last given (the app passes them every time).
    given = {}
    for line in (eng / "calls.jsonl").read_text().splitlines():
        c = json.loads(line)
        if c["cmd"] in ("prepare", "run") and c["answers"]:
            given = c["answers"]

    def share_one(name, kind, paths):
        files = []
        for rel, data in paths.items():
            f = rec / rel
            f.parent.mkdir(parents=True, exist_ok=True)
            if not f.exists():
                f.write_bytes(data)
            b = f.read_bytes()
            files.append({"path": rel, "bytes": len(b), "sha256": hashlib.sha256(b).hexdigest()})
        (eng / "share").mkdir(exist_ok=True)
        doc = {"schemaVersion": 1, "name": name, "kind": kind,
               "recording": {"gameId": "11111111-2222-3333-4444-555555555555"}, "engine": {"version": "fake"},
               "createdAt": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "summary": {"files": len(files)}, "files": files}
        (eng / "share" / f"{name}.json").write_text(json.dumps(doc))
        emit("share", name=name, path=str(eng / "share" / f"{name}.json"), files=len(files))

    for q, paths in (("pitch", {"pitch/pitch.json": b"{}", "pitch/background.png": PNG}),
                     ("kits", {"engine/crops/c0_00.jpg": PNG})):
        a = given.get(q)
        if a is None:
            emit("share", name=q, path=None, reason="not answered yet")
        elif a.get("share") is False:
            emit("share", name=q, path=None, reason="the user chose not to share it")
        else:
            share_one(q, q, paths)
    sd = eng / "labels" / "ball-1"
    if (sd / "answers.json").exists():
        marked = json.loads((sd / "answers.json").read_text())
        share_one("ball-1", "ball", {"engine/labels/ball-1/answers.json": b"",
                                     **{f"engine/labels/ball-1/images/{i}.jpg": PNG for i in sorted(marked)}})
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
    out = rec / "fullgame" / "game.mp4"
    if not out.exists():
        for i in range(1, 4):
            emit("progress", stage="game", fraction=i / 4, chunks=4, elapsedS=i, etaS=4 - i)
            emit("ball", chunksDone=i, chunks=4, **ball(i))
            time.sleep(0.05)
        out.parent.mkdir(exist_ok=True)
        out.write_bytes(b"not really a video")
    yt = {}
    if job.get("output", {}).get("youtubeCopy"):  # beside game.mp4; a finished game gets only the copy
        copy = out.with_name("game-youtube.mp4")
        if not copy.exists():
            emit("step", step="youtube", status="started")
            copy.write_bytes(b"a bigger not really a video")
            emit("step", step="youtube", status="done", seconds=0.1)
        yt = {"youtubeOutput": str(copy)}
    emit("done", output=str(out), **yt, seconds=1, **ball(4))
