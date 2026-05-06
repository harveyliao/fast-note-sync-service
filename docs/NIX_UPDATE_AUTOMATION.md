# Nix Update Automation Notes

This document records the validation path for the Nix packaging and update automation added in this fork.

## Goal

The Nix flake in `nix/flake.nix` packages `haierkeys/fast-note-sync-service`. Each upstream release requires three coupled updates:

- `version`
- `hash` for the GitHub source archive
- `vendorHash` for Go module dependencies

The update workflow automates that process by checking the latest upstream release, resolving both hashes with Nix, verifying the build, verifying flake evaluation, pushing an update branch, and opening a pull request.

## Added Files

- `nix/flake.nix` and `nix/flake.lock`: Nix package and NixOS module.
- `nix/README.md`: usage documentation for the package and module.
- `.github/workflows/nix.yml`: CI for Nix package/module changes.
- `scripts/update-nix-version.sh`: local and CI updater for version/hash/vendorHash.
- `.github/workflows/nix-update.yml`: scheduled and manual GitHub Actions automation.

## Validation Journey

The first manual workflow run was started on `master` before the Nix flake had been merged there.
It failed because `nix/flake.nix` was not present on that branch.

Evidence:
https://github.com/harveyliao/fast-note-sync-service/actions/runs/25411209900

After merging the Nix flake work into `master`, the updater found upstream `v2.13.7`, resolved the source hash and vendor hash, then failed during the final package build. Nix was building every Go package in the source tree, including generated mocks that do not compile in upstream `v2.13.7`. The package was fixed to build only the service binary package with:

```nix
subPackages = [ "." ];
```

The same run also exposed a script cleanup bug: after a failed `nix build`, the script had changed into `nix/`, so its restore path tried to write `nix/flake.nix` from the wrong directory. The build/check helpers now run in subshells so cleanup paths stay rooted at the repository root.

Evidence:
https://github.com/harveyliao/fast-note-sync-service/actions/runs/25411417995

The next workflow run completed the Nix update and pushed `chore/nix-bump-v2.13.7`, but failed to create the PR because GitHub Actions did not yet have permission to create pull requests in the fork.

Evidence:
https://github.com/harveyliao/fast-note-sync-service/actions/runs/25411618927

After enabling "Allow GitHub Actions to create and approve pull requests", the rerun failed because the update branch already existed from the previous run. The workflow now fetches the update branch before `git push --force-with-lease`, making reruns deterministic.

Evidence:
https://github.com/harveyliao/fast-note-sync-service/actions/runs/25411890959

The final rerun succeeded. It updated the Nix package from `v2.13.6` to `v2.13.7`, pushed the update branch, and opened the update PR.

Evidence:
https://github.com/harveyliao/fast-note-sync-service/actions/runs/25412099795

The duplicate-work guard was also tested by rerunning while the bump PR already existed. The workflow skipped as expected.

Evidence:
https://github.com/harveyliao/fast-note-sync-service/actions/runs/25412824772

## Local Verification

The generated update branch was fetched and built locally:

```bash
git fetch origin
git switch -c verify-nix-bump origin/chore/nix-bump-v2.13.7
nix build ./nix#fast-note-sync-service
nix flake check ./nix
```

`nix flake check ./nix` passed on the local system and warned that `aarch64-linux` checks were omitted, which is expected on an incompatible host.

## Upstreaming Notes

For upstream, send the work as a small sequence of pull requests if possible:

1. Add the Nix flake, NixOS module, and `nix/README.md`.
2. Add `.github/workflows/nix.yml` to build/check the flake on Nix changes.
3. Add `scripts/update-nix-version.sh` and `.github/workflows/nix-update.yml`.

Keeping the update automation separate from the initial Nix packaging makes review easier. The maintainer can first decide whether the Nix package/module shape is acceptable, then review the scheduled automation as a follow-up.

Before opening upstream PRs, confirm the target repository is comfortable with:

- GitHub Actions having `contents: write` and `pull-requests: write`.
- Enabling "Allow GitHub Actions to create and approve pull requests" if they want `gh pr create` to work with `GITHUB_TOKEN`.
- Weekly scheduled update checks.
- The generated branch naming convention `chore/nix-bump-vX.Y.Z`.

If upstream does not want Actions to create PRs, the workflow can be adjusted to push a branch only, or the updater script can remain as a manual maintainer tool.
