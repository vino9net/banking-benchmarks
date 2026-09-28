#!/usr/bin/env bash
# One IAM role + instance profile, shared by both VMs (the task requires the bench VM
# use the same role as the sim VM). Grants exactly what the two VMs need at runtime:
#
#   - DynamoDB read/write on account-inquiry's AccountsTable — used by
#     scripts/seed_from_redis.py (run FROM the sim VM in 06_reseed_dynamodb.sh) to wipe
#     and reseed it from Redis.
#   - appsync:GraphQL on account-inquiry's API — AppSync's IAM auth checks the
#     *caller's* identity policy, not a resource policy on the API itself
#     (account-inquiry/stack.py's grant_query() docstring explains why), so this is the
#     only way a load generator on the bench VM can query it.
#   - cloudformation:DescribeStacks on that one stack — both seed_from_redis.py and
#     query_appsync.py resolve the table name / API URL this way by default.
#   - kinesis:PutRecords on account-inquiry's "transfers" stream — core-sim-relay's only
#     Kinesis call (core-sim/src/core_sim/relay.py) is put_records(); the sim VM needs
#     this to publish transfers at all. Found missing by actually running the relay
#     against a live stream — it fails with AccessDeniedException without it.
#   - cloudwatch:PutMetricData, scoped by namespace condition rather than Resource
#     (CloudWatch metrics aren't ARN-addressable, so Resource is always "*" for this
#     action) — dynamodb-ingestion/core_sim_tps.py needs this from the bench VM to
#     publish its write-side TPS metric. Also found missing by actually running it on
#     the VM, not just locally under a broad-permission dev profile.
#
# Idempotent: safe to re-run.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

stack_arn="$(awsc cloudformation describe-stacks --stack-name "$ACCOUNT_INQUIRY_STACK" \
    --query 'Stacks[0].StackId' --output text)"
table_name="$(awsc cloudformation describe-stacks --stack-name "$ACCOUNT_INQUIRY_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='AccountsTableName'].OutputValue" --output text)"
table_arn="$(awsc dynamodb describe-table --table-name "$table_name" --query 'Table.TableArn' --output text)"

api_id="$(awsc appsync list-graphql-apis \
    --query "graphqlApis[?authenticationType=='AWS_IAM' && contains(name,'account-inquiry')].apiId | [0]" \
    --output text)"
[ -n "$api_id" ] && [ "$api_id" != "None" ] || die "couldn't find account-inquiry's AWS_IAM AppSync API — check ACCOUNT_INQUIRY_STACK/region"
account_id="$(awsc sts get-caller-identity --query Account --output text)"
api_arn="arn:aws:appsync:${AWS_REGION}:${account_id}:apis/${api_id}"

stream_name="$(awsc cloudformation describe-stacks --stack-name "$ACCOUNT_INQUIRY_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='TransfersStreamName'].OutputValue" --output text)"
stream_arn="arn:aws:kinesis:${AWS_REGION}:${account_id}:stream/${stream_name}"

info "table: $table_arn"
info "appsync api: $api_arn"
info "stack: $stack_arn"
info "kinesis stream: $stream_arn"

trust_policy=$(cat <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Principal": {"Service": "ec2.amazonaws.com"}, "Action": "sts:AssumeRole"}]
}
JSON
)

if ! awsc iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
    info "creating IAM role $IAM_ROLE_NAME"
    awsc iam create-role --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "$trust_policy" \
        --tags "Key=Project,Value=banking-benchmarks" >/dev/null
else
    info "reusing existing IAM role $IAM_ROLE_NAME"
fi

policy_doc=$(cat <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AccountsTableReadWrite",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem",
        "dynamodb:Query", "dynamodb:Scan",
        "dynamodb:BatchGetItem", "dynamodb:BatchWriteItem",
        "dynamodb:DescribeTable"
      ],
      "Resource": ["${table_arn}", "${table_arn}/index/*"]
    },
    {
      "Sid": "AppSyncQuery",
      "Effect": "Allow",
      "Action": "appsync:GraphQL",
      "Resource": "${api_arn}/*"
    },
    {
      "Sid": "ResolveStackOutputs",
      "Effect": "Allow",
      "Action": "cloudformation:DescribeStacks",
      "Resource": "${stack_arn}"
    },
    {
      "Sid": "PublishTransfers",
      "Effect": "Allow",
      "Action": "kinesis:PutRecords",
      "Resource": "${stream_arn}"
    },
    {
      "Sid": "PublishBenchmarkMetrics",
      "Effect": "Allow",
      "Action": "cloudwatch:PutMetricData",
      "Resource": "*",
      "Condition": {
        "StringEquals": {"cloudwatch:namespace": "DynamoDBIngestionBench"}
      }
    }
  ]
}
JSON
)

awsc iam put-role-policy --role-name "$IAM_ROLE_NAME" \
    --policy-name "banking-benchmarks-access" \
    --policy-document "$policy_doc"

if ! awsc iam get-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
    info "creating instance profile $IAM_INSTANCE_PROFILE_NAME"
    awsc iam create-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" >/dev/null
    awsc iam add-role-to-instance-profile \
        --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
    info "waiting for instance profile to propagate ..."
    sleep 10
else
    info "reusing existing instance profile $IAM_INSTANCE_PROFILE_NAME"
fi

state_set IAM_ROLE_NAME "$IAM_ROLE_NAME"
state_set IAM_INSTANCE_PROFILE_NAME "$IAM_INSTANCE_PROFILE_NAME"
info "IAM role + instance profile ready"
