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

# Nested Podman only works reliably in a --privileged container, so keep PODMAN (path to podman,
# set in the dockerfile) only if it is installed and every privileged-mode check below passes.
podman_not_privileged() {
  # Capability bounding set must hold every capability the kernel knows. CapEff is no use here:
  # it is 0 for a non-root user whether or not the container is privileged.
  local cap_last cap_bnd
  cap_last="$(cat /proc/sys/kernel/cap_last_cap 2> /dev/null)" || cap_last=40
  cap_bnd="$(awk '/^CapBnd:/ {print $2}' /proc/self/status)"
  if [ -z "$cap_bnd" ] || (( (16#$cap_bnd & ((1 << (cap_last + 1)) - 1)) != (1 << (cap_last + 1)) - 1 )); then
    echo "capability bounding set is restricted (CapBnd: ${cap_bnd:-unknown})"
    return 0
  fi

  # --privileged disables seccomp (0 = none, 2 = filtered) and AppArmor/SELinux confinement.
  local seccomp lsm_label
  seccomp="$(awk '/^Seccomp:/ {print $2}' /proc/self/status)"
  if [ -n "$seccomp" ] && [ "$seccomp" != "0" ]; then
    echo "seccomp filtering is active (Seccomp: $seccomp)"
    return 0
  fi
  lsm_label="$(tr -d '\0' < /proc/self/attr/current 2> /dev/null)" || lsm_label=""
  case "$lsm_label" in
    *"(enforce)"*|*"(complain)"*|*":container_t:"*)
      echo "process is confined by a security profile ($lsm_label)"
      return 0
      ;;
  esac

  # /proc/sys and /sys are mounted read-only in an unprivileged container.
  local ro_mounts
  ro_mounts="$(awk '($2 == "/proc/sys" || $2 == "/sys") && $4 ~ /(^|,)ro(,|$)/ {print $2}' /proc/mounts | tr '\n' ' ')"
  if [ -n "$ro_mounts" ]; then
    echo "read-only system mounts: ${ro_mounts% }"
    return 0
  fi

  # A privileged container sees all host devices (dozens+); an unprivileged one only ~15.
  local dev_count
  dev_count="$(ls /dev | wc -l)"
  if (( dev_count < 30 )); then
    echo "only $dev_count entries in /dev (host devices are not exposed)"
    return 0
  fi

  return 1
}
if [ -n "$PODMAN" ] && [ ! -x "$PODMAN" ]; then
  unset PODMAN
elif [ -n "$PODMAN" ]; then
  if podman_reason="$(podman_not_privileged)"; then
    echo 1>&2 "warning: container is not running --privileged ($podman_reason); nested Podman will not work, PODMAN capability not reported"
    unset PODMAN
  fi
  unset podman_reason
fi
unset -f podman_not_privileged
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
