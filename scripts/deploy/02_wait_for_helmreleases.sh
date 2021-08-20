#!/usr/bin/env bash

set -e

## Array of core HRs
CORE_HELMRELEASES=("gatekeeper" "istio-operator" "istio" "monitoring" "eck-operator" "ek" "fluent-bit" "twistlock" "cluster-auditor" "jaeger" "kiali")

## Array of addon HRs
ADD_ON_HELMRELEASES=("argocd" "authservice" "haproxy-sso" "gitlab" "gitlab-runner" "anchore" "sonarqube" "minio-operator" "minio" "mattermost-operator" "mattermost" "nexus-repository-manager" "velero")

## Map of values-keys/labels to HRs: Only needed if HR name =/= label name
declare -A ADD_ON_HELMRELEASES_MAP
ADD_ON_HELMRELEASES_MAP["haproxy"]="haproxy-sso"
ADD_ON_HELMRELEASES_MAP["gitlabRunner"]="gitlab-runner"
ADD_ON_HELMRELEASES_MAP["minioOperator"]="minio-operator"
ADD_ON_HELMRELEASES_MAP["mattermostoperator"]="mattermost-operator"
ADD_ON_HELMRELEASES_MAP["nexus"]="nexus-repository-manager"

## Function to test an array contains an element
## Args:
## $1: array to search
## $2: element to search for
function array_contains() {
    local array="$1[@]"
    local seeking=$2
    local in=1
    for element in ${!array}; do
        if [[ $element == "$seeking" ]]; then
            in=0
            break
        fi
    done
    return $in
}

## Function to check/wait on HR existence
function check_if_exist() {
    timeElapsed=0
    echo "Waiting for $1 HR to exist"
    until kubectl get hr -n bigbang $1 &> /dev/null; do
      sleep 5
      timeElapsed=$(($timeElapsed+5))
      if [[ $timeElapsed -ge 60 ]]; then
         echo "Timed out while waiting for $1 HR to exist"
         exit 1
      fi
    done
}

## Function to wait on all HRs
function wait_all_hr() {
    timeElapsed=0
    while true; do
        if [[ "$(kubectl get hr -A -o jsonpath='{.items[*].status.conditions[0].reason}')" =~ Failed ]]; then
            echo "Found a failed Helm Release. Exiting now."
            exit 1
        fi
        if [[ "$(kubectl get hr -A -o jsonpath='{.items[*].status.conditions[0].reason}')" != *DependencyNotReady* ]]; then
            if [[ "$(kubectl get hr -A -o jsonpath='{.items[*].status.conditions[0].reason}')" != *Failed* ]]; then
                echo "All HR's deployed"
                break
            fi
        fi
        sleep 5
        timeElapsed=$(($timeElapsed+5))
        if [[ $timeElapsed -ge 1800 ]]; then
            echo "Timed out while waiting for hr's to be ready."
            exit 1
        fi
    done
}

## Function to wait on all statefulsets
function wait_sts() {
   timeElapsed=0
   while true; do
      sts=$(kubectl get sts -A -o jsonpath='{.items[*].status.replicas}' | xargs)
      totalSum=$(echo $sts | awk '{for (i=1; i<=NF; i++) c+=$i} {print c}')
      readySts=$(kubectl get sts -A -o jsonpath='{.items[*].status.readyReplicas}' | xargs)
      readySum=$(echo $readySts | awk '{for (i=1; i<=NF; i++) c+=$i} {print c}')
      if [[ $totalSum -eq $readySum ]]; then
         break
      fi
      sleep 5
      timeElapsed=$(($timeElapsed+5))
      if [[ $timeElapsed -ge 600 ]]; then
         echo "Timed out while waiting for stateful sets to be ready."
         exit 1
      fi
   done
}

## Function to wait on all daemonsets
function wait_daemonset(){
   timeElapsed=0
   while true; do
      dmnset=$(kubectl get daemonset -A -o jsonpath='{.items[*].status.desiredNumberScheduled}' | xargs)
      totalSum=$(echo $dmnset | awk '{for (i=1; i<=NF; i++) c+=$i} {print c}')
      readyDmnset=$(kubectl get daemonset -A -o jsonpath='{.items[*].status.numberReady}' | xargs)
      readySum=$(echo $readyDmnset | awk '{for (i=1; i<=NF; i++) c+=$i} {print c}')
      if [[ $totalSum -eq $readySum ]]; then
         break
      fi
      sleep 5
      timeElapsed=$(($timeElapsed+5))
      if [[ $timeElapsed -ge 600 ]]; then
         echo "Timed out while waiting for daemon sets to be ready."
         exit 1
      fi
   done
}

## Append all add-ons to hr list if "all-packages" or default branch/tag. Else, add specific ci labels to hr list.
HELMRELEASES=(${CORE_HELMRELEASES[@]})
if [[ "${CI_COMMIT_BRANCH}" == "${CI_DEFAULT_BRANCH}" ]] || [[ ! -z "$CI_COMMIT_TAG" ]] || [[ $CI_MERGE_REQUEST_LABELS =~ "all-packages" ]]; then
    HELMRELEASES+=(${ADD_ON_HELMRELEASES[@]})
    echo "All helmreleases enabled: all-packages label enabled, or on default branch or tag."
elif [[ ! -z "$CI_MERGE_REQUEST_LABELS" ]]; then
    IFS=","
    for package in $CI_MERGE_REQUEST_LABELS; do
        # Check if package is in addons
        if array_contains ADD_ON_HELMRELEASES "$package"; then
            HELMRELEASES+=("$package")
        # Check to see if there is a mapping from label -> HR
        elif [ ${ADD_ON_HELMRELEASES_MAP[$package]+_} ]; then
            package="${ADD_ON_HELMRELEASES_MAP[$package]}"
            # Safeguard to doublecheck new package name is valid HR name
            if array_contains ADD_ON_HELMRELEASES "$package"; then
                HELMRELEASES+=("$package")
            fi
        fi
    done
    echo "Found enabled helmreleases: ${HELMRELEASES[@]}"
fi

for package in "${HELMRELEASES[@]}";
do
    check_if_exist "$package"
done

echo "Waiting on helm releases..."
wait_all_hr

# TODO: Collapse this output by default with https://docs.gitlab.com/ee/ci/jobs/#custom-collapsible-sections
kubectl get helmreleases,kustomizations,gitrepositories -A

# TODO: Is this needed? Should it be before HRs?
echo "Waiting on Secrets Kustomization"
kubectl wait --for=condition=Ready --timeout 300s kustomizations.kustomize.toolkit.fluxcd.io -n bigbang secrets

# In case some helm releases are marked as ready before all objects are live...
echo "Waiting on all jobs, deployments, statefulsets, and daemonsets"
kubectl wait --for=condition=available --timeout 600s -A deployment --all > /dev/null
wait_sts
wait_daemonset
if kubectl get job -A -o jsonpath='{.items[].metadata.name}' &> /dev/null; then
  kubectl wait --for=condition=complete --timeout 300s -A job --all > /dev/null
fi
