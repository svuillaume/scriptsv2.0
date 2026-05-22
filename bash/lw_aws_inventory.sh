#!/bin/bash
# Script to fetch AWS inventory for Lacework / FortiCNAPP sizing.
# Requirements: awscli v2, jq
#
# Run ./lw_aws_inventory.sh -h for help on how to run the script.

# ─────────────────────────────────────────────────────────────────────────────
# Color / formatting helpers (disabled automatically when not a terminal)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[0;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''
fi

# Always send errors/warnings to stderr so CSV output to stdout stays clean
err()  { echo -e "${RED}ERROR:${RESET} $*" >&2; }
warn() { echo -e "${YELLOW}WARN:${RESET}  $*" >&2; }
info() { echo -e "${CYAN}INFO:${RESET}  $*" >&2; }
ok()   { echo -e "${GREEN}OK:${RESET}    $*" >&2; }

# ─────────────────────────────────────────────────────────────────────────────
# Error accumulator — collected and printed at end so CSV is not polluted
# ─────────────────────────────────────────────────────────────────────────────
ERRORS=()
add_error() { ERRORS+=("$1"); }

# ─────────────────────────────────────────────────────────────────────────────
# Spinner — shown on stderr so stdout (CSV) is never polluted
# ─────────────────────────────────────────────────────────────────────────────
SPINNER_PID=""
spinner_start() {
  local msg="${1:-Working…}"
  if [[ -t 2 ]]; then
    (
      local i=0
      local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
      while true; do
        printf "\r${CYAN}%s${RESET} %s  " "${spin[$i]}" "$msg" >&2
        i=$(( (i + 1) % ${#spin[@]} ))
        sleep 0.1
      done
    ) &
    SPINNER_PID=$!
  fi
}
spinner_stop() {
  if [[ -n "$SPINNER_PID" ]]; then
    kill "$SPINNER_PID" 2>/dev/null
    wait "$SPINNER_PID" 2>/dev/null
    SPINNER_PID=""
    printf "\r%-80s\r" " " >&2   # clear the spinner line
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────────────────────
function showHelp {
  echo -e "${BOLD}lw_aws_inventory.sh${RESET} — Lacework / FortiCNAPP AWS license sizing tool"
  echo ""
  echo "Collects EC2, ECS Fargate, and Lambda counts across one or more AWS accounts."
  echo "Output: CSV (importable into a spreadsheet) and a human-readable summary."
  echo ""
  echo -e "${BOLD}Requirements:${RESET}"
  echo "  • AWS CLI v2   https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  echo "  • jq           https://jqlang.github.io/jq/download/"
  echo ""
  echo -e "${BOLD}Usage:${RESET}"
  echo "  ./lw_aws_inventory.sh [FLAGS]"
  echo ""
  echo -e "${BOLD}Notes:${RESET}"
  echo "  • Must be run with bash  (./lw_aws_inventory.sh, not sh lw_aws_inventory.sh)"
  echo "  • Works in AWS CloudShell, Mac, and Linux"
  echo "  • Has been observed to work on Windows Subsystem for Linux"
  echo "  • Not compatible with Cygwin on Windows"
  echo ""
  echo -e "${BOLD}Flags:${RESET}"
  echo "  -h            Show this help message."
  echo ""
  echo "  -p PROFILES   Comma-separated list of AWS CLI profiles to scan."
  echo "                Defaults to the AWS CLI default (env vars or ~/.aws/credentials)."
  echo "                  ./lw_aws_inventory.sh -p default"
  echo "                  ./lw_aws_inventory.sh -p development,test,production"
  echo ""
  echo "  -r REGIONS    Comma-separated list of regions to scan."
  echo "                Defaults to all regions returned by 'aws ec2 describe-regions'."
  echo "                Limit scope to avoid errors in disabled regions and speed up the scan."
  echo "                  ./lw_aws_inventory.sh -r us-east-1"
  echo "                  ./lw_aws_inventory.sh -r us-east-1,us-west-1"
  echo ""
  echo "  -o ROLE       Scan an entire AWS Organization using this cross-account role."
  echo "                Uses 'aws organizations list-accounts' and assumes the role in each"
  echo "                member account (except master, which is accessed directly)."
  echo "                  ./lw_aws_inventory.sh -o OrganizationAccountAccessRole"
  echo ""
  echo "  -a ACCOUNT_ID Scan only a specific account within an organization (requires -o)."
  echo "                  ./lw_aws_inventory.sh -o OrganizationAccountAccessRole -a 123456789012"
  echo ""
  echo "  -g FILE       Generate a shell script instead of running the scan immediately."
  echo "                Useful for large organizations where you want to run per-account chunks."
  echo "                  ./lw_aws_inventory.sh -o OrganizationAccountAccessRole -g script.sh"
  echo "                  ./script.sh"
  echo ""
  echo "  --output FMT  Control what is printed:"
  echo "                  all         CSV rows + summary (default)"
  echo "                  summary     Human-readable summary only"
  echo "                  csv         CSV rows only (with header)"
  echo "                  csvnoheader CSV rows only (no header)"
  echo "                  ./lw_aws_inventory.sh --output csv"
}

# ─────────────────────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────────────────────
AWS_PROFILE=""
export AWS_MAX_ATTEMPTS=20
REGIONS=""
ORG_ACCESS_ROLE=""
ORG_SCAN_ACCOUNT=""
PRINT_CSV_DETAILS="true"
PRINT_CSV_HEADER="true"
PRINT_SUMMARY="true"
GENERATE_SCRIPT=""
START_TIME=$(date +%s)

# Preserve original credentials so we can restore after assume-role
ORG_AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID
ORG_AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY
ORG_AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN

CSV_HEADER='"Profile","Account ID","Regions","EC2 Instances","EC2 vCPUs","ECS Fargate Clusters","ECS Fargate Running Tasks","ECS Fargate CPU Units","ECS Fargate License vCPUs","Lambda Functions (not used for licensing)","Total vCPUs"'

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────
while getopts ":hp:o:r:a:-:g:" opt; do
  case ${opt} in
    h )
      showHelp
      exit 0
      ;;
    p )
      AWS_PROFILE=$OPTARG
      ;;
    o )
      ORG_ACCESS_ROLE=$OPTARG
      ;;
    a )
      ORG_SCAN_ACCOUNT=$OPTARG
      ;;
    g )
      GENERATE_SCRIPT=$OPTARG
      ;;
    r )
      REGIONS=$OPTARG
      ;;
    -)
      case "${OPTARG}" in
        output)
          output="${!OPTIND}"; OPTIND=$(( $OPTIND + 1 ))
          case "${output}" in
            csv)
              PRINT_SUMMARY="false"
              ;;
            summary)
              PRINT_CSV_DETAILS="false"
              PRINT_CSV_HEADER="false"
              ;;
            all)
              : # default — do nothing
              ;;
            csvnoheader)
              PRINT_CSV_HEADER="false"
              PRINT_SUMMARY="false"
              ;;
            *)
              err "Invalid --output value '${output}'. Valid options: all, csv, summary, csvnoheader"
              echo "" >&2
              showHelp >&2
              exit 1
              ;;
          esac
          ;;
        help)
          showHelp
          exit 0
          ;;
        *)
          err "Unknown flag --${OPTARG}"
          echo "" >&2
          showHelp >&2
          exit 1
          ;;
      esac
      ;;
    \? )
      err "Unknown flag -$OPTARG"
      echo "" >&2
      showHelp >&2
      exit 1
      ;;
    : )
      err "Flag -$OPTARG requires an argument."
      echo "" >&2
      showHelp >&2
      exit 1
      ;;
  esac
done
shift $((OPTIND -1))

# ─────────────────────────────────────────────────────────────────────────────
# Flag validation
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$ORG_SCAN_ACCOUNT" && -z "$ORG_ACCESS_ROLE" ]]; then
  err "Flag -a (account) requires -o (cross-account role) to be set as well."
  exit 1
fi

if [[ -n "$ORG_SCAN_ACCOUNT" ]] && ! [[ "$ORG_SCAN_ACCOUNT" =~ ^[0-9]{12}$ ]]; then
  err "Account ID '${ORG_SCAN_ACCOUNT}' is not a valid 12-digit AWS account ID."
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Pre-requisite checks
# ─────────────────────────────────────────────────────────────────────────────

# 1. Bash shell
if ! echo "$BASH" | grep -q "bash"; then
  err "This script must be run with bash."
  err "Use: ./lw_aws_inventory.sh (not: sh lw_aws_inventory.sh)"
  exit 1
fi

# 2. AWS CLI installed
if ! command -v aws &>/dev/null; then
  err "AWS CLI is not installed or not in PATH."
  err "Install it from: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

# 3. AWS CLI version >= 2
AWS_CLI_VERSION=$(aws --version 2>&1 | cut -d " " -f1 | cut -d "/" -f2)
if [[ "$AWS_CLI_VERSION" = 1* ]]; then
  err "AWS CLI v2 is required. Detected version: ${AWS_CLI_VERSION}"
  err "Upgrade: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
  exit 1
fi

# 4. jq installed
if ! command -v jq &>/dev/null; then
  err "jq is not installed or not in PATH."
  err "Install it from: https://jqlang.github.io/jq/download/"
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Global counters
# ─────────────────────────────────────────────────────────────────────────────
ACCOUNTS=0
ORGANIZATIONS=0
EC2_INSTANCES=0
EC2_INSTANCE_VCPU=0
ECS_FARGATE_CLUSTERS=0
ECS_FARGATE_RUNNING_TASKS=0
ECS_FARGATE_CPUS=0
LAMBDA_FUNCTIONS=0

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup on exit — restore original AWS credentials
# ─────────────────────────────────────────────────────────────────────────────
function cleanup {
  spinner_stop
  export AWS_ACCESS_KEY_ID=$ORG_AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$ORG_AWS_SECRET_ACCESS_KEY
  export AWS_SESSION_TOKEN=$ORG_AWS_SESSION_TOKEN
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# AWS helpers
# ─────────────────────────────────────────────────────────────────────────────

function getAccountId {
  local profile_string=$1
  local result
  result=$(aws $profile_string sts get-caller-identity --query "Account" --output text 2>&1)
  if [[ $? -ne 0 ]]; then
    echo ""
    add_error "sts get-caller-identity failed (profile_string='${profile_string}'): ${result}"
    return 1
  fi
  echo "$result"
}

function getRegions {
  local profile_string=$1
  local result
  result=$(aws $profile_string ec2 describe-regions --output json 2>&1)
  if [[ $? -ne 0 ]]; then
    add_error "ec2 describe-regions failed: ${result}"
    echo ""
    return 1
  fi
  echo "$result" | jq -r '.Regions[].RegionName'
}

function getEC2Instances {
  local profile_string=$1
  local r=$2
  local instances
  instances=$(aws $profile_string ec2 describe-instances \
    --query 'Reservations[*].Instances[*].[InstanceId]' \
    --filters Name=instance-state-name,Values=running \
    --region "$r" --output json --no-cli-pager 2>&1)
  if [[ $instances = \[* ]]; then
    echo "$instances" | jq 'flatten | length'
  else
    echo "-1"
  fi
}

function getEC2InstancevCPUs {
  local profile_string=$1
  local r=$2
  local cpucounts returncount=0
  cpucounts=$(aws $profile_string ec2 describe-instances \
    --query 'Reservations[*].Instances[*].[CpuOptions]' \
    --filters Name=instance-state-name,Values=running \
    --region "$r" --output json --no-cli-pager 2>/dev/null \
    | jq '.[] | .[] | .[] | .CoreCount * .ThreadsPerCore')
  for cpucount in $cpucounts; do
    returncount=$(( returncount + cpucount ))
  done
  echo "$returncount"
}

function getECSFargateClusters {
  local profile_string=$1
  local r=$2
  aws $profile_string ecs list-clusters --region "$r" --output json --no-cli-pager 2>/dev/null \
    | jq -r '.clusterArns[]'
}

# Combined ECS Fargate helper — single describe-tasks call per batch, returns
# two numbers on two lines: running_tasks  running_cpu_units
function getECSFargateMetrics {
  local profile_string=$1
  local r=$2
  local ecsfargateclusters=$3
  local RUNNING_TASKS=0
  local RUNNING_CPUS=0

  for c in $ecsfargateclusters; do
    local allclustertasks
    allclustertasks=$(aws $profile_string ecs list-tasks \
      --region "$r" --output json --cluster "$c" --no-cli-pager 2>/dev/null \
      | jq -r '.taskArns | join(" ")')

    while read -r batch; do
      if [[ -n "$batch" ]]; then
        local tasks_json
        tasks_json=$(aws $profile_string ecs describe-tasks \
          --region "$r" --output json --tasks $batch --cluster "$c" --no-cli-pager 2>/dev/null)

        local batch_tasks
        batch_tasks=$(echo "$tasks_json" \
          | jq '[.tasks[] | select(.launchType=="FARGATE") | select(.lastStatus=="RUNNING")] | length')
        RUNNING_TASKS=$(( RUNNING_TASKS + batch_tasks ))

        local batch_cpus
        batch_cpus=$(echo "$tasks_json" \
          | jq '[.tasks[] | select(.launchType=="FARGATE") | select(.lastStatus=="RUNNING")] | map(.cpu | tonumber) | add // 0')
        RUNNING_CPUS=$(( RUNNING_CPUS + batch_cpus ))
      fi
    done < <(echo "$allclustertasks" | xargs -n 90)
  done

  echo "$RUNNING_TASKS"
  echo "$RUNNING_CPUS"
}

function getLambdaFunctions {
  local profile_string=$1
  local r=$2
  local result
  result=$(aws $profile_string lambda list-functions \
    --region "$r" --output json --no-cli-pager 2>/dev/null \
    | jq '.Functions | length')
  echo "${result:-0}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Per-account inventory scan
# ─────────────────────────────────────────────────────────────────────────────
function calculateInventory {
  local account_name=$1
  local profile_string=$2
  local label="${account_name:-default}"

  local accountid
  accountid=$(getAccountId "$profile_string")
  if [[ -z "$accountid" ]]; then
    add_error "Could not resolve account ID for '${label}'. Skipping."
    warn "Skipping '${label}' — could not resolve account ID."
    return 1
  fi

  local accountEC2Instances=0
  local accountEC2vCPUs=0
  local accountECSFargateClusters=0
  local accountECSFargateRunningTasks=0
  local accountECSFargateCPUs=0
  local accountLambdaFunctions=0
  local regionsScanned=""

  # Resolve region list
  local regionsToScan
  if [[ -n "$REGIONS" ]]; then
    regionsToScan=$(echo "$REGIONS" | sed "s/,/ /g")
  else
    spinner_start "Fetching region list for ${label}…"
    regionsToScan=$(getRegions "$profile_string")
    spinner_stop
    if [[ -z "$regionsToScan" ]]; then
      add_error "Could not retrieve region list for '${label}'. Skipping."
      warn "Skipping '${label}' — could not retrieve region list."
      return 1
    fi
  fi

  local regionCount
  regionCount=$(echo "$regionsToScan" | wc -w | xargs)
  local regionIdx=0

  for r in $regionsToScan; do
    regionIdx=$(( regionIdx + 1 ))
    spinner_start "[${label}] Region ${regionIdx}/${regionCount}: ${r}"

    local instances
    instances=$(getEC2Instances "$profile_string" "$r")

    if [[ "$instances" -lt 0 ]]; then
      spinner_stop
      warn "[${label}] No access to region ${r} — skipping."
      add_error "No access to region ${r} in account '${label}' (${accountid})."
    else
      regionsScanned="${regionsScanned} ${r}"

      EC2_INSTANCES=$(( EC2_INSTANCES + instances ))
      accountEC2Instances=$(( accountEC2Instances + instances ))

      local ec2vcpu
      ec2vcpu=$(getEC2InstancevCPUs "$profile_string" "$r")
      EC2_INSTANCE_VCPU=$(( EC2_INSTANCE_VCPU + ec2vcpu ))
      accountEC2vCPUs=$(( accountEC2vCPUs + ec2vcpu ))

      local ecsfargateclusters
      ecsfargateclusters=$(getECSFargateClusters "$profile_string" "$r")
      local ecsfargateclusterscount
      ecsfargateclusterscount=$(echo "$ecsfargateclusters" | grep -c . || true)
      [[ -z "$ecsfargateclusters" ]] && ecsfargateclusterscount=0
      ECS_FARGATE_CLUSTERS=$(( ECS_FARGATE_CLUSTERS + ecsfargateclusterscount ))
      accountECSFargateClusters=$(( accountECSFargateClusters + ecsfargateclusterscount ))

      # Single combined ECS Fargate call (bash 3.2 compatible — no mapfile)
      local fargate_out
      fargate_out=$(getECSFargateMetrics "$profile_string" "$r" "$ecsfargateclusters")
      local ecsfargaterunningtasks
      ecsfargaterunningtasks=$(echo "$fargate_out" | sed -n '1p')
      local ecsfargatecpu
      ecsfargatecpu=$(echo "$fargate_out" | sed -n '2p')
      ecsfargaterunningtasks="${ecsfargaterunningtasks:-0}"
      ecsfargatecpu="${ecsfargatecpu:-0}"

      ECS_FARGATE_RUNNING_TASKS=$(( ECS_FARGATE_RUNNING_TASKS + ecsfargaterunningtasks ))
      accountECSFargateRunningTasks=$(( accountECSFargateRunningTasks + ecsfargaterunningtasks ))

      ECS_FARGATE_CPUS=$(( ECS_FARGATE_CPUS + ecsfargatecpu ))
      accountECSFargateCPUs=$(( accountECSFargateCPUs + ecsfargatecpu ))

      local lambdafunctions
      lambdafunctions=$(getLambdaFunctions "$profile_string" "$r")
      LAMBDA_FUNCTIONS=$(( LAMBDA_FUNCTIONS + lambdafunctions ))
      accountLambdaFunctions=$(( accountLambdaFunctions + lambdafunctions ))
    fi
    spinner_stop
  done

  local accountECSFargatevCPUs=$(( accountECSFargateCPUs / 1024 ))
  local accountTotalvCPUs=$(( accountEC2vCPUs + accountECSFargatevCPUs ))
  local scannedRegionList
  scannedRegionList=$(echo "$regionsScanned" | xargs | sed "s/ /|/g")

  if [[ $PRINT_CSV_DETAILS == "true" ]]; then
    echo "\"${label}\",\"${accountid}\",\"${scannedRegionList}\",\"${accountEC2Instances}\",\"${accountEC2vCPUs}\",\"${accountECSFargateClusters}\",\"${accountECSFargateRunningTasks}\",\"${accountECSFargateCPUs}\",\"${accountECSFargatevCPUs}\",\"${accountLambdaFunctions}\",\"${accountTotalvCPUs}\""
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary output
# ─────────────────────────────────────────────────────────────────────────────
function textoutput {
  local elapsed=$(( $(date +%s) - START_TIME ))
  local ECS_FARGATE_VCPUS=$(( ECS_FARGATE_CPUS / 1024 ))
  local TOTAL_VCPUS=$(( EC2_INSTANCE_VCPU + ECS_FARGATE_VCPUS ))

  echo -e "\n${BOLD}######################################################################${RESET}" >&2
  echo -e "${BOLD}  Lacework / FortiCNAPP inventory collection complete${RESET}  (${elapsed}s)" >&2
  echo -e "${BOLD}######################################################################${RESET}" >&2
  echo "" >&2
  echo -e "  Organizations Analyzed : ${CYAN}${ORGANIZATIONS}${RESET}" >&2
  echo -e "  Accounts Analyzed      : ${CYAN}${ACCOUNTS}${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}EC2${RESET}" >&2
  echo -e "  ─────────────────────────────────" >&2
  echo -e "  Instances              : ${GREEN}${EC2_INSTANCES}${RESET}" >&2
  echo -e "  vCPUs                  : ${GREEN}${EC2_INSTANCE_VCPU}${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}ECS Fargate${RESET}" >&2
  echo -e "  ─────────────────────────────────" >&2
  echo -e "  Clusters               : ${GREEN}${ECS_FARGATE_CLUSTERS}${RESET}" >&2
  echo -e "  Running Tasks          : ${GREEN}${ECS_FARGATE_RUNNING_TASKS}${RESET}" >&2
  echo -e "  Container CPU Units    : ${GREEN}${ECS_FARGATE_CPUS}${RESET}" >&2
  echo -e "  License vCPUs          : ${GREEN}${ECS_FARGATE_VCPUS}${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}Lambda (not used for licensing)${RESET}" >&2
  echo -e "  ─────────────────────────────────" >&2
  echo -e "  Functions              : ${GREEN}${LAMBDA_FUNCTIONS}${RESET}" >&2
  echo "" >&2
  echo -e "  ${BOLD}License Estimate${RESET}" >&2
  echo -e "  ─────────────────────────────────" >&2
  echo -e "    EC2 vCPUs            : ${EC2_INSTANCE_VCPU}" >&2
  echo -e "  + ECS Fargate vCPUs   : ${ECS_FARGATE_VCPUS}" >&2
  echo -e "  ─────────────────────────────────" >&2
  echo -e "  = ${BOLD}Total vCPUs${RESET}           : ${BOLD}${GREEN}${TOTAL_VCPUS}${RESET}" >&2
  echo "" >&2

  # Print collected errors (if any)
  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "  ${BOLD}${RED}Errors / Warnings (${#ERRORS[@]})${RESET}" >&2
    echo -e "  ─────────────────────────────────" >&2
    for e in "${ERRORS[@]}"; do
      echo -e "  ${RED}•${RESET} ${e}" >&2
    done
    echo "" >&2
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Organization scan helpers
# ─────────────────────────────────────────────────────────────────────────────
function analyzeOrganization {
  local org_profile_string=$1
  local orgAccountId
  orgAccountId=$(getAccountId "$org_profile_string")

  spinner_start "Fetching organization account list…"
  local accounts
  accounts=$(aws $org_profile_string organizations list-accounts 2>&1 \
    | jq -c '.Accounts[] | {Id, Name}')
  spinner_stop

  if [[ -z "$accounts" ]]; then
    err "Failed to list organization accounts. Check that Organizations access is enabled."
    add_error "Could not list organization accounts."
    return 1
  fi

  local total_accounts
  total_accounts=$(echo "$accounts" | wc -l | xargs)
  local current_account=0

  if [[ -n "$ORG_SCAN_ACCOUNT" ]]; then
    local account_name
    account_name=$(echo "$accounts" | jq -r --arg a "$ORG_SCAN_ACCOUNT" 'select(.Id==$a) | .Name')
    if [[ -z "$account_name" ]]; then
      err "Account ID '${ORG_SCAN_ACCOUNT}' not found in organization."
      return 1
    fi
    analyzeOrganizationAccount "$org_profile_string" "$ORG_SCAN_ACCOUNT" "$account_name"
  else
    for account in $(echo "$accounts" | jq -r '.Id'); do
      current_account=$(( current_account + 1 ))
      local account_name
      account_name=$(echo "$accounts" | jq -r --arg a "$account" 'select(.Id==$a) | .Name')
      info "Account ${current_account}/${total_accounts}: ${account_name} (${account})"
      if [[ "$orgAccountId" == "$account" ]]; then
        # Master account — access directly (role may not exist)
        ACCOUNTS=$(( ACCOUNTS + 1 ))
        calculateInventory "$account_name" "$org_profile_string"
      else
        analyzeOrganizationAccount "$org_profile_string" "$account" "$account_name"
      fi
    done
  fi
}

function analyzeOrganizationAccount {
  local org_profile_string=$1
  local account=$2
  local account_name=$3

  local account_credentials
  account_credentials=$(aws $org_profile_string sts assume-role \
    --role-session-name LW-INVENTORY \
    --role-arn "arn:aws:iam::${account}:role/${ORG_ACCESS_ROLE}" 2>&1)

  if [[ $account_credentials = \{* ]]; then
    ACCOUNTS=$(( ACCOUNTS + 1 ))
    export AWS_ACCESS_KEY_ID=$(echo "$account_credentials" | jq -r '.Credentials.AccessKeyId')
    export AWS_SECRET_ACCESS_KEY=$(echo "$account_credentials" | jq -r '.Credentials.SecretAccessKey')
    export AWS_SESSION_TOKEN=$(echo "$account_credentials" | jq -r '.Credentials.SessionToken')
    calculateInventory "$account_name" ""
    # Restore org credentials
    export AWS_ACCESS_KEY_ID=$ORG_AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY=$ORG_AWS_SECRET_ACCESS_KEY
    export AWS_SESSION_TOKEN=$ORG_AWS_SESSION_TOKEN
  else
    err "Failed to assume role in account '${account_name}' (${account})."
    err "Role ARN: arn:aws:iam::${account}:role/${ORG_ACCESS_ROLE}"
    err "AWS response: ${account_credentials}"
    add_error "Could not assume role in '${account_name}' (${account}): ${account_credentials}"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main analysis runner
# ─────────────────────────────────────────────────────────────────────────────
function runAnalysis {
  if [[ $PRINT_CSV_HEADER == "true" ]]; then
    echo "$CSV_HEADER"
  fi

  local HAS_PROFILE=false

  if [[ -n "$ORG_ACCESS_ROLE" ]]; then
    if [[ -n "$AWS_PROFILE" ]]; then
      HAS_PROFILE=true
      for PROFILE in $(echo "$AWS_PROFILE" | sed "s/,/ /g"); do
        ORGANIZATIONS=$(( ORGANIZATIONS + 1 ))
        info "Scanning organization via profile: ${PROFILE}"
        analyzeOrganization "--profile $PROFILE"
      done
    fi
    if [[ "$HAS_PROFILE" == "false" ]]; then
      ORGANIZATIONS=1
      info "Scanning organization via default credentials"
      analyzeOrganization ""
    fi
  else
    if [[ -n "$AWS_PROFILE" ]]; then
      HAS_PROFILE=true
      for PROFILE in $(echo "$AWS_PROFILE" | sed "s/,/ /g"); do
        info "Scanning account via profile: ${PROFILE}"
        ACCOUNTS=$(( ACCOUNTS + 1 ))
        calculateInventory "$PROFILE" "--profile $PROFILE"
      done
    fi
    if [[ "$HAS_PROFILE" == "false" ]]; then
      info "Scanning account via default credentials"
      ACCOUNTS=1
      calculateInventory "" ""
    fi
  fi

  if [[ $PRINT_SUMMARY == "true" ]]; then
    textoutput
  elif [[ ${#ERRORS[@]} -gt 0 ]]; then
    # Always print errors to stderr even in csv-only mode
    echo -e "\n${RED}${#ERRORS[@]} error(s) occurred during the scan:${RESET}" >&2
    for e in "${ERRORS[@]}"; do
      echo -e "  ${RED}•${RESET} ${e}" >&2
    done
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Script generator
# ─────────────────────────────────────────────────────────────────────────────
function generateOrganizationScript {
  local profile=$1
  local cliProfileString=$2
  local regionString=$3
  local orgMasterAccountID
  orgMasterAccountID=$(getAccountId "$cliProfileString")

  spinner_start "Fetching organization accounts for script generation…"
  local accounts
  accounts=$(aws $cliProfileString organizations list-accounts 2>/dev/null \
    | jq -c '.Accounts[] | {Id, Name}')
  spinner_stop

  for account in $(echo "$accounts" | jq -r '.Id'); do
    if [[ "$orgMasterAccountID" == "$account" ]]; then
      echo "$0 ${profile} ${regionString} --output csvnoheader" >> "$GENERATE_SCRIPT"
    else
      echo "$0 ${profile} -o $ORG_ACCESS_ROLE -a $account ${regionString} --output csvnoheader" >> "$GENERATE_SCRIPT"
    fi
  done
}

function generateScript {
  if [[ -f "$GENERATE_SCRIPT" ]]; then
    warn "Output script '${GENERATE_SCRIPT}' already exists and will be overwritten."
  fi
  info "Generating script: ${GENERATE_SCRIPT}"

  echo "#!/bin/bash" > "$GENERATE_SCRIPT"
  echo "echo ${CSV_HEADER}" >> "$GENERATE_SCRIPT"
  chmod +x "$GENERATE_SCRIPT"

  local scriptRegions=""
  if [[ -n "$REGIONS" ]]; then
    scriptRegions="-r $REGIONS"
  fi

  local HAS_PROFILE=false
  if [[ -n "$ORG_ACCESS_ROLE" ]]; then
    if [[ -n "$AWS_PROFILE" ]]; then
      HAS_PROFILE=true
      for PROFILE in $(echo "$AWS_PROFILE" | sed "s/,/ /g"); do
        generateOrganizationScript "-p $PROFILE" "--profile $PROFILE" "$scriptRegions"
      done
    fi
    if [[ "$HAS_PROFILE" == "false" ]]; then
      generateOrganizationScript "" "" "$scriptRegions"
    fi
  else
    if [[ -n "$AWS_PROFILE" ]]; then
      HAS_PROFILE=true
      for PROFILE in $(echo "$AWS_PROFILE" | sed "s/,/ /g"); do
        echo "$0 -p $PROFILE $scriptRegions --output csvnoheader" >> "$GENERATE_SCRIPT"
      done
    fi
    if [[ "$HAS_PROFILE" == "false" ]]; then
      echo "$0 $scriptRegions --output csvnoheader" >> "$GENERATE_SCRIPT"
    fi
  fi

  ok "Script generated: ${GENERATE_SCRIPT}  ($(wc -l < "$GENERATE_SCRIPT") lines)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Entry point
# ─────────────────────────────────────────────────────────────────────────────
if [[ -n "$GENERATE_SCRIPT" ]]; then
  generateScript
else
  runAnalysis
fi
