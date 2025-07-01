#!/bin/bash

# Script to upgrade AWS Lambda and Systems Manager Automation Python runtimes

# --- Configuration ---
TARGET_PYTHON_RUNTIME="python3.10"
LAMBDA_FUNCTIONS_INPUT_FILE="lambda_functions_to_update.txt"
# Input file for SSM automations - now expects the filtered list
SSM_AUTOMATIONS_INPUT_FILE="ssm_automations_filtered.txt"
LOG_FILE="upgrade_runtimes.log"

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# --- Helper function to extract region from ARN ---
extract_region_from_arn() {
    echo "$1" | cut -d':' -f4
}

# --- Helper function to extract resource name from Lambda ARN ---
extract_lambda_name_from_arn() {
    echo "$1" | cut -d':' -f7
}

# --- Helper function to extract resource name from SSM Document ARN ---
extract_ssm_name_from_arn() {
    echo "$1" | cut -d'/' -f2
}

# --- Lambda Functions ---
update_lambda_functions() {
    log "Starting Lambda function runtime updates from $LAMBDA_FUNCTIONS_INPUT_FILE..."
    if [ ! -s "$LAMBDA_FUNCTIONS_INPUT_FILE" ]; then
        log "INFO: $LAMBDA_FUNCTIONS_INPUT_FILE is empty or does not exist. No Lambda functions to update."
        log "Ensure $LAMBDA_FUNCTIONS_INPUT_FILE is populated by discover_resources.sh"
        return
    fi

    while IFS= read -r lambda_arn; do
        if [ -z "$lambda_arn" ]; then continue; fi

        local region
        local function_name
        region=$(extract_region_from_arn "$lambda_arn")
        function_name=$(extract_lambda_name_from_arn "$lambda_arn")

        if [ -z "$region" ] || [ -z "$function_name" ]; then
            log "ERROR: Could not parse ARN: $lambda_arn. Skipping."
            continue
        fi

        log "Updating runtime for Lambda function: $function_name in region: $region to $TARGET_PYTHON_RUNTIME"
        # SIMULATION: aws lambda update-function-configuration --function-name "$function_name" --runtime "$TARGET_PYTHON_RUNTIME" --region "$region"
        echo "SIMULATING: aws lambda update-function-configuration --function-name "$function_name" --runtime "$TARGET_PYTHON_RUNTIME" --region "$region"" >> "$LOG_FILE"
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            log "Successfully (simulated) updated Lambda function $function_name in $region to $TARGET_PYTHON_RUNTIME"
        else
            log "ERROR: Failed to (simulated) update Lambda function $function_name in $region"
        fi
    done < "$LAMBDA_FUNCTIONS_INPUT_FILE"
    log "Lambda function runtime updates complete."
}

# --- Systems Manager Automations ---
update_ssm_automations() {
    log "Starting Systems Manager Automation runtime updates from $SSM_AUTOMATIONS_INPUT_FILE..."
    log "INFO: This script expects $SSM_AUTOMATIONS_INPUT_FILE to be the filtered list from filter_ssm_documents.py"

    if [ ! -s "$SSM_AUTOMATIONS_INPUT_FILE" ]; then
        log "INFO: $SSM_AUTOMATIONS_INPUT_FILE is empty or does not exist. No SSM automations to update."
        return
    fi

    while IFS= read -r ssm_arn; do
        if [ -z "$ssm_arn" ]; then continue; fi

        local region
        local document_name
        region=$(extract_region_from_arn "$ssm_arn")
        document_name=$(extract_ssm_name_from_arn "$ssm_arn")

        if [ -z "$region" ] || [ -z "$document_name" ]; then
            log "ERROR: Could not parse ARN: $ssm_arn. Skipping."
            continue
        fi

        log "Simulating update for SSM Automation document: $document_name in region $region to $TARGET_PYTHON_RUNTIME"

        TEMP_DOC_CONTENT_FILE="${document_name}_${region}_content_sim.json"
        # The following line was SIMULATING: aws ssm get-document ... in the request, but to match the style of the Lambda sim, it should be echo ... >> LOG_FILE
        echo "  SIMULATING: aws ssm get-document --name \"$document_name\" --region \"$region\" --query 'Content' --output text > $TEMP_DOC_CONTENT_FILE" >> "$LOG_FILE"
        cat <<EOD > "$TEMP_DOC_CONTENT_FILE"
{
  "description": "Simulated document content for $document_name in $region",
  "schemaVersion": "0.3",
  "assumeRole": "arn:aws:iam::123456789012:role/AutomationAssumeRole",
  "mainSteps": [
    {
      "name": "executePython",
      "action": "aws:executeScript",
      "inputs": {
        "Runtime": "python3.8", # This runtime would have been identified by filter_ssm_documents.py
        "Script": "print('Hello from old Python in SSM')"
      }
    }
  ]
}
EOD
        sed -i 's/"Runtime": "python3.8"/"Runtime": "'"$TARGET_PYTHON_RUNTIME"'"/' "$TEMP_DOC_CONTENT_FILE" # Simplified simulation

        # The following line was SIMULATING: aws ssm update-document ... in the request, but to match the style of the Lambda sim, it should be echo ... >> LOG_FILE
        echo "  SIMULATING: aws ssm update-document --name \"$document_name\" --content file://$TEMP_DOC_CONTENT_FILE --document-version \$LATEST --region \"$region\"" >> "$LOG_FILE"
        local exit_code=$?

        if [ $exit_code -eq 0 ]; then
            log "  Successfully SIMULATED update for SSM Automation $document_name in $region to $TARGET_PYTHON_RUNTIME"
        else
            log "  ERROR: Failed to SIMULATE update for SSM Automation $document_name in $region"
        fi
        rm "$TEMP_DOC_CONTENT_FILE"
    done < "$SSM_AUTOMATIONS_INPUT_FILE"
    log "Systems Manager Automation runtime updates complete (simulation)."
}

# --- Main Execution ---
log "--- Starting Python Runtime Upgrade Script (ARN-aware) ---"
log "This script expects input files to be populated by:"
log "  - discover_resources.sh (for $LAMBDA_FUNCTIONS_INPUT_FILE)"
log "  - filter_ssm_documents.py (for $SSM_AUTOMATIONS_INPUT_FILE)"

update_lambda_functions
update_ssm_automations

log "--- Python Runtime Upgrade Script Finished ---"
