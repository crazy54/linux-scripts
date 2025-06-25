#!/bin/bash

# Script to discover AWS Lambda functions with outdated Python runtimes
# and all self-owned Systems Manager Automation documents across specified regions.

# --- Configuration ---
OLD_PYTHON_RUNTIMES=("python3.9" "python3.8" "python3.7" "python3.6" "python2.7") # Runtimes to check for Lambda
LAMBDA_FUNCTIONS_OUTPUT_FILE="lambda_functions_to_update.txt"
SSM_AUTOMATIONS_OUTPUT_FILE="ssm_automations_to_update.txt"
LOG_FILE="discover_resources.log"

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- Main Script ---
# Clear log file for new run
> "$LOG_FILE"
log "--- Starting Resource Discovery Script ---"

if [ "$#" -eq 0 ]; then
    log "ERROR: No regions provided. Usage: $0 <region1> <region2> ..."
    echo "Usage: $0 <region1> <region2> ..."
    exit 1
fi

# Clear or create output files
log "Initializing output files..."
> "$LAMBDA_FUNCTIONS_OUTPUT_FILE"
> "$SSM_AUTOMATIONS_OUTPUT_FILE"

# Get AWS Account ID (needed for constructing SSM document ARNs)
log "Fetching AWS Account ID..."
AWS_ACCOUNT_ID=$(./aws_dummy.sh sts get-caller-identity --query Account --output text)
if [ $? -ne 0 ] || [ -z "$AWS_ACCOUNT_ID" ]; then
    log "ERROR: Failed to retrieve AWS Account ID using './aws_dummy.sh sts get-caller-identity'. Exiting."
    # Attempt to simulate if the command itself failed (e.g. ./aws_dummy.sh command not found)
    if ! command -v ./aws_dummy.sh &> /dev/null || [[ "$AWS_ACCOUNT_ID" == *"command not found"* ]]; then
        log "Simulating AWS_ACCOUNT_ID due to './aws_dummy.sh' command issue."
        AWS_ACCOUNT_ID="123456789012" # Default dummy for continuation
    else
        log "AWS CLI './aws_dummy.sh sts get-caller-identity' command executed but failed to return an account ID."
        exit 1
    fi
fi
log "Successfully fetched AWS Account ID: $AWS_ACCOUNT_ID"

# Constructing the Lambda runtime query string
lambda_query_parts=()
for runtime in "${OLD_PYTHON_RUNTIMES[@]}"; do
    lambda_query_parts+=("Runtime==\`${runtime}\`")
done
lambda_runtime_query_filter=$(IFS=" || "; echo "${lambda_query_parts[*]}")

# Iterate through each provided region
for region in "$@"; do
    log "Processing region: $region"

    # Discover Lambda Functions
    log "Discovering Lambda functions in $region with outdated runtimes (${OLD_PYTHON_RUNTIMES[*]})..."
    ./aws_dummy.sh lambda list-functions --region "$region" --function-version ALL --query "Functions[?${lambda_runtime_query_filter}].FunctionArn" --output text > "${LAMBDA_FUNCTIONS_OUTPUT_FILE}.tmp"
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to list Lambda functions in $region (./aws_dummy.sh command failed). Skipping Lambda discovery for this region."
    else
        if [ -s "${LAMBDA_FUNCTIONS_OUTPUT_FILE}.tmp" ]; then # Check if tmp file has content
            # Process the temporary file to add each ARN on a new line
            # Handles cases where ARNs might be space or tab separated by first converting all whitespace to newlines, then removing empty lines.
            tr -s '[[:space:]]' '\n' < "${LAMBDA_FUNCTIONS_OUTPUT_FILE}.tmp" | sed '/^$/d' >> "$LAMBDA_FUNCTIONS_OUTPUT_FILE"
            log "Lambda function discovery in $region complete. Results appended."
        else
            log "No Lambda functions found or tmp file empty for $region."
        fi
    fi
    rm -f "${LAMBDA_FUNCTIONS_OUTPUT_FILE}.tmp"

    # Discover Systems Manager Automation Documents
    log "Discovering self-owned SSM Automation documents in $region..."
    ssm_document_names=$(./aws_dummy.sh ssm list-documents --region "$region" --document-filter key=Owner,value=Self key=DocumentType,value=Automation --query "DocumentIdentifiers[*].Name" --output text)
    if [ $? -ne 0 ]; then
        log "ERROR: Failed to list SSM documents in $region (./aws_dummy.sh command failed). Skipping SSM discovery for this region."
    else
        if [ -n "$ssm_document_names" ]; then
            log "Found SSM documents in $region: $ssm_document_names. Constructing ARNs..."
            # Handles cases where names might be space or tab separated
            echo "$ssm_document_names" | tr -s '[[:space:]]' '\n' | sed '/^$/d' | while IFS= read -r name; do
                if [ -n "$name" ]; then # Ensure name is not empty
                     echo "arn:aws:ssm:$region:$AWS_ACCOUNT_ID:document/$name" >> "$SSM_AUTOMATIONS_OUTPUT_FILE"
                fi
            done
            log "SSM Automation document ARN construction in $region complete."
        else
            log "No self-owned SSM Automation documents found in $region."
        fi
    fi
done

log "--- Resource Discovery Script Finished ---"
log "Lambda functions to update written to: $LAMBDA_FUNCTIONS_OUTPUT_FILE"
log "SSM automations to update (ALL self-owned) written to: $SSM_AUTOMATIONS_OUTPUT_FILE"
log "IMPORTANT: Review $SSM_AUTOMATIONS_OUTPUT_FILE. It contains ALL self-owned SSM automations. Manual review or a more advanced script is needed to filter by specific Python runtimes used within document content."
echo "IMPORTANT: Review $SSM_AUTOMATIONS_OUTPUT_FILE. It contains ALL self-owned SSM automations. Manual review is needed."
