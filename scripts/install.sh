#!/bin/bash

set -e

DIR=.

# Magic begin: scripts are inlined for distribution. See "make build/install.sh"
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
. $DIR/scripts/common/tasks.sh
. $DIR/scripts/common/upgrade.sh
. $DIR/scripts/common/yaml.sh
# Magic end

function init() {
    logStep "Initialize Kubernetes"

    get_shared

    kubernetes_maybe_generate_bootstrap_token

    if [ "$HA_CLUSTER" = "1" ]; then
        promptForLoadBalancerAddress

        if [ "$LOAD_BALANCER_ADDRESS_CHANGED" = "1" ]; then
            handleLoadBalancerAddressChangedPreInit
        fi
    fi

    kustomize_kubeadm_init=./kustomize/kubeadm/init
    if [ "$HA_CLUSTER" = "1" ]; then
        CERT_KEY=$(< /dev/urandom tr -dc a-f0-9 | head -c64)
        insert_patches_strategic_merge \
            $kustomize_kubeadm_init/kustomization.yaml \
            patch-certificate-key.yaml
    fi
    if [ -n "$PUBLIC_ADDRESS" ]; then
        insert_patches_strategic_merge \
            $kustomize_kubeadm_init/kustomization.yaml \
            patch-public-address.yaml
    fi
    if [ -n "$LOAD_BALANCER_ADDRESS" ]; then
        insert_patches_strategic_merge \
            $kustomize_kubeadm_init/kustomization.yaml \
            patch-load-balancer-address.yaml
    fi
    # Add kubeadm init patches from addons.
    for patch in $(ls -1 ${kustomize_kubeadm_init}-patches/* 2>/dev/null || echo); do
        patch_basename="$(basename $patch)"
        cp $patch $kustomize_kubeadm_init/$patch_basename
        insert_patches_strategic_merge \
            $kustomize_kubeadm_init/kustomization.yaml \
            $patch_basename
    done
    mkdir -p "$KUBEADM_CONF_DIR"
    kustomize build $kustomize_kubeadm_init > $KUBEADM_CONF_DIR/kubeadm-init-raw.yaml
    render_yaml_file $KUBEADM_CONF_DIR/kubeadm-init-raw.yaml > $KUBEADM_CONF_FILE

    if [ "$HA_CLUSTER" = "1" ]; then
        UPLOAD_CERTS="--upload-certs"
    fi
    # kubeadm init temporarily taints this node which causes rook to move any mons on it and may
    # lead to a loss of quorum
    disable_rook_ceph_operator
    kubeadm init \
        --ignore-preflight-errors=all \
        --config $KUBEADM_CONF_FILE \
        $UPLOAD_CERTS \
        | tee /tmp/kubeadm-init

    exportKubeconfig

    waitForNodes
    enable_rook_ceph_operator

    DID_INIT_KUBERNETES=1
    logSuccess "Kubernetes Master Initialized"

    if [ "$LOAD_BALANCER_ADDRESS_CHANGED" = "1" ]; then
        handleLoadBalancerAddressChangedPostInit
    fi

    kubectl cluster-info
    logSuccess "Cluster Initialized"
}

function kubernetes_maybe_generate_bootstrap_token() {
    if [ -z "$BOOTSTRAP_TOKEN" ]; then
        logStep "generate kubernetes bootstrap token"
        BOOTSTRAP_TOKEN=$(kubeadm token generate)
    fi
    echo "Kubernetes bootstrap token: ${BOOTSTRAP_TOKEN}"
    echo "This token will expire in 24 hours"
}

function outro() {
    echo
    if [ -z "$PUBLIC_ADDRESS" ]; then
      if [ -z "$PRIVATE_ADDRESS" ]; then
        PUBLIC_ADDRESS="<this_server_address>"
        PRIVATE_ADDRESS="<this_server_address>"
      else
        PUBLIC_ADDRESS="$PRIVATE_ADDRESS"
      fi
    fi

    local dockerRegistryIP=""
    if [ -n "$DOCKER_REGISTRY_IP" ]; then
        dockerRegistryIP=" docker-registry-ip=$DOCKER_REGISTRY_IP"
    fi

    KUBEADM_TOKEN_CA_HASH=$(cat /tmp/kubeadm-init | grep 'discovery-token-ca-cert-hash' | awk '{ print $(NF) }')

    printf "\n"
    printf "\t\t${GREEN}Installation${NC}\n"
    printf "\t\t${GREEN}  Complete ✔${NC}\n"
    addon_outro
    printf "\n"
    printf "To access the cluster with kubectl, reload your shell:\n"
    printf "\n"
    printf "${GREEN}    bash -l${NC}\n"
    printf "\n"
    if [ "$AIRGAP" = "1" ]; then
        printf "\n"
        printf "To add worker nodes to this installation, copy and unpack this bundle on your other nodes, and run the following:"
        printf "\n"
        printf "\n"
        printf "${GREEN}    cat ./join.sh | sudo bash -s airgap kubernetes-master-address=${PRIVATE_ADDRESS} kubeadm-token=${BOOTSTRAP_TOKEN} kubeadm-token-ca-hash=$KUBEADM_TOKEN_CA_HASH kubernetes-version=$KUBERNETES_VERSION ${dockerRegistryIP}\n"
        printf "${NC}"
        printf "\n"
        printf "\n"
        if [ "$HA_CLUSTER" = "1" ]; then
            printf "\n"
            printf "To add ${GREEN}MASTER${NC} nodes to this installation, copy and unpack this bundle on your other nodes, and run the following:"
            printf "\n"
            printf "\n"
            printf "${GREEN}    cat ./join.sh | sudo bash -s airgap kubernetes-master-address=${PRIVATE_ADDRESS} kubeadm-token=${BOOTSTRAP_TOKEN} kubeadm-token-ca-hash=$KUBEADM_TOKEN_CA_HASH kubernetes-version=$KUBERNETES_VERSION cert-key=${CERT_KEY} control-plane ${dockerRegistryIP}\n"
            printf "${NC}"
            printf "\n"
            printf "\n"
        fi
    else
        local prefix="curl $KURL_URL/$INSTALLER_ID/"
        if [ -z "$KURL_URL" ]; then
            prefix="cat "
        fi
        printf "\n"
        printf "To add worker nodes to this installation, run the following script on your other nodes"
        printf "\n"
        printf "${GREEN}    ${prefix}join.sh | sudo bash -s kubernetes-master-address=${PRIVATE_ADDRESS} kubeadm-token=${BOOTSTRAP_TOKEN} kubeadm-token-ca-hash=$KUBEADM_TOKEN_CA_HASH kubernetes-version=$KUBERNETES_VERSION ${dockerRegistryIP}\n"
        printf "${NC}"
        printf "\n"
        printf "\n"
        if [ "$HA_CLUSTER" = "1" ]; then
            printf "\n"
            printf "To add ${GREEN}MASTER${NC} nodes to this installation, run the following script on your other nodes"
            printf "\n"
            printf "${GREEN}    ${prefix}join.sh | sudo bash -s kubernetes-master-address=${PRIVATE_ADDRESS} kubeadm-token=${BOOTSTRAP_TOKEN} kubeadm-token-ca-hash=$KUBEADM_TOKEN_CA_HASH kubernetes-version=$KUBERNETES_VERSION cert-key=${CERT_KEY} control-plane ${dockerRegistryIP}\n"
            printf "${NC}"
            printf "\n"
            printf "\n"
        fi
    fi
}

function main() {
    export KUBECONFIG=/etc/kubernetes/admin.conf
    requireRootUser
    discover
    flags $FLAGS
    flags "$@"
    tasks
    preflights
    prompts
    configure_proxy
    install_docker
    upgrade_kubernetes_patch
    kubernetes_host
    setup_kubeadm_kustomize
    addon_pre_init aws "$AWS_VERSION"
    addon_pre_init calico "$CALICO_VERSION"
    addon_pre_init weave "$WEAVE_VERSION"
    addon_pre_init rook "$ROOK_VERSION"
    addon_pre_init contour "$CONTOUR_VERSION"
    addon_pre_init registry "$REGISTRY_VERSION"
    addon_pre_init prometheus "$PROMETHEUS_VERSION"
    addon_pre_init kotsadm "$KOTSADM_VERSION"
    init
    addon aws "$AWS_VERSION"
    addon calico "$CALICO_VERSION"
    addon weave "$WEAVE_VERSION"
    addon rook "$ROOK_VERSION"
    addon contour "$CONTOUR_VERSION"
    addon registry "$REGISTRY_VERSION"
    addon prometheus "$PROMETHEUS_VERSION"
    addon kotsadm "$KOTSADM_VERSION"
    outro
}

main "$@"
