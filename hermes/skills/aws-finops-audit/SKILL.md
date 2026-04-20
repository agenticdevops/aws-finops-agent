---
name: aws-finops-audit
description: "Detect AWS resource waste — stopped EC2, orphaned EBS, unassociated EIPs, idle RDS, unused ELBs, NAT Gateways, unused security groups. Uses MCP aws-finops server + AWS CLI. Read-only operations only."
version: 1.0.0
author: gshah
license: MIT
metadata:
  hermes:
    tags: [AWS, FinOps, cost-optimization, waste-detection, cloud, devops]
    category: devops
    requires_toolsets: [terminal]
---

# AWS FinOps Audit — Waste Detection

Identify unused and idle AWS resources across accounts and regions using read-only operations to surface cost optimization opportunities.

## When to Use

- Find unused or idle AWS resources that are incurring unnecessary costs
- Identify waste across EC2, EBS, EIP, RDS, ELB, NAT Gateway, and Security Group resources
- Run a weekly or monthly cloud cost audit
- Investigate stopped instances, orphaned volumes, or idle databases before a cost review meeting
- Produce a waste report for FinOps or cloud governance teams

## Prerequisites

- AWS CLI installed and configured (`aws --version`)
- Valid AWS CLI profiles configured in `~/.aws/credentials` or `~/.aws/config`
- IAM permissions as defined in `shared/iam-policy.json` (read-only FinOps policy)
- Optional: MCP `aws-finops` server running locally for enhanced reporting

Validate your credentials before running any checks:

```bash
aws sts get-caller-identity --profile <name>
```

## SAFETY RULES

**NEVER run any destructive commands.** This skill is strictly read-only.

The following operations are **NEVER** permitted:
- **NEVER** use `delete`, `terminate`, `stop`, `modify`, `update`, or `create` subcommands
- **NEVER** use `iam` commands (no policy changes, no user management)
- **NEVER** use `organizations` commands
- **NEVER** run anything that mutates AWS state

**ONLY** the following are allowed: `describe-*`, `list-*`, `get-*`, `cloudwatch get-metric-statistics`

If you are unsure whether a command is read-only, do not run it.

## Quick Reference

| Check | Command |
|---|---|
| Stopped EC2 instances | `aws ec2 describe-instances --filters "Name=instance-state-name,Values=stopped"` |
| Orphaned EBS volumes | `aws ec2 describe-volumes --filters "Name=status,Values=available"` |
| Unassociated EIPs | `aws ec2 describe-addresses` (filter where AssociationId is null) |
| Idle RDS instances | `aws rds describe-db-instances` + CloudWatch `DatabaseConnections` metric |
| Unused ELBs | `aws elbv2 describe-load-balancers` + `describe-target-health` |
| NAT Gateways | `aws ec2 describe-nat-gateways --filter "Name=state,Values=available"` |
| Unused Security Groups | Cross-reference `describe-security-groups` with `describe-network-interfaces` |

## Procedure

### 1. Discover Profiles and Regions

List all configured AWS CLI profiles:

```bash
aws configure list-profiles
```

Validate each profile with STS before proceeding:

```bash
aws sts get-caller-identity --profile <profile-name>
```

Get the list of enabled regions for the account:

```bash
aws ec2 describe-regions \
  --profile <profile-name> \
  --query "Regions[].RegionName" \
  --output json
```

### 2. Try MCP First

If the MCP `aws-finops` server is available, call it first for a consolidated report:

```
run_finops_audit
```

If MCP is not available or returns an error, proceed with the CLI checks below.

### 3. CLI Waste Checks (per profile, per region)

Run the following checks for each combination of `--profile` and `--region`.

#### Stopped EC2 Instances

```bash
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=stopped" \
  --query "Reservations[].Instances[].{InstanceId:InstanceId,InstanceType:InstanceType,State:State.Name,Name:Tags[?Key=='Name']|[0].Value,LaunchTime:LaunchTime}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Flag any instance stopped for more than 7 days as potential waste.

#### Orphaned EBS Volumes (status=available)

```bash
aws ec2 describe-volumes \
  --filters "Name=status,Values=available" \
  --query "Volumes[].{VolumeId:VolumeId,SizeGiB:Size,VolumeType:VolumeType,CreateTime:CreateTime,AvailabilityZone:AvailabilityZone}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Any volume in `available` state is unattached and accumulating storage charges.

#### Unassociated Elastic IPs (AssociationId == null)

```bash
aws ec2 describe-addresses \
  --query "Addresses[?AssociationId==null].{AllocationId:AllocationId,PublicIp:PublicIp,Domain:Domain}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Each unassociated EIP costs approximately $3.60/month.

#### Idle RDS Instances

List all RDS instances:

```bash
aws rds describe-db-instances \
  --query "DBInstances[].{DBInstanceIdentifier:DBInstanceIdentifier,DBInstanceClass:DBInstanceClass,Engine:Engine,DBInstanceStatus:DBInstanceStatus,MultiAZ:MultiAZ}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

For each instance, check `DatabaseConnections` over the last 7 days:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/RDS \
  --metric-name DatabaseConnections \
  --dimensions Name=DBInstanceIdentifier,Value=<db-instance-id> \
  --start-time $(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Average \
  --query "Datapoints[].Average" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Flag any instance where the average `DatabaseConnections` is less than 1 over the 7-day window.

#### Unused Elastic Load Balancers

List all load balancers:

```bash
aws elbv2 describe-load-balancers \
  --query "LoadBalancers[].{LoadBalancerArn:LoadBalancerArn,LoadBalancerName:LoadBalancerName,Type:Type,State:State.Code,CreatedTime:CreatedTime}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

List target groups for each load balancer:

```bash
aws elbv2 describe-target-groups \
  --load-balancer-arn <load-balancer-arn> \
  --query "TargetGroups[].TargetGroupArn" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Check target health for each target group:

```bash
aws elbv2 describe-target-health \
  --target-group-arn <target-group-arn> \
  --query "TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Flag load balancers with no registered targets or all targets in `unused` or `draining` state.

#### NAT Gateways (state=available)

```bash
aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query "NatGateways[].{NatGatewayId:NatGatewayId,VpcId:VpcId,SubnetId:SubnetId,State:State,CreateTime:CreateTime}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Each NAT Gateway costs approximately $32/month minimum (hourly charge + data processing). Flag any that appear unused based on low traffic patterns.

#### Unused Security Groups

List all non-default security groups:

```bash
aws ec2 describe-security-groups \
  --query "SecurityGroups[?GroupName!='default'].{GroupId:GroupId,GroupName:GroupName,Description:Description,VpcId:VpcId}" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

List all security groups currently attached to network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --query "NetworkInterfaces[].Groups[].GroupId" \
  --profile <profile-name> \
  --region <region> \
  --output json
```

Cross-reference the two lists. Any non-default security group not appearing in the network interfaces list is unused.

### 4. Output Format

Structure findings as JSON per profile with the following schema:

```json
{
  "profile": "<profile-name>",
  "account_id": "<account-id>",
  "audit_date": "<ISO-8601-date>",
  "regions_scanned": ["us-east-1", "us-west-2"],
  "findings": {
    "stopped_ec2": [],
    "orphaned_ebs": [],
    "unassociated_eips": [],
    "idle_rds": [],
    "unused_elbs": [],
    "nat_gateways": [],
    "unused_security_groups": []
  },
  "estimated_monthly_waste": {
    "eip_usd": 0.0,
    "nat_gateway_usd": 0.0,
    "total_confirmed_usd": 0.0,
    "notes": "EC2/RDS/ELB costs require instance type pricing lookup — do not guess"
  }
}
```

## Pitfalls

1. **Never guess instance costs.** EC2, RDS, and ELB pricing varies by instance type, region, reserved vs on-demand, and OS. Only report confirmed per-unit costs (EIP, NAT Gateway) and note that compute costs require a separate pricing lookup.
2. **CloudWatch requires at least 7 days of data.** For newly created or recently restarted instances, `DatabaseConnections` metrics may not be available or may not reflect typical usage patterns.
3. **Trusted Advisor requires Business or Enterprise support plan.** If the account is on Basic or Developer support, Trusted Advisor cost optimization checks will not be accessible — rely on the CLI checks above instead.
4. **Some regions may be disabled.** Calls to disabled regions will return an `AuthorizationError`. Skip those regions and note them in the output rather than treating them as failures.
5. **Unassociated EIPs cost $3.60/month each.** This is a confirmed, predictable cost that should always be reported with a dollar figure.
6. **NAT Gateways cost approximately $32/month minimum.** The $0.045/hour charge applies regardless of traffic. Data processing charges add to this. Flag all available NAT Gateways for human review — do not attempt to determine usage from CLI alone without CloudWatch data.
