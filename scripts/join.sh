#!/bin/bash

set -e

DIR=.

# Magic begin: scripts are inlined for distribution. See "make build/join.sh"
. $DIR/scripts/Manifest
. $DIR/scripts/common/addon.sh
. $DIR/scripts/common/common.sh
. $DIR/scripts/common/discover.sh
. $DIR/scripts/common/docker.sh
. $DIR/scripts/common/flags.sh
. $DIR/scripts/common/kubernetes.sh
. $DIR/scripts/common/preflights.sh
. $DIR/scripts/common/prompts.sh
. $DIR/scripts/common/proxy.sh
. $DIR/scripts/common/rook.sh
. $DIR/scripts/common/yaml.sh
# Magic end

function join() {
    get_shared

    if [ "$MASTER" = "1" ]; then
        logStep "Join Kubernetes master node"

        # this will stop all the control plane pods except etcd
        rm -f /etc/kubernetes/manifests/kube-*
        while docker ps | grep -q kube-apiserver ; do
            sleep 2
        done
        # delete files that need to be regenerated in case of load balancer address change
        rm -f /etc/kubernetes/*.conf
        rm -f /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.key
    else
        logStep "Join Kubernetes node"
    fi

    rm -rf ./kustomize/kubeadm/join
    cp -rf ./kustomize/kubeadm/join-orig ./kustomize/kubeadm/join
    if [ "$MASTER" = "1" ]; then
        insert_patches_strategic_merge \
            ./kustomize/kubeadm/join/base/kustomization.yaml \
            patch-certificate-key.yaml
    fi
    mkdir -p "$KUBEADM_CONF_DIR"
    kustomize build ./kustomize/kubeadm/join > $KUBEADM_CONF_DIR/kubeadm-join-raw.yaml
    render_yaml_file $KUBEADM_CONF_DIR/kubeadm-join-raw.yaml > $KUBEADM_CONF_FILE

    set +e
    (set -x; kubeadm join --config /opt/replicated/kubeadm.conf --ignore-preflight-errors=all)
    _status=$?
    set -e

    if [ "$_status" -ne "0" ]; then
        printf "${RED}Failed to join the kubernetes cluster.${NC}\n" 1>&2
        exit $_status
    fi

    if [ "$MASTER" = "1" ]; then
        exportKubeconfig
        logStep "Master node joined successfully"
    else
        logStep "Node joined successfully"
    fi
}

outro() {
    printf "\n"
    printf "\t\t${GREEN}Installation${NC}\n"
    printf "\t\t${GREEN}  Complete ✔${NC}\n"
    if [ "$MASTER" = "1" ]; then
        printf "\n"
        printf "To access the cluster with kubectl, reload your shell:\n"
        printf "\n"
        printf "${GREEN}    bash -l${NC}\n"
    fi
    printf "\n"
}

function main() {
    export KUBECONFIG=/etc/kubernetes/admin.conf
    requireRootUser
    discover
    flags $FLAGS
    flags "$@"
    preflights
    joinPrompts
    prompts
    configure_proxy
    install_docker
    addon_join weave "$WEAVE_VERSION"
    addon_join rook "$ROOK_VERSION"
    addon_join contour "$CONTOUR_VERSION"
    addon_join registry "$REGISTRY_VERSION"
    addon_join prometheus "$PROMETHEUS_VERSION"
    addon_join kotsadm "$KOTSADM_VERSION"
    kubernetes_host
    join
    outro
}

main "$@"
