#!/bin/bash
set -e

# Drop inherited variables with no value (e.g. from a disabled optional toolchain's
# conditional ENV in the dockerfile) so they don't show up in the agent's environment block.
for env_var in $(compgen -e); do
  [ -z "${!env_var}" ] && unset "$env_var"
done

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  if [ -z "$AZP_TOKEN" ]; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable"
    exit 1
  fi

  AZP_TOKEN_FILE=/azp/.token
  echo -n $AZP_TOKEN > "$AZP_TOKEN_FILE"
fi

unset AZP_TOKEN

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

# AZP_RUN_ONCE (default true): run a single job, then exit (and deregister); false keeps the agent running.
case "${AZP_RUN_ONCE:-true}" in
  [Tt][Rr][Uu][Ee]|1|[Yy][Ee][Ss]) run_args=(--once) ;;
  [Ff][Aa][Ll][Ss][Ee]|0|[Nn][Oo]) run_args=() ;;
  *)
    echo 1>&2 "error: invalid AZP_RUN_ONCE value '$AZP_RUN_ONCE' (expected true or false)"
    exit 1
    ;;
esac

export AGENT_ALLOW_RUNASROOT="1"

# Some build tools (e.g. Gradle toolchains) auto-detect JDKs via JAVA_HOME_<version>_<arch>;
# derive both from the versioned/arch-suffixed real path behind the JAVA_HOME symlink.
if [ -n "$JAVA_HOME" ]; then
  java_real_home="$(readlink -f "$JAVA_HOME")"
  if [[ "$(basename "$java_real_home")" =~ ^java-([0-9]+)-openjdk-(amd64|arm64)$ ]]; then
    java_version="${BASH_REMATCH[1]}"
    java_arch="$(echo "${BASH_REMATCH[2]/amd64/x64}" | tr '[:lower:]' '[:upper:]')"
    export "JAVA_HOME_${java_version}_${java_arch}=$JAVA_HOME"
  fi
fi

# Expose the native toolchain as agent capabilities (usable in pipeline demands). Derived at
# startup because the versions come from the installed apt packages, not a pinned build arg.
if gcc_path="$(command -v gcc)"; then
  export GCC="$(gcc -dumpfullversion)"
  export "GCC_${GCC%%.*}=$gcc_path"
fi
if command -v python3-config > /dev/null; then
  export PYTHON_DEV="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
fi

# Keep PODMAN (path to podman, set in the dockerfile) only if nested Podman actually works here.
# Heuristics about --privileged are not enough: they miss e.g. image storage stacked on the
# outer container's overlay (fuse-overlayfs on fuse-overlayfs cannot create directories), and
# can reject a working setup. So run a real container instead, exercising what builds rely on:
# importing an image into storage, crun creating a new bind-mount target, and a mkdir inside
# the container's root filesystem. The image is built from this container's own sh/mkdir/cat
# (plus their libraries), so no registry or network access is needed.
# --cgroups=disabled: nested cgroup delegation is commonly unavailable; CI scripts pass this
# flag unconditionally, so the probe tests the same mode they use.
# Prints the reason and returns 0 when Podman is NOT usable.
podman_unusable() {
  local probe_dir probe_image out rc=0 files
  probe_image="localhost/agent-podman-probe:$$"
  probe_dir="$(mktemp -d)" || { echo "cannot create temp dir"; return 0; }
  mkdir -p "$probe_dir/mnt"
  echo ok > "$probe_dir/mnt/ok"

  files="$( { printf '%s\n' /bin/sh /bin/mkdir /bin/cat; ldd /bin/sh /bin/mkdir /bin/cat 2> /dev/null | grep -o '/[^ ]*'; } \
    | sort -u | sed 's|^/||')"
  # -h stores symlink targets as regular files (e.g. /bin -> usr/bin on merged-/usr systems).
  # shellcheck disable=SC2086
  out="$(tar -C / -chf - $files 2> /dev/null | timeout 120 "$PODMAN" import - "$probe_image" 2>&1)" || rc=$?
  if [ "$rc" -eq 0 ]; then
    out="$(timeout 120 "$PODMAN" run --rm --pull=never --cgroups=disabled --network=none \
      -v "$probe_dir/mnt:/probe:ro" "$probe_image" \
      /bin/sh -c '/bin/mkdir /probe-mkdir && /bin/cat /probe/ok' 2>&1)" || rc=$?
  fi
  "$PODMAN" rmi -f "$probe_image" > /dev/null 2>&1 || true
  rm -rf "$probe_dir"

  if [ "$rc" -eq 0 ] && [ "$out" = "ok" ]; then
    return 1
  fi

  echo "probe container failed (rc=$rc): $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
  # Most common cause besides a missing --privileged: image storage on the container's own
  # overlay root instead of a volume.
  local graph_root graph_fs
  graph_root="$("$PODMAN" info --format '{{.Store.GraphRoot}}' 2> /dev/null)" || graph_root=""
  if [ -n "$graph_root" ]; then
    graph_fs="$(stat -fc %T "$graph_root" 2> /dev/null)" || graph_fs=""
    case "$graph_fs" in
      overlayfs|fuseblk|fuse*)
        echo "; image storage $graph_root is on $graph_fs — mount a volume at /var/lib/containers"
        ;;
    esac
  fi
  return 0
}
if [ -n "$PODMAN" ] && [ ! -x "$PODMAN" ]; then
  unset PODMAN
elif [ -n "$PODMAN" ]; then
  if podman_reason="$(podman_unusable)"; then
    echo 1>&2 "warning: nested Podman does not work in this container ($podman_reason); PODMAN capability not reported"
    unset PODMAN
  fi
  unset podman_reason
fi
unset -f podman_unusable

# The emulator is only usable with hardware acceleration (e.g. /dev/kvm passed into the
# container), so report it only when -accel-check succeeds, plus one ANDROID_EMULATOR_<api>
# per installed system image.
android_emulator="$ANDROID_HOME/emulator/emulator"
if [ -n "$ANDROID_HOME" ] && [ -x "$android_emulator" ] && "$android_emulator" -accel-check > /dev/null 2>&1; then
  export ANDROID_EMULATOR="$android_emulator"
  for system_image_dir in "$ANDROID_HOME"/system-images/android-*; do
    if [[ "$(basename "$system_image_dir")" =~ ^android-([0-9]+)$ ]]; then
      export "ANDROID_EMULATOR_${BASH_REMATCH[1]}=$android_emulator"
    fi
  done
fi
unset android_emulator

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
      ./config.sh remove --unattended --auth PAT --token $(cat "$AZP_TOKEN_FILE") && break

      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

source ./env.sh

print_header "1. Configuring Azure Pipelines agent..."

./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth PAT \
  --token $(cat "$AZP_TOKEN_FILE") \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula & wait $!

print_header "2. Running Azure Pipelines agent..."

trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# To be aware of TERM and INT signals call run.sh
# Running it with the --once flag (AZP_RUN_ONCE) will shut down the agent after the build is executed

./run.sh "${run_args[@]}" & wait $!
