#!/bin/bash
# Copyright (C) 2024 Advanced Micro Devices, Inc.
# SPDX-License-Identifier: Apache-2.0

set -xe
IMAGE_REPO=${IMAGE_REPO:-"opea"}
IMAGE_TAG=${IMAGE_TAG:-"latest"}
echo "REGISTRY=IMAGE_REPO=${IMAGE_REPO}"
echo "TAG=IMAGE_TAG=${IMAGE_TAG}"
export REGISTRY=${IMAGE_REPO}
export TAG=${IMAGE_TAG}
export MODEL_CACHE=${model_cache:-"./data"}

WORKPATH=$(dirname "$PWD")
LOG_PATH="$WORKPATH/tests"
ip_address=$(hostname -I | awk '{print $1}')

source $WORKPATH/docker_compose/amd/gpu/rocm/set_env_vllm.sh

function build_docker_images() {
    opea_branch=${opea_branch:-"main"}
    cd $WORKPATH/docker_image_build
    git clone --depth 1 --branch ${opea_branch} https://github.com/opea-project/GenAIComps.git
    pushd GenAIComps
    echo "GenAIComps test commit is $(git rev-parse HEAD)"
    docker build --no-cache -t ${REGISTRY}/comps-base:${TAG} --build-arg https_proxy=$https_proxy --build-arg http_proxy=$http_proxy -f Dockerfile .
    popd && sleep 1s

    echo "Build all the images with --no-cache, check docker_image_build.log for details..."
    service_list="docsum docsum-gradio-ui whisper llm-docsum vllm-rocm"
    docker compose -f build.yaml build ${service_list} --no-cache > ${LOG_PATH}/docker_image_build.log

    docker images && sleep 3s
}

function start_services() {
    cd "$WORKPATH"/docker_compose/amd/gpu/rocm
    sed -i "s/backend_address/$ip_address/g" "$WORKPATH"/ui/svelte/.env
    # Start Docker Containers
    docker compose -f compose_vllm.yaml up -d > "${LOG_PATH}"/start_services_with_compose.log
    n=0
    until [[ "$n" -ge 500 ]]; do
        docker logs docsum-vllm-service >& "${LOG_PATH}"/docsum-vllm-service_start.log
        if grep -q "Application startup complete" "${LOG_PATH}"/docsum-vllm-service_start.log; then
            break
        fi
        sleep 10s
        n=$((n+1))
    done
    sleep 5s
}

function validate_services() {
    local URL="$1"
    local EXPECTED_RESULT="$2"
    local SERVICE_NAME="$3"
    local DOCKER_NAME="$4"
    local INPUT_DATA="$5"

    local HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -d "$INPUT_DATA" -H 'Content-Type: application/json' "$URL")

    echo "==========================================="

    if [ "$HTTP_STATUS" -eq 200 ]; then
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."

        local CONTENT=$(curl -s -X POST -d "$INPUT_DATA" -H 'Content-Type: application/json' "$URL" | tee ${LOG_PATH}/${SERVICE_NAME}.log)

        if echo "$CONTENT" | grep -q "$EXPECTED_RESULT"; then
            echo "[ $SERVICE_NAME ] Content is as expected."
        else
            echo "EXPECTED_RESULT==> $EXPECTED_RESULT"
            echo "CONTENT==> $CONTENT"
            echo "[ $SERVICE_NAME ] Content does not match the expected result: $CONTENT"
            docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log
            exit 1

        fi
    else
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log
        exit 1
    fi
    sleep 1s
}

get_base64_str() {
    local file_name=$1
    base64 -w 0 "$file_name"
}

# Function to generate input data for testing based on the document type
input_data_for_test() {
    local document_type=$1
    case $document_type in
        ("text")
            echo "THIS IS A TEST >>>> and a number of states are starting to adopt them voluntarily special correspondent john delenco of education week reports it takes just 10 minutes to cross through gillette wyoming this small city sits in the northeast corner of the state surrounded by 100s of miles of prairie but schools here in campbell county are on the edge of something big the next generation science standards you are going to build a strand of dna and you are going to decode it and figure out what that dna actually says for christy mathis at sage valley junior high school the new standards are about learning to think like a scientist there is a lot of really good stuff in them every standard is a performance task it is not you know the child needs to memorize these things it is the student needs to be able to do some pretty intense stuff we are analyzing we are critiquing we are."
            ;;
        ("audio")
            get_base64_str "$WORKPATH/tests/data/test.wav"
            ;;
        ("video")
            get_base64_str "$WORKPATH/tests/data/test.mp4"
            ;;
        (*)
            echo "Invalid document type" >&2
            exit 1
            ;;
    esac
}

function validate_microservices() {
    # Check if the microservices are running correctly.

    # whisper microservice
    ulimit -s 65536
    validate_services \
        "${HOST_IP}:${DOCSUM_WHISPER_PORT}/v1/asr" \
        '{"asr_result":"well"}' \
        "whisper-service" \
        "whisper-service" \
        "{\"audio\": \"$(input_data_for_test "audio")\"}"

    # vLLM service
    validate_services \
        "${HOST_IP}:${DOCSUM_VLLM_SERVICE_PORT}/v1/chat/completions" \
        "content" \
        "docsum-vllm-service" \
        "docsum-vllm-service" \
        '{"model": "Intel/neural-chat-7b-v3-3", "messages": [{"role": "user", "content": "What is Deep Learning?"}], "max_tokens": 17}'

    # llm microservice
    validate_services \
        "${HOST_IP}:${DOCSUM_LLM_SERVER_PORT}/v1/docsum" \
        "text" \
        "docsum-llm-server" \
        "docsum-llm-server" \
        '{"messages":"What is a Deep Learning?"}'

}

function validate_megaservice() {
    local SERVICE_NAME="docsum-backend-server"
    local DOCKER_NAME="docsum-backend-server"
    local EXPECTED_RESULT="[DONE]"
    local INPUT_DATA="messages=Text Embeddings Inference (TEI) is a toolkit for deploying and serving open source text embeddings and sequence classification models. TEI enables high-performance extraction for the most popular models, including FlagEmbedding, Ember, GTE and E5."
    local URL="${HOST_IP}:${DOCSUM_BACKEND_SERVER_PORT}/v1/docsum"
    local DATA_TYPE="type=text"

    local HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST -F "$DATA_TYPE" -F "$INPUT_DATA" -H 'Content-Type: multipart/form-data' "$URL")

    if [ "$HTTP_STATUS" -eq 200 ]; then
        echo "[ $SERVICE_NAME ] HTTP status is 200. Checking content..."

        local CONTENT=$(curl -s -X POST -F "$DATA_TYPE" -F "$INPUT_DATA" -H 'Content-Type: multipart/form-data' "$URL" | tee ${LOG_PATH}/${SERVICE_NAME}.log)

        if echo "$CONTENT" | grep -q "$EXPECTED_RESULT"; then
            echo "[ $SERVICE_NAME ] Content is as expected."
        else
            echo "[ $SERVICE_NAME ] Content does not match the expected result: $CONTENT"
            docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log
            exit 1
        fi
    else
        echo "[ $SERVICE_NAME ] HTTP status is not 200. Received status was $HTTP_STATUS"
        docker logs ${DOCKER_NAME} >> ${LOG_PATH}/${SERVICE_NAME}.log
        exit 1
    fi
    sleep 1s
}

function validate_megaservice_json() {
    # Curl the Mega Service
    echo ""
    echo ">>> Checking text data with Content-Type: application/json"
    validate_services \
        "${HOST_IP}:${DOCSUM_BACKEND_SERVER_PORT}/v1/docsum" \
        "[DONE]" \
        "docsum-backend-server" \
        "docsum-backend-server" \
        '{"type": "text", "messages": "Text Embeddings Inference (TEI) is a toolkit for deploying and serving open source text embeddings and sequence classification models. TEI enables high-performance extraction for the most popular models, including FlagEmbedding, Ember, GTE and E5."}'

    echo ">>> Checking audio data"
    validate_services \
        "${HOST_IP}:${DOCSUM_BACKEND_SERVER_PORT}/v1/docsum" \
        "[DONE]" \
        "docsum-backend-server" \
        "docsum-backend-server" \
        "{\"type\": \"audio\",  \"messages\": \"$(input_data_for_test "audio")\"}"

    echo ">>> Checking video data"
    validate_services \
        "${HOST_IP}:${DOCSUM_BACKEND_SERVER_PORT}/v1/docsum" \
        "[DONE]" \
        "docsum-backend-server" \
        "docsum-backend-server" \
        "{\"type\": \"video\",  \"messages\": \"$(input_data_for_test "video")\"}"

}

function stop_docker() {
    cd $WORKPATH/docker_compose/amd/gpu/rocm/
    docker compose -f compose_vllm.yaml stop && docker compose -f compose_vllm.yaml rm -f
}

function main() {

    echo "::group:: Stop Docker containers..."
    stop_docker
    echo "::endgroup::"

    echo "::group::build_docker_images"
    if [[ "$IMAGE_REPO" == "opea" ]]; then build_docker_images; fi
    echo "::endgroup::"

    echo "::group::start_services"
    start_services
    echo "::endgroup::"

    echo "::group:: Validating microservices"
    validate_microservices
    echo "::endgroup::"

    echo "::group:: Validating Mega Service"
    validate_megaservice
    echo "::endgroup::"

    echo "::group:: Validating Mega Service with JSON input"
    validate_megaservice_json
    echo "::endgroup::"

    echo "::group::Stopping Docker containers..."
    stop_docker
    echo "::endgroup::"

    docker system prune -f

}

main
