# Contributing

Thanks for helping. Before you open a pull request:

1. **Sign the contributor license agreement (CLA).** Pull requests can't be
   merged until it is signed. The CLA lets the maintainers relicense
   contributions, which is required to offer the processing pipeline
   (opensportsball-processing) under a commercial license alongside the
   AGPL. (TODO before the repo goes public:
   adopt a CLA text, based on the Apache Individual CLA, and connect CLA
   Assistant.)
2. **Read [docs/LICENSING.md](docs/LICENSING.md).** Everything here is
   Apache-2.0. Never import, vendor or link the AGPL processing code, and
   add no AGPL or GPL dependencies.
3. **Add the Apache-2.0 SPDX header** to every new source file.
4. **Run the license check:** `python3 scripts/check_licenses.py`.

## Footage and privacy

Game footage shows minors. Never commit video, frames, or labeled datasets
to this repository; `.gitignore` blocks common video formats. Share test
footage privately and only with the consent of the families involved.
