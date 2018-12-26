#!/bin/bash

## Test for the Docker API.

# Cleanup function with EXIT trap
function cleanup {
  # Kill the Docker events listener
  kill $docker_events_pid && wait $docker_events_pid 2>/dev/null
  # Remove the remaining containers silently
  for cid in $(docker ps -a --filter "label=docker_api_test_suite" --format "{{.ID}}"); do
    docker stop "$cid" > /dev/null 2>&1
  done
}
trap cleanup EXIT

nginx_vol='nginx-volumes-from'
nginx_env='nginx-env-var'
nginx_lbl='nginx-label'
docker_gen='docker-gen-no-label'
docker_gen_lbl='docker-gen-label'

function run_le_companion {
  local nginx_proxy_env=""
  local docker_gen_env=""
  local get_docker_gen_cmd=""

  while [[ $# -gt 0 ]]; do
  local flag="$1"
    case $flag in
      --nginx-proxy-names)
      nginx_proxy_env="${2:?}"
      shift
      shift
      ;;

      --docker-gen-names)
      docker_gen_env="${2:?}"
      get_docker_gen_cmd="get_docker_gen_container;"
      shift
      shift
      ;;

      *)
      letsencrypt_companion_image="${1:?}"
      shift
      ;;
    esac
  done

  docker run --rm \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    --label docker_api_test_suite \
    --volumes-from "$nginx_vol" \
    --env NGINX_PROXY_CONTAINER="$nginx_proxy_env" \
    --env NGINX_DOCKER_GEN_CONTAINER="$docker_gen_env" \
    "$letsencrypt_companion_image" \
    bash -c "source /app/functions.sh; \
            reload_nginx > /dev/null; \
            check_nginx_proxy_container_run; \
            $get_docker_gen_cmd \
            get_nginx_proxy_container;" 2>&1
}

case $SETUP in

  2containers)
  # Listen to Docker exec_start events
  docker events \
    --filter event=exec_start \
    --format 'Container {{.Actor.Attributes.name}} received {{.Action}}' &
  docker_events_pid=$!

  # Run a nginx-proxy container named nginx-volumes-from, without the nginx_proxy label
  docker run --rm -d \
    --name "$nginx_vol" \
    --label docker_api_test_suite \
    -v /var/run/docker.sock:/tmp/docker.sock:ro \
    jwilder/nginx-proxy > /dev/null

  # Run a nginx-proxy container named nginx-env-var, without the nginx_proxy label
  docker run --rm -d \
    --name "$nginx_env" \
    --label docker_api_test_suite \
    -v /var/run/docker.sock:/tmp/docker.sock:ro \
    jwilder/nginx-proxy > /dev/null

  # This should target the nginx-proxy container obtained with
  # the --volume-from argument (nginx-volumes-from)
  run_le_companion "$1" 2>&1

  # This should target the nginx-proxy container obtained with
  # the NGINX_PROXY_CONTAINER environment variable (nginx-env-var)
  run_le_companion "$1" --nginx-proxy-names "$nginx_env" 2>&1

  # Run a nginx-proxy container named nginx-label, with the nginx_proxy label.
  # Store the container id in the labeled_nginx_cid variable.
  labeled_nginx_cid="$(docker run --rm -d \
    --name "$nginx_lbl" \
    -v /var/run/docker.sock:/tmp/docker.sock:ro \
    --label docker_api_test_suite \
    --label com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy \
    jwilder/nginx-proxy)"

  # This should target the nginx-proxy container with the label (nginx-label)
  run_le_companion "$1" --nginx-proxy-names "$nginx_env" 2>&1

  cat > ${TRAVIS_BUILD_DIR}/test/tests/docker_api/expected-std-out.txt <<EOF
Container $nginx_vol received exec_start: sh -c /app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; /usr/sbin/nginx -s reload
$nginx_vol
Container $nginx_env received exec_start: sh -c /app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; /usr/sbin/nginx -s reload
$nginx_env
Container $nginx_lbl received exec_start: sh -c /app/docker-entrypoint.sh /usr/local/bin/docker-gen /app/nginx.tmpl /etc/nginx/conf.d/default.conf; /usr/sbin/nginx -s reload
$labeled_nginx_cid
EOF
  ;;

  3containers)
  function run_docker_gen {
    local setup="${1:-}"
    local name="${2:?}"

    case $setup in
      "--label")
        local label="--label com.github.jrcs.letsencrypt_nginx_proxy_companion.docker_gen"
        ;;
      *)
        local label=""
        ;;
    esac

    docker run --rm -d \
          --name "$name" \
          -v /var/run/docker.sock:/tmp/docker.sock:ro \
          -v ${TRAVIS_BUILD_DIR}/nginx.tmpl:/etc/docker-gen/templates/nginx.tmpl:ro \
          --label docker_api_test_suite \
          $label \
          jwilder/docker-gen \
          -watch /etc/docker-gen/templates/nginx.tmpl /etc/docker-gen/nginx.conf
  }

  # Listen to Docker kill events
  docker events \
    --filter event=kill \
    --format 'Container {{.Actor.Attributes.name}} received signal {{.Actor.Attributes.signal}}' &
  docker_events_pid=$!

  # Run a nginx container named nginx-volumes-from, without the nginx_proxy label.
  docker run --rm -d \
    --name "$nginx_vol" \
    --label docker_api_test_suite \
    nginx:alpine > /dev/null

  # Run a nginx container named nginx-env-var, without the nginx_proxy label.
  docker run --rm -d \
    --name "$nginx_env" \
    --label docker_api_test_suite \
    nginx:alpine > /dev/null

  # Spawn two docker-gen containers without the docker_gen label,
  # named docker-gen-nolabel-1 and docker-gen-nolabel-2.
  (run_docker_gen --no-label "${docker_gen}-1") > /dev/null
  (run_docker_gen --no-label "${docker_gen}-2") > /dev/null

  # This should target the nginx container whose id or name was obtained with
  # the --volumes-from argument (nginx-volumes-from)
  # and the docker-gen containers whose id or name was obtained with
  # the NGINX_DOCKER_GEN_CONTAINER environment variable (docker-gen-nolabel).
  run_le_companion "$1" --docker-gen-names "${docker_gen}-1,${docker_gen}-2" 2>&1

  # This should target the nginx container whose id or name was obtained with
  # the NGINX_PROXY_CONTAINER environment variable (nginx-env-var)
  # and the docker-gen containers whose id or name was obtained with
  # the NGINX_DOCKER_GEN_CONTAINER environment variable (docker-gen-nolabel)
  run_le_companion "$1" --nginx-proxy-names "$nginx_env" \
    --docker-gen-names "${docker_gen}-1,${docker_gen}-2" 2>&1

  # Spawn a nginx container named nginx-label, with the nginx_proxy label.
  labeled_nginx1_cid="$(docker run --rm -d \
    --name "$nginx_lbl" \
    --label docker_api_test_suite \
    --label com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy \
    nginx:alpine)"

  # This should target the nginx container whose id or name was obtained with
  # the nginx_proxy label (nginx-label)
  # and the docker-gen containers whose id or name was obtained with
  # the NGINX_DOCKER_GEN_CONTAINER environment variable (docker-gen-nolabel)
  run_le_companion "$1" --nginx-proxy-names "$nginx_env" \
    --docker-gen-names "${docker_gen}-1,${docker_gen}-2" 2>&1

  docker stop "$nginx_lbl" > /dev/null

  # Spawn two docker-gen container named docker-gen-label-1
  # and docker-gen-label-2, with the docker_gen label.
  labeled_docker_gen_1_cid="$(run_docker_gen --label "${docker_gen_lbl}-1")"
  labeled_docker_gen_2_cid="$(run_docker_gen --label "${docker_gen_lbl}-2")"

  # This should target the nginx container whose id or name was obtained with
  # the --volumes-from argument (nginx-volumes-from)
  # and the docker-gen container whose id or name was obtained with
  # the docker_gen label (docker-gen-label)
  run_le_companion "$1" --docker-gen-names "${docker_gen}-1,${docker_gen}-2" 2>&1

  # This should target the nginx container whose id or name was obtained with
  # the NGINX_PROXY_CONTAINER environment variable (nginx-env-var)
  # and the docker-gen container whose id or name was obtained with
  # the docker_gen label (docker-gen-label)
  run_le_companion "$1" --nginx-proxy-names "$nginx_env" \
    --docker-gen-names "${docker_gen}-1,${docker_gen}-2" 2>&1

  # Spawn a nginx container named nginx-label, with the nginx_proxy label.
  labeled_nginx2_cid="$(docker run --rm -d \
    --name "$nginx_lbl" \
    --label docker_api_test_suite \
    --label com.github.jrcs.letsencrypt_nginx_proxy_companion.nginx_proxy \
    nginx:alpine)"

  # This should target the nginx container whose id or name was obtained with
  # the nginx_proxy label (nginx-label)
  # and the docker-gen container whose id or name was obtained with
  # the docker_gen label (docker-gen-label)
  run_le_companion "$1" --nginx-proxy-names "$nginx_env" \
    --docker-gen-names "${docker_gen}-1,${docker_gen}-2" 2>&1

    cat > ${TRAVIS_BUILD_DIR}/test/tests/docker_api/expected-std-out.txt <<EOF
Container ${docker_gen}-1 received signal 1
Container ${docker_gen}-2 received signal 1
Container $nginx_vol received signal 1
${docker_gen}-1
${docker_gen}-2
$nginx_vol
Container ${docker_gen}-1 received signal 1
Container ${docker_gen}-2 received signal 1
Container $nginx_env received signal 1
${docker_gen}-1
${docker_gen}-2
$nginx_env
Container ${docker_gen}-1 received signal 1
Container ${docker_gen}-2 received signal 1
Container $nginx_lbl received signal 1
${docker_gen}-1
${docker_gen}-2
$labeled_nginx1_cid
Container $nginx_lbl received signal 15
Container ${docker_gen_lbl}-2 received signal 1
Container ${docker_gen_lbl}-1 received signal 1
Container $nginx_vol received signal 1
$labeled_docker_gen_2_cid
$labeled_docker_gen_1_cid
$nginx_vol
Container ${docker_gen_lbl}-2 received signal 1
Container ${docker_gen_lbl}-1 received signal 1
Container $nginx_env received signal 1
$labeled_docker_gen_2_cid
$labeled_docker_gen_1_cid
$nginx_env
Container ${docker_gen_lbl}-2 received signal 1
Container ${docker_gen_lbl}-1 received signal 1
Container $nginx_lbl received signal 1
$labeled_docker_gen_2_cid
$labeled_docker_gen_1_cid
$labeled_nginx2_cid
EOF
  ;;

esac
