#!/bin/bash

## Test for the logging system.

function test_logging {
  local image="${1:?}"
  local environment="${2:-}"

  [[ -n "$environment" ]] && environment="--env $environment"

  docker run --rm \
    $environment \
    "$image" \
    bash -c 'source /app/functions.sh; \
            log --error "this is an error message." 2>&1; \
            log --warning "this is a warning message."; \
            log --info "this is an info message."; \
            log --debug "this is a debug message."' \
    | cut -d ' ' -f3- 2>&1
}

values=( \
  [0]="LOG_LEVEL=1" \
  [1]="LOG_LEVEL=error" \
  [2]="LOG_LEVEL=Error" \
  [3]="LOG_LEVEL=2" \
  [4]="LOG_LEVEL=warning" \
  [5]="LOG_LEVEL=Warning" \
  [6]="LOG_LEVEL=3" \
  [7]="LOG_LEVEL=info" \
  [8]="LOG_LEVEL=Info" \
  [9]="LOG_LEVEL=4" \
  [10]="LOG_LEVEL=debug" \
  [11]="LOG_LEVEL=Debug" \
  [12]="DEBUG=true" \
  [13]="DEBUG=True" \
  [14]="LOG_LEVEL=incorrect_value" \
  )

for value in "${values[@]}"; do
  echo $value
  test_logging "$1" "$value"
done

echo "no environment variable"
test_logging "$1"
