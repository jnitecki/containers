# Containers — Project Context

A repository of standalone container definitions, one directory per container, grouped by category (`crypto/`, `development/`, ...). [CATALOG.md](../CATALOG.md) is the repo-wide index — every container gets an entry there.

## Per-container file convention

Each container directory follows this layout:

| File | Purpose |
|------|---------|
| `dockerfile` (or `Dockerfile.<os>` for multi-OS containers) | The image build definition. |
| `build-context/` (or `<os>-context/` for multi-OS containers) | Build context passed to `docker build`/`podman build`. |
| `build.ps1` (or `build-<os>.ps1` for multi-OS containers) | Builds and publishes the image — resolves/pins the upstream version, builds (multi-arch where applicable), tags, and pushes to Docker Hub. On a successful push, also syncs `README.md` and `hub-metadata.yml` to the Docker Hub repository via `Publish-DockerHubRepository` (see [scripts/](#repo-wide-scripts) below). Shared logic between OS variants lives in a dot-sourced `build-common.ps1`. |
| `hub-metadata.yml` | Docker Hub repository metadata that isn't part of `README.md` itself: `short_description` (≤100 chars) and, optionally, `categories` (a list of Docker Hub category slugs). Read by `build*.ps1` via `Import-HubMetadata`, not hand-transcribed into the script. |
| `run.ps1` (optional) | Host-side helper that pulls the current image, stops/removes any previous container(s), and starts fresh one(s). Not every container has one. |
| `entrypoint.sh` (or `entrypoint.ps1` for Windows) | The container's `ENTRYPOINT`, baked into the image and copied from `build-context/`/`<os>-context/`. Named `entrypoint.*` (the common convention) rather than `start.*`, which is why `run.ps1` — a *host-side* script — deliberately avoids that name too. |
| `BUILD.md` | Internal documentation: how to build the image and run the publish script — build command, version-pinning behavior, `build*.ps1` parameters, multi-arch/publish notes, known-issue/verification caveats. **Not** included in the Docker Hub description. |
| `README.md` | Docker Hub-facing documentation: how to **use** the already-published image — `docker run` examples, environment variables, volumes, ports. Must **not** contain build/publish instructions; those belong in `BUILD.md`. |

This split exists because `README.md` content is what gets pushed as the Docker Hub repository description — an audience that only ever pulls the finished image and has no reason to see build tooling.

## Repo-wide scripts

`scripts/` holds cross-container helpers dot-sourced by the per-container `build*.ps1` scripts (as opposed to `build-common.ps1`, which is per-container and only shared between that one container's OS variants):

- `scripts/dockerhub-common.ps1` — two functions used together by every `build*.ps1`:
  - `Import-HubMetadata -Path <hub-metadata.yml path>` parses that container's `hub-metadata.yml` (a restricted YAML subset — a `short_description: "..."` scalar and an optional `categories:` list — hand-rolled rather than pulling in a YAML module dependency for two fields) and returns `@{ ShortDescription; Categories }`. Never throws; a missing file or missing keys just come back empty.
  - `Publish-DockerHubRepository -Repository <namespace>/<name> -ReadmePath <path> -Description <text> -Categories <slug[]>` pushes a container's `README.md` (as `full_description`), a short one-line `description` (≤100 chars, Docker Hub's own limit), and optionally its category slugs to its Docker Hub repository, called by every `build*.ps1` right after its final image push succeeds. All three are optional and independent — pass whichever you have. Credentials are never prompted for or stored by this script — `Get-DockerHubCredential` reuses whatever `podman login`/`docker login` already wrote (`~/.config/containers/auth.json`, then `~/.docker/config.json`, including a `credsStore`/`credHelpers` fallback), or `$env:DOCKERHUB_USERNAME`/`$env:DOCKERHUB_TOKEN` if set. The password/token found there must be a Docker Hub Personal Access Token with **Read & Write** scope (not "Public Repo Read-only"). A missing credential or a failed API call only warns — it never fails the build, since the image push already succeeded by that point.
  - **`description`/`full_description` are confirmed working**: `PATCH https://hub.docker.com/v2/repositories/{namespace}/{repo}` with a Bearer token from `POST /v2/auth/token` — verified against the actual source of the widely-used `peter-evans/dockerhub-description` GitHub Action.
  - **`categories` is unconfirmed and sent as a separate, isolated PATCH call** so it can't jeopardize the description update if rejected. It's absent from the official Hub API spec (`docs.docker.com/reference/api/hub` only exposes `GET`/`HEAD` on a repository — no documented update endpoint at all for any field) and from `peter-evans/dockerhub-description`. Other automation has sent `categories` speculatively on this same classic endpoint but never confirmed the server actually persists it rather than silently dropping it — treat it the same way here: best-effort, verify in the Docker Hub UI after a real run, and set it manually there if it didn't take. Valid slugs come from `GET https://hub.docker.com/v2/categories/` (undocumented but public) and are hardcoded in `$script:DockerHubCategorySlugs`; an unknown slug in `hub-metadata.yml` is warned about and dropped, not a hard failure. There is no blockchain/crypto category, so monero/verus don't set one.

## Naming history

Publish scripts were originally named `install*.ps1`; they were renamed to `build*.ps1` to reflect what they actually do (build + publish, not install) and to avoid confusion with `install-common.ps1`-style shared helpers, which is now `build-common.ps1`.

In-container entrypoint scripts were originally named `start.sh`/`start.ps1`; they were renamed to `entrypoint.sh`/`entrypoint.ps1` to match the common convention used across the wider Docker ecosystem.

## Workflow rules

- **Never commit without explicit confirmation.** Stage/prepare changes, but only run `git commit` (or push) when the user explicitly asks for it in that turn — a prior approval doesn't carry forward to later changes.
- **Keep [CATALOG.md](../CATALOG.md) in sync with the containers actually defined in the repo.** Whenever a container directory is added, removed, or renamed, check the catalog for a matching entry (both the alphabetical table and its category section) and flag/fix any mismatch rather than leaving the index stale.
