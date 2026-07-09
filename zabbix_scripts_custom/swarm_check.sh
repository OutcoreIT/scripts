#!/bin/bash

ACTION="$1"
TARGET="$2"

DOCKER_BIN="/usr/bin/docker"

if [ ! -x "$DOCKER_BIN" ]; then
    DOCKER_BIN="$(command -v docker)"
fi

if [ -z "$DOCKER_BIN" ]; then
    echo "0"
    exit 1
fi

case "$ACTION" in

    cluster_info)
        $DOCKER_BIN info --format '{{json .Swarm}}' 2>/dev/null
    ;;

    cluster_state)
        STATE="$($DOCKER_BIN info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
        if [ "$STATE" = "active" ]; then
            echo 1
        else
            echo 0
        fi
    ;;

    nodes_discovery)
        $DOCKER_BIN node ls --format '{"{#NODE_ID}":"{{.ID}}","{#NODE_HOSTNAME}":"{{.Hostname}}","{#NODE_STATUS}":"{{.Status}}","{#NODE_AVAILABILITY}":"{{.Availability}}","{#NODE_MANAGER_STATUS}":"{{.ManagerStatus}}"}' 2>/dev/null \
        | jq -s '{"data": .}'
    ;;

    services_discovery)
        $DOCKER_BIN service ls --format '{"{#SERVICE_ID}":"{{.ID}}","{#SERVICE_NAME}":"{{.Name}}","{#SERVICE_MODE}":"{{.Mode}}","{#SERVICE_REPLICAS}":"{{.Replicas}}"}' 2>/dev/null \
        | jq -s '{"data": .}'
    ;;

    service_running)
        if [ -z "$TARGET" ]; then
            echo 0
            exit 0
        fi

        $DOCKER_BIN service inspect "$TARGET" >/dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo 0
            exit 0
        fi

        RUNNING="$($DOCKER_BIN service ps "$TARGET" \
            --filter desired-state=running \
            --format '{{.CurrentState}}' 2>/dev/null \
            | grep -c '^Running')"

        if [ -z "$RUNNING" ]; then
            echo 0
        else
            echo "$RUNNING"
        fi
    ;;

    service_desired)
        if [ -z "$TARGET" ]; then
            echo 0
            exit 0
        fi

        MODE_JSON="$($DOCKER_BIN service inspect "$TARGET" --format '{{json .Spec.Mode}}' 2>/dev/null)"

        if [ -z "$MODE_JSON" ]; then
            echo 0
            exit 0
        fi

        DESIRED="$(echo "$MODE_JSON" | jq -r '.Replicated.Replicas // empty' 2>/dev/null)"

        if [ -n "$DESIRED" ]; then
            echo "$DESIRED"
            exit 0
        fi

        IS_GLOBAL="$(echo "$MODE_JSON" | jq -r 'has("Global")' 2>/dev/null)"

        if [ "$IS_GLOBAL" = "true" ]; then
            $DOCKER_BIN node ls --format '{{.Status}} {{.Availability}}' 2>/dev/null \
                | awk '$1 == "Ready" && $2 == "Active" {count++} END {print count+0}'
            exit 0
        fi

        echo 0
    ;;

    service_replicas_ok)
        if [ -z "$TARGET" ]; then
            echo 0
            exit 0
        fi

        RUNNING="$($0 service_running "$TARGET")"
        DESIRED="$($0 service_desired "$TARGET")"

        if [ -z "$RUNNING" ] || [ -z "$DESIRED" ]; then
            echo 0
            exit 0
        fi

        if [ "$RUNNING" -ge "$DESIRED" ]; then
            echo 1
        else
            echo 0
        fi
    ;;

    service_failed_tasks)
        $DOCKER_BIN service ps "$TARGET" --no-trunc --format '{{.CurrentState}}' 2>/dev/null \
        | grep -Ei 'Failed|Rejected|Error' \
        | wc -l
    ;;

    service_tasks)
        $DOCKER_BIN service ps "$TARGET" --no-trunc --format '{{.ID}}' 2>/dev/null \
        | wc -l
    ;;

    node_status)
        STATUS="$($DOCKER_BIN node ls --format '{{.Hostname}} {{.Status}}' 2>/dev/null | awk -v node="$TARGET" '$1 == node {print $2}')"

        case "$STATUS" in
            Ready)
                echo 1
            ;;
            Down)
                echo 0
            ;;
            *)
                echo 0
            ;;
        esac
    ;;

    node_availability)
        AVAILABILITY="$($DOCKER_BIN node ls --format '{{.Hostname}} {{.Availability}}' 2>/dev/null | awk -v node="$TARGET" '$1 == node {print $2}')"

        case "$AVAILABILITY" in
            Active)
                echo 1
            ;;
            Pause)
                echo 2
            ;;
            Drain)
                echo 3
            ;;
            *)
                echo 0
            ;;
        esac
    ;;

    node_manager)
        MANAGER="$($DOCKER_BIN node ls --format '{{.Hostname}} {{.ManagerStatus}}' 2>/dev/null | awk -v node="$TARGET" '$1 == node {print $2}')"

        case "$MANAGER" in
            Leader)
                echo 2
            ;;
            Reachable)
                echo 1
            ;;
            *)
                echo 0
            ;;
        esac
    ;;

    services_problem_count)
        $DOCKER_BIN service ls --format '{{.Name}} {{.Replicas}}' 2>/dev/null \
        | awk -F'[ /]' '$2 != $3 {count++} END {print count+0}'
    ;;

    nodes_problem_count)
        $DOCKER_BIN node ls --format '{{.Hostname}} {{.Status}} {{.Availability}}' 2>/dev/null \
        | awk '$2 != "Ready" || $3 != "Active" {count++} END {print count+0}'
    ;;

    *)
        echo "Unsupported action"
        exit 1
    ;;

esac