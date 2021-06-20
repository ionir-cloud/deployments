#!/bin/bash

APP_NAME="ionir-compatibility-check"
APP_NAME_PRETTY="Ionir compatibility check"
PREFLIGHT_NAMESPACE="${APP_NAME}"
TEMPLATE_FILE="./${APP_NAME}.template.yaml"
OUTPUT_FILE="./${APP_NAME}.yaml"
IMAGES_FILE="./image-list.yaml"
PREFLIGHT_POD_LABEL="name=${APP_NAME}-operator"
PREFLIGHT_LOGS_FOLDER="./logs"
PERFLIGHT_OPERATOR_LOG_FILE_NAME="${APP_NAME}-operator.log"
PREFLIGHT_LOGS_TAR_FILE_NAME="${APP_NAME}-`date +%s`.tar.gz"

INSTALLATION_TYPE_MINIMAL="minimal"
INSTALLATION_TYPE_SCALE="scale"
NODE_COUNT_MINIMAL=3
NODE_COUNT_SCALE=5
MEDIA_SIZE_MINIMAL=256
MEDIA_SIZE_SCALE=2048


INSTALL="true"
DELETE="false"
COLLECT_LOGS="false"
DOCKER_REGISTRY="quay.io/ionir"
IONIR_TAG=""
DOCKER_REGISTRY_USER=""
DOCKER_REGISTRY_PASSWORD=""
INSTALLATION_TYPE=""

#trap collect_logs SIGINT
#trap collect_logs SIGTERM


usage() {
    echo "Usage: ${0} [options]"
    echo "Options:"
    echo "-i                     install ${APP_NAME_PRETTY} under $PREFLIGHT_NAMESPACE namespace (via currently configured kubeconfig)"
    echo "-d                     delete $PREFLIGHT_NAMESPACE namespace and all of its components (via currently configured kubeconfig)"
    echo "-l                     Collect ${APP_NAME_PRETTY} logs and generate a tarball (via currently configured kubeconfig)"
    echo "-r <registry>          image registry to pull images from (optional, default: quay.io/ionir)"
    echo "-u <user>              image registry username"
    echo "-p <password>          image registry password / token"
    echo "-s <installation type> Ionir's installation type, may be either '$INSTALLATION_TYPE_MINIMAL', for up to 4 nodes or '$INSTALLATION_TYPE_SCALE', for a larger cluster"
    echo "-t <tag>               Ionir release tag (optional)"
    echo
    echo "Examples:"
    echo "  1. Install ${APP_NAME_PRETTY} with user 'ionir+test' and password 'test' using public internet and '$INSTALLATION_TYPE_MINIMAL' installation"
    echo "     $0 -i -u ionir+test -p test -s $INSTALLATION_TYPE_MINIMAL"
    echo
    echo "  2. Install ${APP_NAME_PRETTY} with user 'ionir+test' and password 'test' using '172.17.1.1' as image registry and '$INSTALLATION_TYPE_SCALE' installation:"
    echo "     $0 -i -r 172.17.1.1 -u ionir+test -p test -s $INSTALLATION_TYPE_SCALE"
    echo
    echo "  3. Delete ${APP_NAME_PRETTY} installation from cluster"
    echo "     $0 -d"
    echo
    echo "  4. Collect ${APP_NAME_PRETTY} logs from cluster"
    echo "     $0 -l"
    exit 1
}

delete_preflight() {
    echo "Removing ${PREFLIGHT_NAMESPACE} resources"
    kubectl delete namespaces ${PREFLIGHT_NAMESPACE} 2> /dev/null
    kubectl delete clusterrolebindings.rbac.authorization.k8s.io ${PREFLIGHT_NAMESPACE}
    kubectl delete clusterrole ${PREFLIGHT_NAMESPACE}
    kubectl delete podsecuritypolicies.policy ${PREFLIGHT_NAMESPACE}.psp.privileged
    return 0
}

check_params() {
  if [[ "$IONIR_TAG" == ""  ]] || [[ "$IONIR_TAG" == ""  ]] || [[ "$DOCKER_REGISTRY_USER" == "" ]] || [[ "$DOCKER_REGISTRY_PASSWORD" == "" ]] \
    || ([[ ! "$INSTALLATION_TYPE" == "$INSTALLATION_TYPE_MINIMAL" ]] && [[ ! "$INSTALLATION_TYPE" == "$INSTALLATION_TYPE_SCALE" ]]); then
    echo "invalid syntax:"
    echo "IONIR_TAG: $IONIR_TAG"
    echo "REGISTRY=$DOCKER_REGISTRY"
    echo "REGISTRY_USER: $DOCKER_REGISTRY_USER"
    echo "REGISTRY_PASSWORD: $DOCKER_REGISTRY_PASSWORD"
    echo "INSTALLATION_TYPE: $INSTALLATION_TYPE"
    echo
    usage
    return 1
  fi
  return 0
}

create_namespace() {
  # Create ionir-preflight namespace
  echo "Creating $PREFLIGHT_NAMESPACE namespace"
  kubectl create namespace $PREFLIGHT_NAMESPACE
}

create_secret() {
  echo "Creating a secret from the provided credentials"
  kubectl -n $PREFLIGHT_NAMESPACE create secret docker-registry ${APP_NAME}-k8s-pull-secret \
  --docker-server="${DOCKER_REGISTRY}" \
  --docker-username="${DOCKER_REGISTRY_USER}" \
  --docker-password="${DOCKER_REGISTRY_PASSWORD}"
}

template_replace() {
  sed -e "
    s!<IONIR_TAG>!${IONIR_TAG}!g;
    s!<DOCKER_REGISTRY>!${DOCKER_REGISTRY}!g;
  " | \
  if [ "$INSTALLATION_TYPE" == "$INSTALLATION_TYPE_MINIMAL" ]; then
    sed -e "
      s!NVME_MEDIA_MIN_SIZE_GB:.*!NVME_MEDIA_MIN_SIZE_GB: \"${MEDIA_SIZE_MINIMAL}\"!g;
      s!NODE_MIN_COUNT:.*!NODE_MIN_COUNT: \"${NODE_COUNT_MINIMAL}\"!g;
    "
  else
    sed -e "
      s!NVME_MEDIA_MIN_SIZE_GB:.*!NVME_MEDIA_MIN_SIZE_GB: \"${MEDIA_SIZE_SCALE}\"!g;
      s!NODE_MIN_COUNT:.*!NODE_MIN_COUNT: \"${NODE_COUNT_SCALE}\"!g;
    "
  fi
}

generate_yaml_from_template() {
  echo "Creating $OUTPUT_FILE"
  template_replace < $TEMPLATE_FILE \
      > $OUTPUT_FILE
}

apply_images_config_map() {
  [[ -f "$IMAGES_FILE" ]] && kubectl -n $PREFLIGHT_NAMESPACE apply -f $IMAGES_FILE
}

apply_yaml() {
  echo "Applying $OUTPUT_FILE"
  kubectl -n $PREFLIGHT_NAMESPACE apply -f $OUTPUT_FILE
}

wait_for_pod_with_label() {
  # Accepts label of a pod in the form of KEY=LABEL
  pod_label="$1"
  pod_name="$(echo $pod_label | cut -d = -f2 )"

  echo "Waiting for $pod_name to start"
  kubectl -n $PREFLIGHT_NAMESPACE wait --for=condition=ready pod -l $pod_label --timeout=300s
}

show_pod_logs_continues() {
  pod_name="$1"
  kubectl -n $PREFLIGHT_NAMESPACE logs -f $pod_name
}

show_pod_logs() {
  pod_name="$1"
  kubectl -n $PREFLIGHT_NAMESPACE logs $pod_name
}

get_pod_name_by_label() {
  pod_label="$1"
  pod_name=`kubectl -n $PREFLIGHT_NAMESPACE get pod -l $pod_label -o=jsonpath='{.items[*].metadata.name}'`
  echo $pod_name
}

install_preflight() {
  create_namespace
  create_secret
  generate_yaml_from_template
  apply_images_config_map
  apply_yaml
  wait_for_pod_with_label "$PREFLIGHT_POD_LABEL"
  pod_name=`get_pod_name_by_label "$PREFLIGHT_POD_LABEL"`
  show_pod_logs_continues "$pod_name"
}

collect_logs() {
  echo -e "\nCollecting logs"
  mkdir -p $PREFLIGHT_LOGS_FOLDER
  pod_name=`get_pod_name_by_label "$PREFLIGHT_POD_LABEL"`
  show_pod_logs "$pod_name" > "${PREFLIGHT_LOGS_FOLDER}/${PERFLIGHT_OPERATOR_LOG_FILE_NAME}"
  kubectl -n $PREFLIGHT_NAMESPACE cp ${pod_name}:/opt/reduxio/logs ${PREFLIGHT_LOGS_FOLDER} > /dev/null 2>&1
  if [[ $? -eq 0 ]]; then
      tar -zcvf ${PREFLIGHT_LOGS_TAR_FILE_NAME} ${PREFLIGHT_LOGS_FOLDER} > /dev/null 2>&1
      rm -rf ${PREFLIGHT_LOGS_FOLDER}
      echo "Logs can be found at ${PREFLIGHT_LOGS_TAR_FILE_NAME}"
      echo "To untar the logs tarball use:"
      echo -e "\ttar xvzf ${PREFLIGHT_LOGS_TAR_FILE_NAME}"
      echo -e "To view a log file use:"
      echo -e "\tless -Sr <log file name>"
  else
      echo -e "\nERROR: Logs collection failed. Please contact Ionir support"
      exit $?
  fi
}

run(){

  [[ "$DELETE" == "true" ]] && delete_preflight && exit 0
  [[ "$COLLECT_LOGS" == "true" ]] && collect_logs && exit 0
  [[ "$INSTALL" == "true" ]] && check_params && delete_preflight && install_preflight

}

while getopts "u:p:r:t:s:idl" opt; do
    case ${opt} in
        i|I)
            INSTALL="true"
            ;;
        d|D)
            DELETE="true"
            ;;
        l|L)
            COLLECT_LOGS="true"
            ;;
        u|U)
            DOCKER_REGISTRY_USER=$OPTARG
            ;;
        p|P)
            DOCKER_REGISTRY_PASSWORD=$OPTARG
            ;;
        r|R)
            DOCKER_REGISTRY=$OPTARG
            ;;
        t|T)
            IONIR_TAG=$OPTARG
            ;;
        s|S)
            INSTALLATION_TYPE=$OPTARG
            ;;
        *)
            echo Unknown opt "${opt}"
            usage
            exit 1
            ;;
    esac
done

run

