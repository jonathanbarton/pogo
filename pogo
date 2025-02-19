#!/bin/bash

# This is a script that allows you to programmatically connect
# to different AWS EC2 hosts via a Bastion host.
# For original source code modified: https://github.com/needcaffeine/heimdall
# For issues: https://github.com/jonathanbarton/pogo 

# Usage:
# $ ./pogo

# Configuration options for your organization.
pogoDir="$(dirname "$(readlink "$0")")"
source "${pogoDir}/pogo.conf"

###############################################################################
# Do not modify the script below this line unless you know what you're doing. #
###############################################################################

ed() {
    { local line ; line=${@:1} ; }
    if [[ $DEBUG -eq 1 ]]; then
        LG='\033[0;34m'
        NC='\033[0m' # No Color
        echo -e "\033${LG}${line}\033${NC}" 1>&2
    fi
}

ee() {
    { local line ; line=${@:1} ; }
    RED='\033[0;31m'
    NC='\033[0m' # No Color
    echo -e "\033${RED}${line}\033${NC}" 1>&2
}

bold=$(tput bold)
normal=$(tput sgr0)

# Read in any positional arguments that were passed in.
args=()
numArgs=($#)
while [[ "$#" > 0 ]]; do
    case "${1}" in
        -x)
            set -x
            shift;;
        --bastion-dns-name | \
            --bastion-host-name | \
            --bastion-host-port | \
            --bastion-security-group-id | \
            --bastion-user | \
            --debug | \
            --ssh-key-file)
            if [[ -z ${2} || ${2} =~ \-\-.* ]]; then
                # Ignore flags without values.
                shift
            else
                # replace "--" with nothing
                override=${1/--/}

                # replace "-" with "_"
                override=${override//-/_}

                # convert to uppercase
                override=$(echo ${override} | awk '{print toupper($0)}')

                declare ${override}="${2}"
                shift 2
            fi
            ;;
        --profile)
            if [[ ! -z ${PROFILES} ]]; then
                # Set the awscli profile
                PROFILE=${2}

                for profile_name in $(echo ${PROFILES} | jq -r '. | keys | .[]'); do
                    # Only override env variables if the provided profile_name is configured
                    if [[ ${profile_name} != ${2} ]]; then
                        continue
                    fi

                    profile_defaults=$(echo ${PROFILES} | jq -r .\"${profile_name}\")
                    while IFS='|' read key value; do
                        eval ${key}="'${value}'"
                    done <<< "$(jq -r 'to_entries | map(.key + "|" + (.value | tostring)) | .[]' <<<"${profile_defaults}")"
                done
                shift 2
            fi
            ;;
        *) args+=("${1}"); shift;; # save argument for later
    esac
done
set -- "${args[@]}" # restore saved arguments

# Set the default awscli profile if not configured.
PROFILE="${PROFILE:-default}"

# If this script was invoked without any arguments, display usage information.
if [[ $numArgs -eq 0 ]]; then
    echo Connect to different AWS EC2 hosts via a Bastion/Jump host.
    echo
    echo ${bold}USAGE${normal}
    echo "  ./pogo <command> <target> [flags]"
    echo
    echo ${bold}CORE COMMANDS${normal}
    echo "  list:                       List all available hosts."
    echo "  list-db                     List all database instances."
    echo "  grant:                      Grants access to your IP to the bastion security group."
    echo "  revoke:                     Revokes access to your IP to the bastion security group."
    echo "  show:                       Shows current IP address."
    echo "  bastion:                    Logs you into the bastion itself."
    echo
    echo ${bold}TARGETS${normal}
    echo "  host:                       Logs you into host via the bastion and the current user."
    echo "  user@host:                  Logs you into host via the bastion and the specified user."
    echo "  service#cluster:            Logs you into a specific service on the specified cluster."
    echo
    echo ${bold}TUNNELS${normal}
    echo "  tunnel:                     Tunnel into host."
    echo 
    echo ${bold}FLAGS${normal}
    echo "  --profile <profile>         Switches your AWSCLI profile to a different one in your .aws/config file."
    echo "  NOTE:                       Every configurable variable found in pogo.conf can be passed as a flag."
    echo "                              The format is to use lowercase, kebab-case names with a value."
    echo "                              Example: --bastion-host-name would set/override the config variable BASTION_HOST_NAME."
    echo
    echo ${bold}EXAMPLES${normal}
    echo "  $ ./pogo list"
    echo "  $ ./pogo ec2-user@Prod1"
    echo "  $ ./pogo backend#production"
    exit
fi

case ${args[0]} in
    show|grant|revoke|lock|unlock|tunnel)
        ip=`dig -4 +short myip.opendns.com @resolver1.opendns.com`
        numArgs=($#)
        case ${args[0]} in
            show)
                echo "Your IP Address is: ${ip}"
            ;;
            revoke|lock)
                echo "Revoking your IP (${ip}/32) access to the ingress group..."
                aws ec2 revoke-security-group-ingress --group-id ${BASTION_SECURITY_GROUP_ID} --protocol tcp --port 22 --cidr ${ip}/32 --profile ${PROFILE}
                ;;
            grant|unlock)
                echo "Granting your IP (${ip}/32) access to the ingress group..."
                aws ec2 authorize-security-group-ingress --group-id ${BASTION_SECURITY_GROUP_ID} --protocol tcp --port 22 --cidr ${ip}/32 --profile ${PROFILE}
                ;;
            tunnel)
                if [[ $numArgs -eq 2 ]]; then
                    instance_id=${args[1]}
                    DB_ENDPOINT=`aws rds describe-db-instances --filters "Name=db-instance-id,Values=${instance_id}" --profile ${PROFILE} | jq ".DBInstances[] | .Endpoint.Address"`
                    DB_PORT=`aws rds describe-db-instances --filters "Name=db-instance-id,Values=${instance_id}" --profile ${PROFILE} | jq ".DBInstances[] | .Endpoint.Port"`
                    ssh -i ${SSH_KEY_FILE} -N -L ${TUNNEL_LOCAL_PORT}:${DB_ENDPOINT}:${DB_PORT} ${BASTION_USER}@${BASTION_DNS_NAME}
                else
                    echo "Missing DB Instance ID (Example: ./pogo tunnel prod-db-2)"
                fi
            ;;
            esac
            ;;

    list )
        echo "Listing all running instances:"
        aws ec2 describe-instances --profile ${PROFILE} | jq '[.Reservations | .[] | .Instances | .[] | select(.State.Name!="terminated") | {Name: (.Tags[]|select(.Key=="Name")|.Value), PrivateIpAddress: .PrivateIpAddress, VpcId: .VpcId, Subnet: .SubnetId, InstanceType: .InstanceType,State: .State.Name}]' 
        ;;
    list-db )
        echo "Listing all database instances:"
        aws rds describe-db-instances --profile ${PROFILE} | jq ".DBInstances[] | {DBInstanceIdentifier: .DBInstanceIdentifier, EndpointAddress: .Endpoint.Address }" 
        ;;
    bastion|* )
        # Do we need to figure out the dns name for our Bastion host?
        if [[ -z "$BASTION_DNS_NAME" && -z "$BASTION_HOST_NAME" ]]; then
            ee "[ERROR] Please set either BASTION_DNS_NAME or BASTION_HOST_NAME."
            exit 127
        fi

        BASTION_DNS_NAME=${BASTION_DNS_NAME:-$(aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=${BASTION_HOST_NAME}" --profile ${PROFILE} | jq -r '.Reservations[].Instances[].PublicDnsName')}

        # If the target param contains a username, split it out so we can determine the host dns.
        host=${args[0]}
        if [[ ${host} =~ "#" ]]; then
            SEARCH_SERVICE=$(echo ${host} | cut -f1 -d\#)
            SEARCH_CLUSTER=$(echo ${host} | cut -f2 -d\#)

            # Allow executing a full command (with multiple parameters), defaulting to bash.
            EXECUTABLE=("${args[@]:1}")
            if [ ${#EXECUTABLE[@]} -eq 0 ]; then
                EXECUTABLE=bash
            fi

            echo "[INFO] Looking"

            CLUSTER=`aws ecs list-clusters --profile ${PROFILE} | jq -r ".clusterArns[] | select(. | match (\"$SEARCH_CLUSTER\$\"))"`
            if (( `echo $CLUSTER | wc -w` > 1 )); then
                ee "[ERROR] More than one matching cluster arn found"
                ee "[ERROR] Got cluster arns:"
                ee "$CLUSTER"
                exit 127
            fi
            if (( `echo $CLUSTER | wc -w` == 0 )); then
                ee "[ERROR] No matching cluster arn found"
                exit 127
            fi
            ed "[DEBUG] Got a cluster arn:\t$CLUSTER"
            CLUSTER="--cluster $CLUSTER"

            SERVICEARN=`aws ecs list-services $CLUSTER --profile ${PROFILE} | jq -r ".serviceArns[] | select(. | contains(\"$SEARCH_SERVICE\"))"`
            if (( `echo $SERVICEARN | wc -w` > 1 )); then
                ee "[ERROR] More than one matching service arn found"
                ee "[ERROR] Got service arns:"
                ee "$SERVICEARN"
                exit 127
            fi
            if (( `echo $SERVICEARN | wc -w` == 0 )); then
                ee "[ERROR] No matching service arn found"
                exit 127
            fi
            ed "[DEBUG] Got a service arn:\t$SERVICEARN"

            TASK=`aws ecs list-tasks $CLUSTER --service $SERVICEARN --profile ${PROFILE} | jq -r '.taskArns[0]'`
            DESCRIBE_TASK=`aws ecs describe-tasks --task $TASK $CLUSTER --profile ${PROFILE}`
            ed "[DEBUG] Got a task:\t\t$TASK"

            CONTAINER_INSTANCE=`echo $DESCRIBE_TASK | jq -r '.tasks[].containerInstanceArn'`
            TASK_DEFINITION_ARN=`echo $DESCRIBE_TASK | jq -r '.tasks[].taskDefinitionArn' | cut -f2 -d/ | sed 's/:/-/'`
            ed "[DEBUG] Got a container instance:\t$CONTAINER_INSTANCE"
            ed "[DEBUG] Got an image name piece:\t$TASK_DEFINITION_ARN"

            INSTANCE_ID=`aws ecs describe-container-instances $CLUSTER --container-instance $CONTAINER_INSTANCE --profile ${PROFILE} | jq -r '.containerInstances[].ec2InstanceId'`
            ed "[DEBUG] Got an instance id:\t$INSTANCE_ID"

            HOST=`aws ec2 describe-instances --instance-ids $INSTANCE_ID --profile ${PROFILE} | jq -r '.Reservations[].Instances[].PrivateDnsName'`
            ed "[DEBUG] Got a hostname:\t\t$HOST"
            echo "[INFO] Connecting"

            ed "[DEBUG] Using executable ${EXECUTABLE[@]}"
            ssh -i ${SSH_KEY_FILE} -p ${BASTION_HOST_PORT:-22} -A -t ${BASTION_USER}@${BASTION_DNS_NAME} "ssh -A -t ec2-user@${HOST} \"docker exec -it --detach-keys 'ctrl-q,q' \\\$(docker ps --format='{{.Names}}' | grep $TASK_DEFINITION_ARN | awk '{print \$1}' | head -n 1) ${EXECUTABLE[@]}\""
            exit
        fi
        if [[ ${host} =~ "@" ]]; then
            user=$(echo ${host} | cut -f1 -d@)
            host=$(echo ${host} | cut -f2 -d@)
        fi

        # If a user was not provided, use the currently logged in user.
        user=${user:-$USER}

        case ${args[0]} in
            bastion)
                ssh -i ${SSH_KEY_FILE} -p ${BASTION_HOST_PORT:-22} -A -t ${BASTION_USER}@${BASTION_DNS_NAME}
                ;;
            *)
                # Figure out the host ip.
                PRIVATE_IP=`aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" "Name=tag:Name,Values=${host}" --profile ${PROFILE} | jq -r '.Reservations[].Instances[].PrivateIpAddress'`

                if [[ -z ${PRIVATE_IP} ]]; then
                    ee "${host} is not a valid instance tag."
                    exit 127
                fi

                # Do the magic.
                #ssh -i ${SSH_KEY_FILE} -p ${BASTION_HOST_PORT:-22} -A -t ${BASTION_USER}@${BASTION_DNS_NAME} ssh -A -t ${BASTION_USER}@${PRIVATE_IP} -v
                ssh -i ${SSH_KEY_FILE} -o ProxyCommand="ssh -i ${SSH_KEY_FILE} -W %h:%p ${BASTION_USER}@${BASTION_DNS_NAME}"  ${BASTION_USER}@${PRIVATE_IP}
                ;;
            esac
        ;;
esac
