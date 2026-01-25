#!/usr/bin/env bash

# A utility script to run a kubectl pod with one or more PVCs mounted.
# Original: https://gist.github.com/yuanying/3aa7d59dcce65470804ab43def646ab6
# Modified to add help message, -n and -x options, and other improvements.

IMAGE="gcr.io/google-containers/ubuntu-slim:0.14"
COMMAND="/bin/bash"
NAMESPACE=""
CONTEXT=""
SUFFIX=$(date +%s | shasum | base64 | fold -w 10 | head -1 | tr '[:upper:]' '[:lower:]')

usage_exit() {
    cat <<EOF
kubectl-run-with-pvc - Run a temporary pod with PersistentVolumeClaims mounted

USAGE:
    $0 [-c command] [-i image] [-n namespace] [-x context] [-h] PVC [PVC ...]

DESCRIPTION:
    Creates an ephemeral Kubernetes pod that mounts one or more PersistentVolumeClaims (PVCs).
    Each PVC is mounted at /pvcs/<claimName>. The pod is automatically removed when you exit.
    
    Useful for inspecting, debugging, or manipulating data in PVCs without having to deploy
    a persistent pod or job.

OPTIONS:
    -i IMAGE
        Container image to use in the pod.
        Default: gcr.io/google-containers/ubuntu-slim:0.14

    -c COMMAND
        Command to execute in the container.
        Default: /bin/bash

    -n NAMESPACE
        Kubernetes namespace where the pod will be created.
        Default: current namespace (from kubectl config)

    -x CONTEXT
        kubectl context to use for this operation.
        Default: current context (from kubectl config)

    -h
        Display this help message and exit.

EXAMPLES:
    # Mount a single PVC and get an interactive shell
    $0 my-pvc

    # Mount multiple PVCs
    $0 data-pvc logs-pvc config-pvc

    # Use a specific namespace
    $0 -n my-namespace my-pvc

    # Use a different context and namespace
    $0 -x prod-cluster -n production my-pvc

    # Use Alpine Linux instead of Ubuntu
    $0 -i alpine:latest -c sh my-pvc

    # Run a command non-interactively
    $0 -c "ls -lh /pvcs/my-pvc" my-pvc

MOUNT PATHS:
    Each PVC is mounted to: /pvcs/<claimName>
    
    Example: If you mount 'database-pvc', it will be at /pvcs/database-pvc

NOTES:
    - Pod name is auto-generated: pvc-mounter-<random-suffix>
    - Pod is removed when you exit (--rm flag)
    - Uses hostNetwork: true for networking access
    - Requires kubectl configured and permissions to create pods

PREREQUISITES:
    - kubectl installed and configured
    - PVCs must already exist in the target namespace
    - User must have permission to create pods in the target namespace

EOF
    exit 1
}

while getopts i:c:n:x:h OPT
do
    case $OPT in
        i)  IMAGE=$OPTARG
            ;;
        c)  COMMAND=$OPTARG
            ;;
        n)  NAMESPACE=$OPTARG
            ;;
        x)  CONTEXT=$OPTARG
            ;;
        h)  usage_exit
            ;;
        \?) usage_exit
            ;;
    esac
done
shift $(($OPTIND - 1))

# Require at least one PVC
if [ $# -eq 0 ]; then
    echo "Error: At least one PVC name is required" 1>&2
    usage_exit
fi

VOL_MOUNTS=""
VOLS=""
COMMA=""

for i in $@
do
  VOL_MOUNTS="${VOL_MOUNTS}${COMMA}{\"name\": \"${i}\",\"mountPath\": \"/pvcs/${i}\"}"
  VOLS="${VOLS}${COMMA}{\"name\": \"${i}\",\"persistentVolumeClaim\": {\"claimName\": \"${i}\"}}"
  COMMA=","
done

KUBECTL_CMD="kubectl"
[ -n "$CONTEXT" ] && KUBECTL_CMD="$KUBECTL_CMD --context=$CONTEXT"
[ -n "$NAMESPACE" ] && KUBECTL_CMD="$KUBECTL_CMD --namespace=$NAMESPACE"

$KUBECTL_CMD run -it --rm --restart=Never --image=${IMAGE} pvc-mounter-${SUFFIX} --overrides "
{
  \"spec\": {
    \"containers\":[
      {
        \"args\": [\"${COMMAND}\"],
        \"stdin\": true,
        \"tty\": true,
        \"name\": \"pvc\",
        \"image\": \"${IMAGE}\",
        \"volumeMounts\": [
          ${VOL_MOUNTS}
        ]
      }
    ],
    \"volumes\": [
      ${VOLS}
    ]
  }
}
" -- ${COMMAND}