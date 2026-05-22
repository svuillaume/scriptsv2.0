# Handy Bash Scripts for Working with Lacework / FortiCNAPP

---

## lw_aws_inventory.sh

Estimates Lacework / FortiCNAPP license vCPUs across one or more AWS accounts or an entire AWS Organization.  
Output: a CSV row per account (importable into a spreadsheet) and a human-readable summary.

### Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html |
| jq | any | https://jqlang.github.io/jq/download/ |
| bash | 3.2+ | Pre-installed on Mac and Linux |

> **Must be run as** `./lw_aws_inventory.sh` — not `sh lw_aws_inventory.sh`

### Platform support

| Platform | Support |
|----------|---------|
| macOS | ✅ Verified |
| Linux | ✅ Verified |
| AWS CloudShell | ✅ Works great |
| Windows Subsystem for Linux | ✅ Observed to work |
| Windows (Cygwin) | ❌ Not supported |

---

### What gets counted toward vCPUs

| Resource | Counted? | Notes |
|----------|----------|-------|
| EC2 running instances | ✅ Yes | CoreCount × ThreadsPerCore per instance |
| ECS Fargate running tasks | ✅ Yes | CPU units ÷ 1024 = vCPUs |
| Stopped / terminated EC2 | ❌ No | Only `running` state |
| Lambda functions | ❌ No | Shown in output but not in license total |

---

### Flags

```
-h                Show help message
-p PROFILES       Comma-separated AWS CLI profile(s) to scan
-r REGIONS        Comma-separated region(s) to scan (default: all 17 regions)
-o ROLE_NAME      Cross-account role name for AWS Organization scan
-a ACCOUNT_ID     Scan a single account within an organization (requires -o)
-g FILE           Generate a per-account script instead of running immediately
--output FORMAT   Control output: all (default) | csv | summary | csvnoheader
```

---

### Usage examples

#### Single account — default credentials
```bash
./lw_aws_inventory.sh
```

#### Single account — named profile
```bash
./lw_aws_inventory.sh -p myprofile
```

#### Multiple profiles
```bash
./lw_aws_inventory.sh -p dev,staging,production
```

#### Limit regions (faster, avoids disabled-region errors)
```bash
./lw_aws_inventory.sh -r us-east-1,us-west-2,eu-west-1
```

#### Scan all accounts in an AWS Organization
```bash
./lw_aws_inventory.sh -o OrganizationAccountAccessRole
```

This assumes a cross-account IAM role into every member account in the organization and scans each one.  
See **[Understanding -o / Cross-Account Role](#understanding--o--cross-account-role)** below.

#### Scan a single account within an organization
```bash
./lw_aws_inventory.sh -o OrganizationAccountAccessRole -a 123456789012
```

#### Combine org scan with region restriction
```bash
./lw_aws_inventory.sh -o OrganizationAccountAccessRole -r us-east-1,us-east-2
```

#### Save CSV to a file, show summary on screen
```bash
./lw_aws_inventory.sh --output csv > results.csv
./lw_aws_inventory.sh --output summary
```

#### Generate a per-account script for large organizations
```bash
# Step 1: generate the script
./lw_aws_inventory.sh -o OrganizationAccountAccessRole -g scan_org.sh

# Step 2: run it (accounts are processed one at a time — easier to debug)
./scan_org.sh
```

---

### Sample output

```
INFO:  Scanning account via profile: admin-account
INFO:  [sandbox-1] Region 1/3: us-east-1
INFO:  [sandbox-2] Region 1/3: us-east-1
INFO:  [logging]   Region 1/3: us-east-1

"Profile","Account ID","Regions","EC2 Instances","EC2 vCPUs","ECS Fargate Clusters","ECS Fargate Running Tasks","ECS Fargate CPU Units","ECS Fargate License vCPUs","Lambda Functions (not used for licensing)","Total vCPUs"
"sandbox-1","123456789012","us-east-1","2","4","0","0","0","0","1","4"
"sandbox-2","234567890123","us-east-1","0","0","0","0","0","0","0","0"
"logging",  "345678901234","us-east-1","0","0","0","0","0","0","0","0"

######################################################################
  Lacework / FortiCNAPP inventory collection complete  (42s)
######################################################################

  Organizations Analyzed : 1
  Accounts Analyzed      : 3

  EC2
  ─────────────────────────────────
  Instances              : 2
  vCPUs                  : 4

  ECS Fargate
  ─────────────────────────────────
  Clusters               : 0
  Running Tasks          : 0
  Container CPU Units    : 0
  License vCPUs          : 0

  Lambda (not used for licensing)
  ─────────────────────────────────
  Functions              : 1

  License Estimate
  ─────────────────────────────────
    EC2 vCPUs            : 4
  + ECS Fargate vCPUs   : 0
  ─────────────────────────────────
  = Total vCPUs           : 4
```

> **Note:** Progress spinners and info messages go to **stderr**. The CSV rows go to **stdout** so you can pipe or redirect cleanly:
> ```bash
> ./lw_aws_inventory.sh --output csv > results.csv
> ```

---

### Understanding `-o` / Cross-Account Role

The `-o` flag enables **AWS Organization scanning**. The script:

1. Calls `aws organizations list-accounts` from your management account to get **all accounts across all OUs** (any nesting depth)
2. Calls `sts:AssumeRole` into each member account using the role name you provide
3. Scans EC2, ECS Fargate, and Lambda in every region of every account

```
AWS Organization (Root)
├── Management Account         ← scanned directly (no role needed)
├── OU: Production
│   ├── Account A              ← role assumed → scanned
│   └── Account B              ← role assumed → scanned
├── OU: Development
│   └── Account C              ← role assumed → scanned
└── OU: Security
    └── Sub-OU: Audit
        └── Account D          ← role assumed → scanned  (any depth)
```

#### What role name to use

AWS automatically creates `OrganizationAccountAccessRole` in every account enrolled via AWS Organizations. If your organization uses a different name (e.g., AWS Control Tower creates `AWSControlTowerExecution`), pass that instead:

```bash
./lw_aws_inventory.sh -o AWSControlTowerExecution
./lw_aws_inventory.sh -o MyCompany-ReadOnlyRole
```

#### Minimum IAM permissions required on the cross-account role

```json
{
  "Effect": "Allow",
  "Action": [
    "ec2:DescribeInstances",
    "ec2:DescribeRegions",
    "ecs:ListClusters",
    "ecs:ListTasks",
    "ecs:DescribeTasks",
    "lambda:ListFunctions",
    "sts:GetCallerIdentity"
  ],
  "Resource": "*"
}
```

The role's **trust policy** must allow your management account to assume it:

```json
{
  "Effect": "Allow",
  "Principal": {
    "AWS": "arn:aws:iam::MANAGEMENT_ACCOUNT_ID:root"
  },
  "Action": "sts:AssumeRole"
}
```

#### Verify the role works before running the full scan

```bash
aws sts assume-role \
  --role-arn arn:aws:iam::MEMBER_ACCOUNT_ID:role/OrganizationAccountAccessRole \
  --role-session-name test-lw-inventory
```

✅ Returns credentials → role is configured correctly  
❌ `AccessDenied` → trust policy is missing or role does not exist in that account

---

## lw_gcp_inventory.sh

Script for estimating license vCPUs in a GCP environment, based on folder, project or organization level.

Note the following about the script:
* It does not work on Windows
* It has only been verified to work on Mac and Linux based systems
* It works great in a cloud shell

```
$ ./lw_gcp_inventory.sh -help
Usage: ./lw_gcp_inventory.sh [-f folder] [-o organization] [-p project]
Any single scope can have multiple values comma delimited, but multiple scopes cannot be defined.
```

By default, the script will scan any project that the user has access to:
```
$ ./lw_gcp_inventory.sh
"Project", "VM Count", "vCPUs"
"projects/project-one", 2, 8
"projects/project-two", 3, 12
##########################################
Lacework inventory collection complete.

License Summary:
================================================
Number of VMs, including standard GKE: 5
vCPUs:                                 20
```

The scope of the scan can be further refined using the -f, -o or -p parameters:
```
$ ./lw_gcp_inventory.sh -p project-one,project-two
"Project", "VM Count", "vCPUs"
"projects/project-one", 2, 8
"projects/project-two", 3, 12
##########################################
Lacework inventory collection complete.

License Summary:
================================================
Number of VMs, including standard GKE: 5
vCPUs:                                 20
```

---

## lw_azure_inventory.sh

Script for estimating license vCPUs in an Azure environment, based on management group or subscription.

Note the following about the script:
* It does not work on Windows
* It has only been verified to work on Mac and Linux based systems
* It works great in a cloud shell

```
./lw_azure_inventory.sh -help
Usage: ./lw_azure_inventory.sh [-m management_group] [-s subscription]
Any single scope can have multiple values comma delimited, but multiple scopes cannot be defined.
```

By default, the script will scan any subscriptions the user has configured access to:
```
$ ./lw_azure_inventory.sh -m b448f327-c977-4cb8-9c27-09cfaa781bb9
resource-graph extension already present...
Building Azure VM SKU to vCPU map...
Map built successfully.
Load subscriptions
Load VMs
Load VMSS
"Subscription ID", "Subscription Name", "VM Instances", "VM vCPUs", "VM Scale Sets", "VM Scale Set Instances", "VM Scale Set vCPUs", "Total Subscription vCPUs"
"1215ba55...", "Subscription Number One", 2, 4, 0, 0, 0, 4
"72165fcf...", "Subscription Number Two", 1, 2, 0, 0, 0, 2
##########################################
Lacework inventory collection complete.

VM Summary:
===============================
VM Instances:     3
VM vCPUS:         6

VM Scale Set Summary:
===============================
VM Scale Sets:          0
VM Scale Set Instances: 0
VM Scale Set vCPUs:     0

License Summary
===============================
  VM vCPUS:             6
+ VM Scale Set vCPUs:   0
-------------------------------
Total vCPUs:            6
```

The scope can further be refined by specifying management groups or subscriptions.

### Specify subscriptions to scan
```
$ ./lw_azure_inventory.sh -s 1215ba55,72165fcf
```

### Specify management group to scan
```
$ ./lw_azure_inventory.sh -m mymanagementgroup,myothermanagementgroup
```
