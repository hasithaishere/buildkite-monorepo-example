#!/bin/bash

# Set error handling
set -euo pipefail

# Function to parse CloudFormation template and extract metadata
parse_template() {
    local template_file=$1
    # Extract stack name suffix from metadata
    STACK_NAME_SUFFIX=$(yq e '.Metadata.StackNameSuffix' "$template_file")
    STACK_BASE_NAME=$(yq e '.Metadata.Name' "$template_file")
}

# Function to get parameters from template and create parameter input
get_parameters() {
    local template_file=$1
    local environment=$2
    
    # Get all parameters and their default values using yq
    parameters=$(yq e '.Parameters | to_entries | .[] | select(.value.Type != null)' "$template_file")
    
    # Initialize parameter list
    parameter_list=""
    
    while IFS= read -r param; do
        param_name=$(echo "$param" | yq e '.key' -)
        default_value=$(echo "$param" | yq e '.value.Default // ""' -)
        
        # If parameter is Environment, use the provided environment
        if [ "$param_name" == "Environment" ]; then
            parameter_list+="ParameterKey=Environment,ParameterValue=$environment "
        elif [ -n "$default_value" ]; then
            parameter_list+="ParameterKey=$param_name,ParameterValue=$default_value "
        fi
    done <<< "$parameters"
    
    echo "$parameter_list"
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
    TEMPLATE_FILE="cloudformation.yaml"
    ENVIRONMENT=${1:-staging}  # Default to staging if not provided
    AWS_REGION=${2:-us-east-1}  # Default to us-east-1 if not provided
    
    # Parse template
    parse_template "$TEMPLATE_FILE"
    
    # Generate stack name
    STACK_NAME="${STACK_BASE_NAME}-${ENVIRONMENT}${STACK_NAME_SUFFIX}"
    
    echo "Generated Stack Name: $STACK_NAME"
    echo "AWS Region: $AWS_REGION"
    echo "Environment: $ENVIRONMENT"
    
    # Get parameters
    PARAMETERS=$(get_parameters "$TEMPLATE_FILE" "$ENVIRONMENT")
    echo "Parameters: $PARAMETERS"
    
    # Create change set name with timestamp
    CHANGE_SET_NAME="changeset-${BUILDKITE_PIPELINE_SLUG}-$(date +%Y%m%d-%H%M%S)"
    
    # Check if stack exists and create appropriate change set
    if check_stack_exists "$STACK_NAME" "$AWS_REGION"; then
        echo "Stack exists, creating update change set..."
        aws cloudformation create-change-set \
            --stack-name "$STACK_NAME" \
            --change-set-name "$CHANGE_SET_NAME" \
            --template-body "file://$TEMPLATE_FILE" \
            --parameters $PARAMETERS \
            --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
            --region "$AWS_REGION"
    else
        echo "Stack does not exist, creating creation change set..."
        aws cloudformation create-change-set \
            --stack-name "$STACK_NAME" \
            --change-set-name "$CHANGE_SET_NAME" \
            --change-set-type CREATE \
            --template-body "file://$TEMPLATE_FILE" \
            --parameters $PARAMETERS \
            --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
            --region "$AWS_REGION"
    fi
    
    # Wait for change set creation
    aws cloudformation wait change-set-create-complete \
        --stack-name "$STACK_NAME" \
        --change-set-name "$CHANGE_SET_NAME" \
        --region "$AWS_REGION"
    
    # Describe change set
    aws cloudformation describe-change-set \
        --stack-name "$STACK_NAME" \
        --change-set-name "$CHANGE_SET_NAME" \
        --region "$AWS_REGION"
}

# Execute main function with provided arguments
main "$@"