#!/bin/bash
source logger.bash

RUNNER_ASSETS_DIR=${RUNNER_ASSETS_DIR:-/runnertmp}
RUNNER_HOME=${RUNNER_HOME:-/runner}

if [ ! -z "${STARTUP_DELAY_IN_SECONDS}" ]; then
  log.notice "Delaying startup by ${STARTUP_DELAY_IN_SECONDS} seconds"
  sleep ${STARTUP_DELAY_IN_SECONDS}
fi

if [[ "${DISABLE_WAIT_FOR_DOCKER}" != "true" ]] && [[ "${DOCKER_ENABLED}" == "true" ]]; then
    log.debug 'Docker enabled runner detected and Docker daemon wait is enabled'
    log.debug 'Waiting until Docker is available or the timeout is reached'
    timeout 120s bash -c 'until docker ps ;do sleep 1; done'
else
  log.notice 'Docker wait check skipped. Either Docker is disabled or the wait is disabled, continuing with entrypoint'
fi

if [ -z "${GITHUB_URL}" ]; then
  log.debug 'Working with public GitHub'
  GITHUB_URL="https://github.com/"
else
  length=${#GITHUB_URL}
  last_char=${GITHUB_URL:length-1:1}

  [[ $last_char != "/" ]] && GITHUB_URL="$GITHUB_URL/"; :
  log.debug "Github endpoint URL ${GITHUB_URL}"
fi

if [ -z "${RUNNER_NAME}" ]; then
  log.error 'RUNNER_NAME must be set'
  exit 1
fi

if [ -n "${RUNNER_ORG}" ] && [ -n "${RUNNER_REPO}" ] && [ -n "${RUNNER_ENTERPRISE}" ]; then
  ATTACH="${RUNNER_ORG}/${RUNNER_REPO}"
elif [ -n "${RUNNER_ORG}" ]; then
  ATTACH="${RUNNER_ORG}"
elif [ -n "${RUNNER_REPO}" ]; then
  ATTACH="${RUNNER_REPO}"
elif [ -n "${RUNNER_ENTERPRISE}" ]; then
  ATTACH="enterprises/${RUNNER_ENTERPRISE}"
else
  log.error 'At least one of RUNNER_ORG, RUNNER_REPO, or RUNNER_ENTERPRISE must be set'
  exit 1
fi

if [ -z "${RUNNER_TOKEN}" ]; then
  log.error 'RUNNER_TOKEN must be set'
  exit 1
fi

if [ -z "${RUNNER_REPO}" ] && [ -n "${RUNNER_GROUP}" ];then
  RUNNER_GROUPS=${RUNNER_GROUP}
fi

# Hack due to https://github.com/actions-runner-controller/actions-runner-controller/issues/252#issuecomment-758338483
if [ ! -d "${RUNNER_HOME}" ]; then
  log.error "$RUNNER_HOME should be an emptyDir mount. Please fix the pod spec."
  exit 1
fi

# if this is not a testing environment
if [[ "${UNITTEST:-}" == '' ]]; then
  sudo chown -R runner:docker "$RUNNER_HOME"
  # enable dotglob so we can copy a ".env" file to load in env vars as part of the service startup if one is provided
  # loading a .env from the root of the service is part of the actions/runner logic
  shopt -s dotglob
  # use cp instead of mv to avoid issues when src and dst are on different devices
  cp -r "$RUNNER_ASSETS_DIR"/* "$RUNNER_HOME"/
  shopt -u dotglob
fi

cd ${RUNNER_HOME}
# past that point, it's all relative pathes from /runner

config_args=()
if [ "${RUNNER_FEATURE_FLAG_ONCE:-}" != "true" -a "${RUNNER_EPHEMERAL}" == "true" ]; then
  config_args+=(--ephemeral)
  log.debug 'Passing --ephemeral to config.sh to enable the ephemeral runner.'
fi
if [ "${DISABLE_RUNNER_UPDATE:-}" == "true" ]; then
  config_args+=(--disableupdate)
  log.debug 'Passing --disableupdate to config.sh to disable automatic runner updates.'
fi

retries_left=10
while [[ ${retries_left} -gt 0 ]]; do
  log.debug 'Configuring the runner.'
  ./config.sh --unattended --replace \
    --name "${RUNNER_NAME}" \
    --url "${GITHUB_URL}${ATTACH}" \
    --token "${RUNNER_TOKEN}" \
    --runnergroup "${RUNNER_GROUPS}" \
    --labels "${RUNNER_LABELS}" \
    --work "${RUNNER_WORKDIR}" "${config_args[@]}"

  if [ -f .runner ]; then
    log.debug 'Runner successfully configured.'
    break
  fi

  log.debug 'Configuration failed. Retrying'
  retries_left=$((retries_left - 1))
  sleep 1
done

if [ ! -f .runner ]; then
  # we couldn't configure and register the runner; no point continuing
  log.error 'Configuration failed!'
  exit 2
fi

cat .runner
# Note: the `.runner` file's content should be something like the below:
#
# $ cat /runner/.runner
# {
# "agentId": 117, #=> corresponds to the ID of the runner
# "agentName": "THE_RUNNER_POD_NAME",
# "poolId": 1,
# "poolName": "Default",
# "serverUrl": "https://pipelines.actions.githubusercontent.com/SOME_RANDOM_ID",
# "gitHubUrl": "https://github.com/USER/REPO",
# "workFolder": "/some/work/dir" #=> corresponds to Runner.Spec.WorkDir
# }
#
# Especially `agentId` is important, as other than listing all the runners in the repo,
# this is the only change we could get the exact runnner ID which can be useful for further
# GitHub API call like the below. Note that 171 is the agentId seen above.
#   curl \
#     -H "Accept: application/vnd.github.v3+json" \
#     -H "Authorization: bearer ${GITHUB_TOKEN}"
#     https://api.github.com/repos/USER/REPO/actions/runners/171

if [ -z "${UNITTEST:-}" ]; then
  mkdir -p ./externals
  # Hack due to the DinD volumes
  mv ./externalstmp/* ./externals/
fi

args=()
if [ "${RUNNER_FEATURE_FLAG_ONCE:-}" == "true" -a "${RUNNER_EPHEMERAL}" == "true" ]; then
  args+=(--once)
  log.warning 'Passing --once is deprecated and will be removed as an option' \
    'from the image and actions-runner-controller at the release of 0.25.0.' \
    'Upgrade to GHES => 3.3 to continue using actions-runner-controller. If' \
    'you are using github.com ignore this warning.'
fi

# Unset entrypoint environment variables so they don't leak into the runner environment
unset RUNNER_NAME RUNNER_REPO RUNNER_TOKEN STARTUP_DELAY_IN_SECONDS DISABLE_WAIT_FOR_DOCKER

# Docker ignores PAM and thus never loads the system environment variables that
# are meant to be set in every environment of every user. We emulate the PAM
# behavior by reading the environment variables without interpreting them.
#
# https://github.com/actions-runner-controller/actions-runner-controller/issues/1135
# https://github.com/actions/runner/issues/1703

# /etc/environment may not exist when running unit tests depending on the platform being used
# (e.g. Mac OS) so we just skip the mapping entirely
if [ -z "${UNITTEST:-}" ]; then
  mapfile -t env </etc/environment
fi
exec env -- "${env[@]}" ./run.sh "${args[@]}"
