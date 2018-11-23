#!/bin/bash

## Test for DH parameters generation

if [[ -z $TRAVIS_CI ]]; then
  le_container_name="$(basename ${0%/*})_$(date "+%Y-%m-%d_%H.%M.%S")"
else
  le_container_name="$(basename ${0%/*})"
fi

# Create the $domains array from comma separated domains in TEST_DOMAINS.
IFS=',' read -r -a domains <<< "$TEST_DOMAINS"

function get_file_hash {
  local file="${1:?}"
  docker exec "$le_container_name" sha512sum "$file" | cut -d ' ' -f 1
}

# Cleanup function with EXIT trap
function cleanup {
  # Stop the LE container
  docker stop "$le_container_name" > /dev/null
}
trap cleanup EXIT

docker exec $NGINX_CONTAINER_NAME rm -f /etc/nginx/certs/dhparam.pem

if [[ "$SETUP" == '3containers' ]]; then
  cli_args+=" --env NGINX_DOCKER_GEN_CONTAINER=$DOCKER_GEN_CONTAINER_NAME"
fi
docker run -d \
  --name "$le_container_name" \
  --volumes-from $NGINX_CONTAINER_NAME \
  --volume /var/run/docker.sock:/var/run/docker.sock:ro \
  $cli_args \
  --env "DHPARAM_BITS=1024" \
  --env "DEBUG=true" \
  --env "ACME_CA_URI=http://boulder:4000/directory" \
  --label com.github.jrcs.letsencrypt_nginx_proxy_companion.test_suite \
  --network boulder_bluenet \
  "${1:?}" > /dev/null

default_dhparam_hash="$(get_file_hash '/app/dhparam.pem.default')"

docker run --rm -d \
  --name "${domains[0]}" \
  -e "VIRTUAL_HOST=${domains[0]}" \
  -e "LETSENCRYPT_HOST=${domains[0]}" \
  --network boulder_bluenet \
  nginx:alpine > /dev/null

# Wait for a connection to https://${domain[0]}
wait_for_conn --domain "${domains[0]}"

echo | openssl s_client -connect "${domains[0]}":443 -cipher kEDH 2>/dev/null | grep 'Server Temp Key'

i=0
until [[ $(docker exec $NGINX_CONTAINER_NAME -f '/etc/nginx/certs/dhparam.pem') ]] && [[ "$(get_file_hash '/etc/nginx/certs/dhparam.pem')" != "$default_dhparam_hash" ]]; do
  if [[ $i -gt 300 ]]; then
    echo 'The non default DH parameters file was not generated under five minutes, timing out.'
    exit 1
  fi
  sleep 2
  i=$((i + 2))
done

docker exec "$le_container_name" openssl dhparam -in /etc/nginx/certs/dhparam.pem -noout -text | grep -q '1024' \
  || echo 'The DH parameters file was not generated with the requested size.'

echo | openssl s_client -connect "${domains[0]}":443 -cipher kEDH 2>/dev/null | grep 'Server Temp Key'
