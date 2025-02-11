#!/bin/bash

# Set error handling
set -euo pipefail

# Function to parse CloudFormation template and extract metadata
parse_template() {
    local template_file=$1
    
    # Convert YAML to JSON using cfn-flip
    JSON_OUTPUT=$(cfn-flip "$template_file")

    # Extract stack name suffix from metadata
    STACK_NAME_SUFFIX=$(echo "$JSON_OUTPUT" | jq -r '.Metadata.StackNameSuffix')
    STACK_BASE_NAME=$(echo "$JSON_OUTPUT" | jq -r '.Metadata.Name')
}

# Function to get parameters from template and create parameter input
get_parameters() {
    local template_file=$1
    local environment=$2

    # Convert YAML to JSON using cfn-flip
    JSON_OUTPUT=$(cfn-flip "$template_file")

    # Extract Parameters as JSON
    PARAMETERS=$(echo "$JSON_OUTPUT" | jq -c '.Parameters')

    # Initialize Buildkite pipeline YAML with title and parameter input step
    PIPELINE_YAML="steps:\n  - input:\n      title: \"Configure Stack Parameters\"\n      fields:"

    # Loop through parameters and generate fields based on Type
    FIELDS=$(echo "$PARAMETERS" | jq -r '
    to_entries[] | 
    if .value | has("AllowedValues") then
        # If AllowedValues exist, generate a dropdown
        "        - select: \"\(.value.Description)\"\n          key: \(.key)\n          default: \(.value.Default)\n          options:\n" + 
        ( .value.AllowedValues | map("            - label: \"\(.)\"\n              value: \"\(.)\"") | join("\n") )
    else
        # Otherwise, generate a text input
        "        - text: \"\(.value.Description)\"\n          key: \(.key)\n          default: \(.value.Default)"
    end
    ')

    # Add CloudFormation changeset creation and execution steps
    PIPELINE_YAML="$PIPELINE_YAML\n\n  - command: |\n      # Create CloudFormation changeset
      aws cloudformation create-change-set \
        --stack-name \"\${STACK_NAME}\" \
        --change-set-name \"changeset-\${BUILDKITE_BUILD_NUMBER}\" \
        --template-body file://template.yaml \
        --parameters \$PARAMETERS \
        --capabilities CAPABILITY_IAM
      
      # Wait for changeset creation
      aws cloudformation wait change-set-create-complete \
        --stack-name \"\${STACK_NAME}\" \
        --change-set-name \"changeset-\${BUILDKITE_BUILD_NUMBER}\"
      
      # Display changeset
      aws cloudformation describe-change-set \
        --stack-name \"\${STACK_NAME}\" \
        --change-set-name \"changeset-\${BUILDKITE_BUILD_NUMBER}\" \
        --output table
    
  - block: \"Review Changes\"
    prompt: \"Review the CloudFormation changes above and click 'Continue' to proceed with deployment\"

  - command: |\n      # Execute CloudFormation changeset
      aws cloudformation execute-change-set \
        --stack-name \"\${STACK_NAME}\" \
        --change-set-name \"changeset-\${BUILDKITE_BUILD_NUMBER}\"
      
      # Wait for stack update/creation to complete
      aws cloudformation wait stack-update-complete \
        --stack-name \"\${STACK_NAME}\" || \
      aws cloudformation wait stack-create-complete \
        --stack-name \"\${STACK_NAME}\""

    # Concatenate the generated fields into the pipeline
    PIPELINE_YAML="$PIPELINE_YAML\n$FIELDS"
    
    # Create temporary pipeline file
    TEMP_PIPELINE_FILE="/tmp/pipeline-${BUILDKITE_BUILD_ID}.yml"
    echo -e "$PIPELINE_YAML" > "$TEMP_PIPELINE_FILE"

    cat "$TEMP_PIPELINE_FILE"
    
    # Upload the pipeline from temp file
    buildkite-agent pipeline upload "$TEMP_PIPELINE_FILE"
    
    # Clean up temp file
    rm -f "$TEMP_PIPELINE_FILE"
    
    # # Get all parameters and their default values using yq
    # parameters=$(echo "$JSON_OUTPUT" | jq -r '.Parameters | to_entries[] | select(.value.Type != null)')
    
    # # Initialize parameter list
    # parameter_list=""
    
    # while IFS= read -r param; do
    #     param_name=$(echo "$param" | jq -r '.key')
    #     default_value=$(echo "$param" | jq -r '.value.Default // empty')
        
    #     # If parameter is Environment, use the provided environment
    #     if [ "$param_name" == "Environment" ]; then
    #         parameter_list+="ParameterKey=Environment,ParameterValue=$environment "
    #     elif [ -n "$default_value" ]; then
    #         parameter_list+="ParameterKey=$param_name,ParameterValue=$default_value "
    #     fi
    # done <<< "$parameters"
    
    # echo "$parameter_list"
}

# Function to check if stack exists
check_stack_exists() {
    local stack_name=$1
    local region=$2
    
    if aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Main execution
main() {
    # Required environment variables
    if [ -z "${BUILDKITE_PIPELINE_SLUG:-}" ]; then
        echo "Error: BUILDKITE_PIPELINE_SLUG is not set"
        exit 1
    fi

    # Set variables
    ENVIRONMENT=${1:-staging}  # Default to staging if not provided
    AWS_REGION=${2:-us-east-1}  # Default to us-east-1 if not provided
    TEMPLATE_FILE=${3:-template.yaml}  # Default to template.yaml if not provided
    
    # Parse template
    parse_template "$TEMPLATE_FILE"
    
    # Generate stack name
    STACK_NAME="${ENVIRONMENT}${STACK_NAME_SUFFIX}"
    
    # Get parameters
    PARAMETERS=$(get_parameters "$TEMPLATE_FILE" "$ENVIRONMENT")

    # Create change set name with timestamp
    CHANGE_SET_NAME="changeset-${BUILDKITE_PIPELINE_SLUG}-$(date +%Y%m%d-%H%M%S)"

    
    # # Check if stack exists and create appropriate change set
    # if check_stack_exists "$STACK_NAME" "$AWS_REGION"; then
    #     echo "Stack exists, creating update change set..."
    #     aws cloudformation create-change-set \
    #         --stack-name "$STACK_NAME" \
    #         --change-set-name "$CHANGE_SET_NAME" \
    #         --template-body "file://$TEMPLATE_FILE" \
    #         --parameters $PARAMETERS \
    #         --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    #         --region "$AWS_REGION"
    # else
    #     echo "Stack does not exist, creating creation change set..."
    #     aws cloudformation create-change-set \
    #         --stack-name "$STACK_NAME" \
    #         --change-set-name "$CHANGE_SET_NAME" \
    #         --change-set-type CREATE \
    #         --template-body "file://$TEMPLATE_FILE" \
    #         --parameters $PARAMETERS \
    #         --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
    #         --region "$AWS_REGION"
    # fi
    
    # # Wait for change set creation
    # aws cloudformation wait change-set-create-complete \
    #     --stack-name "$STACK_NAME" \
    #     --change-set-name "$CHANGE_SET_NAME" \
    #     --region "$AWS_REGION"
    
    # # Describe change set
    # aws cloudformation describe-change-set \
    #     --stack-name "$STACK_NAME" \
    #     --change-set-name "$CHANGE_SET_NAME" \
    #     --region "$AWS_REGION"
}

# Execute main function with provided arguments
main "$@"