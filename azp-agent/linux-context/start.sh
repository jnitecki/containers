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
# Running it with the --once flag at the end will shut down the agent after the build is executed

./run.sh --once & wait $!
