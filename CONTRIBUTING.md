# Contributing

Thanks for helping. Before you open a pull request:

1. **Sign the contributor license agreement (CLA).** Pull requests can't be
   merged until it is signed. The CLA lets the maintainers relicense
   contributions, which is required to offer `processing/` under a
   commercial license alongside the AGPL. (TODO before the repo goes public:
   adopt a CLA text, based on the Apache Individual CLA, and connect CLA
   Assistant.)
2. **Read [docs/LICENSING.md](docs/LICENSING.md).** Code in `processing/` and
   `ml/` is AGPL-3.0-only; everything else is Apache-2.0. Apache code must
   never import AGPL code.
3. **Add the SPDX header** for your directory to every new source file.
4. **Run the license check:** `python3 scripts/check_licenses.py`.

## Footage and privacy

Game footage shows minors. Never commit video, frames, or labeled datasets
to this repository; `.gitignore` blocks common video formats. Share test
footage privately and only with the consent of the families involved.
