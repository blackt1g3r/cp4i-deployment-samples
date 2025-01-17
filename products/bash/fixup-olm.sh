#!/bin/bash

OLM_NS="openshift-operator-lifecycle-manager"
CATALOG_OPERATOR_LABEL="app=catalog-operator"
OLM_OPERATOR_LABEL="app=olm-operator"
CP4I_NAMESPACE="cp4i"
CS_NAMESPACE="ibm-common-services"
DRY_RUN=false

# Subscriptions/CSVs will only be deleted if older than the following threshold.
# This gives OLM a chance to install and resolve any problems itself.
AGE_THRESHOLD_SECS=60

while getopts "dn:" opt; do
  case ${opt} in
  d)
    DRY_RUN=true
    ;;
  n)
    CP4I_NAMESPACE="$OPTARG"
    ;;
  esac
done


echo "Checking OLM..."
CATALOG_RESTART_COUNT=$(oc get pod -n $OLM_NS -l $CATALOG_OPERATOR_LABEL -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
# Check if the catalog pod has restarted
# Delete the OLM pods if so
if [ "$CATALOG_RESTART_COUNT" -gt "0" ]; then
  if [[ "${DRY_RUN}" == "false" ]]; then
    echo "Catalog operator has restarted, restarting OLM pods..."
    oc delete pod -n ${OLM_NS} -l ${CATALOG_OPERATOR_LABEL}
    oc delete pod -n ${OLM_NS} -l ${OLM_OPERATOR_LABEL}
    oc wait --for condition=ready --timeout=120s pod -n ${OLM_NS} -l ${CATALOG_OPERATOR_LABEL}
    oc wait --for condition=ready --timeout=120s pod -n ${OLM_NS} -l ${OLM_OPERATOR_LABEL}
  else
    echo "Catalog operator has restarted, the catalog/OLM pods need to be restarted..."
  fi
fi



echo "Checking operator subscriptions..."
# Get a list of all subscriptions that have the ResolutionFailed condition and don't have a status.state
rows=$(oc get subscription --all-namespaces -o json | jq -r '.items[] | select(.status.conditions[].type == "ResolutionFailed") | select(.status.state == null) | {namespace:.metadata.namespace, name:.metadata.name, currentCSV:.status.currentCSV} | @base64')
for row in ${rows}; do
  _jq() {
   echo ${row} | base64 --decode | jq -r ${1}
  }

  # Check if the namespace is for 1-click or CS
  subscription_namespace="$(_jq '.namespace')"
  subscription_name="$(_jq '.name')"
  if [[ "$subscription_namespace" == "$CP4I_NAMESPACE" ]] || [[ "$subscription_namespace" == "$CS_NAMESPACE" ]]; then
    # Check the creation time against the current time and only delete if it's had > 1 minute
    CREATION_TIMESTAMP=$(oc get subscription -n ${subscription_namespace} ${subscription_name} -o json | jq -r .metadata.creationTimestamp)
    CURRENT_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ "$OSTYPE" == "darwin"* ]]; then
      CREATION_TIMESTAMP_SECS=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "${CREATION_TIMESTAMP}" +%s)
      CURRENT_TIMESTAMP_SECS=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "${CURRENT_TIMESTAMP}" +%s)
    else
      CREATION_TIMESTAMP_SECS=$(date -d"${CREATION_TIMESTAMP}" +%s)
      CURRENT_TIMESTAMP_SECS=$(date -d"${CURRENT_TIMESTAMP}" +%s)
    fi

    AGE="$(($CURRENT_TIMESTAMP_SECS-$CREATION_TIMESTAMP_SECS))"
    if [ "$AGE" -ge "$AGE_THRESHOLD_SECS" ]; then
      # Auto delete the csv/subscription
      current_csv=$(_jq '.status.currentCSV')
      if [[ ! -z "${current_csv}" ]] && [[ "${current_csv}" != "null" ]] ; then
        if [[ "${DRY_RUN}" == "false" ]]; then
          oc delete csv -n ${subscription_namespace} ${current_csv}
        else
          echo "The csv named [${current_csv}] in the [${subscription_namespace}] namespace needs to be deleted."
        fi
      fi

      if [[ "${DRY_RUN}" == "false" ]]; then
        SUBSCRIPTION_JSON="$(oc get subscription -n ${subscription_namespace} ${subscription_name} -o json | jq 'del(.status) | del(.metadata.managedFields) | del(.metadata.creationTimestamp) | del(.metadata.uid) | del(.metadata.resourceVersion)')"
        oc delete subscription -n ${subscription_namespace} ${subscription_name}

        sleep 5

        cat <<EOF | oc apply -f -
  ${SUBSCRIPTION_JSON}
EOF
      else
        echo "The subscription named [${subscription_name}] in the [${subscription_namespace}] namespace needs to be deleted and recreated."
      fi
    fi
  else
    echo "The operator named [${subscription_name}] in the [${subscription_namespace}] namespace needs to be deleted and re-installed."
  fi
done

NAMESPACES="$CP4I_NAMESPACE $CS_NAMESPACE"
echo "Checking for orphaned CSVs in the following namespaces: [$NAMESPACES]"
for NAMESPACE in ${NAMESPACES}; do
  SUBSCRIPTION_CSVS=$(oc get subscriptions -n $NAMESPACE -o json | jq -r ".items[].status.currentCSV | select(. != null)")
  CSVS=$(oc get csv -n $NAMESPACE -o json | jq -r ".items[].metadata.name")
  for CSV in ${CSVS}; do
    echo $SUBSCRIPTION_CSVS | grep -w -q $CSV
    if [[ $? != 0 ]]; then
      if [[ "${DRY_RUN}" == "false" ]]; then
        oc delete csv -n $NAMESPACE $CSV
      else
        echo "The CSV named [$CSV] needs to be deleted from the [$NAMESPACE] namespace."
      fi
    fi
  done
done
