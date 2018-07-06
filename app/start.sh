#!/bin/bash

# SIGTERM-handler
term_handler() {
    [[ -n "$docker_gen_pid" ]] && kill $docker_gen_pid
    [[ -n "$crond_pid" ]] && kill $crond_pid

    source /app/functions.sh
    remove_all_location_configurations

    exit 0
}

trap 'term_handler' INT QUIT TERM

docker-gen -watch \
  -wait 5s:10s \
  -notify "/app/letsencrypt_service" \
  -notify-output \
  /app/letsencrypt_service_data.tmpl /app/letsencrypt_service_data &
docker_gen_pid=$!

crond -f -d 8 > /dev/stdout 2> /dev/stderr &
crond_pid=$!

# wait "indefinitely"
while [[ -e /proc/$docker_gen_pid ]]; do
    wait $docker_gen_pid # Wait for any signals or end of execution of docker-gen
done

# Stop container properly
term_handler
