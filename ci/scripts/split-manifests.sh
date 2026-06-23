#!/usr/bin/env bash
# split-manifests.sh — Split a YAML stream into individual files.
# Each file is named {kind}-{metadata.name}.yaml (lowercased).
# Files are organized into subdirectories by resource type.
# Handles both --- separated and concatenated YAML documents.
#
# Usage: cat manifests.yaml | ./ci/scripts/split-manifests.sh <output-dir>

set -euo pipefail

OUTDIR="${1:?Usage: split-manifests.sh <output-dir>}"
mkdir -p "$OUTDIR"

INDEX=0
DOC=""

# Map kind to subdirectory
subdir_for_kind() {
    case "$1" in
        compositeresourcedefinition) echo "xrds" ;;
        composition)                echo "compositions" ;;
        nodetaint)                  echo "nodes" ;;
        networkpolicy)              echo "policies" ;;
        resourcequota)              echo "policies" ;;
        helmrelease)                echo "helm" ;;
        rolebinding)                echo "rbac" ;;
        namespace)                  echo "namespaces" ;;
        xnodetaint)                 echo "nodes" ;;
        xnetworkpolicy)             echo "policies" ;;
        xresourcequota)             echo "policies" ;;
        xhelmrelease)               echo "helm" ;;
        xrolebinding)               echo "rbac" ;;
        xnamespace)                 echo "namespaces" ;;
        xharborregistry)            echo "harbor" ;;
        xharborproject)             echo "harbor" ;;
        xstorageclass)              echo "storage" ;;
        # Networking — Ingresses + their dependencies (MetalLB pools,
        # external backends, Traefik ServersTransports, exposed services).
        xingress)                   echo "networking" ;;
        xmetallbpool)               echo "networking" ;;
        xexternalbackend)           echo "networking" ;;
        xserverstransport)          echo "networking" ;;
        xexposedservice)            echo "networking" ;;
        # Argo Events / CD CRs.
        xargoapplicationset)        echo "argo" ;;
        xargoappproject)            echo "argo" ;;
        xargoeventbus)              echo "argo" ;;
        xargoeventsource)           echo "argo" ;;
        xargosensor)                echo "argo" ;;
        # RBAC adjacent.
        xclusterrole)               echo "rbac" ;;
        xclusterrolebinding)        echo "rbac" ;;
        xserviceaccount)            echo "rbac" ;;
        # Secrets / certs.
        xexternalsecret)            echo "secrets" ;;
        xclusterexternalsecret)     echo "secrets" ;;
        xclustersecretstore)        echo "secrets" ;;
        xcertificate)               echo "secrets" ;;
        # Jobs + CronJobs.
        xjob)                       echo "jobs" ;;
        xcronjob)                   echo "jobs" ;;
        # SSA patches against existing resources.
        xobjectpatch)               echo "patches" ;;
        # Kyverno policies join the rest of the policy/quota bucket.
        xkyvernopolicy)             echo "policies" ;;
        # Kelos AI pipeline CRs.
        xkelosagentconfig)          echo "kelos" ;;
        xkelostaskspawner)          echo "kelos" ;;
        xkelosworkspace)            echo "kelos" ;;
        # Autoscaling CRs.
        xverticalpodautoscaler)     echo "autoscaling" ;;
        *)                          echo "" ;;
    esac
}

flush_doc() {
    if [[ -z "$DOC" ]]; then
        return
    fi

    KIND=$(echo "$DOC" | yq '.kind' | tr '[:upper:]' '[:lower:]')
    NAME=$(echo "$DOC" | yq '.metadata.name')
    NS=$(echo "$DOC" | yq '.metadata.namespace')

    if [[ "$KIND" == "null" || "$NAME" == "null" ]]; then
        echo "  WARN: skipping document $INDEX (missing kind or metadata.name)" >&2
        DOC=""
        return
    fi

    SUBDIR=$(subdir_for_kind "$KIND")
    if [[ -n "$SUBDIR" ]]; then
        mkdir -p "$OUTDIR/$SUBDIR"
        FILEPATH="$SUBDIR/${KIND}-${NAME}.yaml"
    else
        FILEPATH="${KIND}-${NAME}.yaml"
    fi

    # Disambiguate same-kind/same-name resources living in different namespaces
    # (e.g. a Traefik ServersTransport named `insecure-skip-verify` in both the
    # home-assistant and truenas namespaces). Without this the second document
    # silently overwrites the first and one resource vanishes from the output.
    if [[ -e "$OUTDIR/$FILEPATH" && "$NS" != "null" && -n "$NS" ]]; then
        if [[ -n "$SUBDIR" ]]; then
            FILEPATH="$SUBDIR/${KIND}-${NS}-${NAME}.yaml"
        else
            FILEPATH="${KIND}-${NS}-${NAME}.yaml"
        fi
    fi

    mkdir -p "$(dirname "$OUTDIR/$FILEPATH")"
    echo "$DOC" > "$OUTDIR/$FILEPATH"
    echo "  $FILEPATH"
    DOC=""
    INDEX=$((INDEX + 1))
}

while IFS= read -r line; do
    # Skip --- separators
    if [[ "$line" == "---" ]]; then
        flush_doc
        continue
    fi

    # Detect new document: apiVersion at column 0 means a new resource
    if [[ "$line" =~ ^apiVersion: && -n "$DOC" ]]; then
        flush_doc
    fi

    if [[ -n "$DOC" ]]; then
        DOC="$DOC"$'\n'"$line"
    else
        DOC="$line"
    fi
done

# Flush last document
flush_doc

echo "Wrote $INDEX manifests to $OUTDIR"
