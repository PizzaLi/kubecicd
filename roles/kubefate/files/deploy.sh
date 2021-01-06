#! /bin/bash

version=v1.5.0
kubefate_version=v1.2.0
docker_version=docker-19.03.10
dist_name=""
deploydir="cicd"

# Get distribution
get_dist_name()
{
  if grep -Eqii "CentOS" /etc/issue || grep -Eq "CentOS" /etc/*-release; then
        dist_name='CentOS'
  elif grep -Eqi "Red Hat Enterprise Linux Server" /etc/issue || grep -Eq "Red Hat Enterprise Linux Server" /etc/*-release; then
        dist_name='Fedora'
  elif grep -Eqi "Debian" /etc/issue || grep -Eq "Debian" /etc/*-release; then
        dist_name='Debian'
  elif grep -Eqi "Ubuntu" /etc/issue || grep -Eq "Ubuntu" /etc/*-release; then
        dist_name='Ubuntu'
  else
        dist_name='Unknown'
  fi
  echo $DISTRO;
}

centos()
{
  yum remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine
  yum install -y yum-utils
  yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  yum install -y docker-ce docker-ce-cli containerd.io
  systemctl start docker
}

fedora()
{
  dnf remove docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-selinux docker-engine-selinux docker-engine
  dnf -y install dnf-plugins-core
  dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
  dnf install docker-ce docker-ce-cli containerd.io
  systemctl start docker
}

debian()
{
  apt-get remove docker docker-engine docker.io containerd runc
  apt-get update
  apt-get install apt-transport-https ca-certificates curl gnupg-agent software-properties-common
  curl -fsSL https://download.docker.com/linux/debian/gpg | apt-key add -
  add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/debian $(lsb_release -cs) stable"
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
}

ubuntu()
{
  sudo apt-get remove docker docker-engine docker.io containerd runc
  sudo apt-get update
  sudo apt-get install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg-agent \
    software-properties-common
  sudo add-apt-repository \
   "deb [arch=amd64] https://download.docker.com/linux/ubuntu \
   $(lsb_release -cs) \
   stable"
  sudo apt-get update
  sudo apt-get install docker-ce docker-ce-cli containerd.io
}

check_cgroupfs()
{
  if grep -v '^#' /etc/fstab | grep -q cgroup; then
    echo 'cgroups mounted from fstab, not mounting /sys/fs/cgroup'
    exit 1
  fi

  # kernel provides cgroups?
  if [ ! -e /proc/cgroups ]; then
    exit 1
  fi

  # if we don't even have the directory we need, something else must be wrong
  if [ ! -d /sys/fs/cgroup ]; then
    exit 1
  fi

  # mount /sys/fs/cgroup if not already done
  if ! mountpoint -q /sys/fs/cgroup; then
    mount -t tmpfs -o uid=0,gid=0,mode=0755 cgroup /sys/fs/cgroup
  fi

  cd /sys/fs/cgroup

  # get/mount list of enabled cgroup controllers
  for sys in $(awk '!/^#/ { if ($4 == 1) print $1 }' /proc/cgroups); do
    mkdir -p $sys
    if ! mountpoint -q $sys; then
        if ! mount -n -t cgroup -o $sys cgroup $sys; then
            rmdir $sys || true
        fi
    fi
  done

  if [ -e /sys/fs/cgroup/memory/memory.use_hierarchy ]; then
      echo 1 > /sys/fs/cgroup/memory/memory.use_hierarchy
  fi
}

binary()
{
  system_bit=`getconf LONG_BIT`
  if [ $system_bit == 64 ]; then
    echo "System bit: " $system_bit
  else
    echo "Fatal: Unsupport system"
    exit 1
  fi

  main=`uname -r | awk -F '.' '{print $1}'`
  minor=`uname -r | awk -F '.' '{print $2}'`
  if [ $main$minor -ge 310 ]; then
    echo "Kernel version: " `uname -r`
  else
    echo "Fatal: Kernel less then 310 is unsupported"
    exit 1
  fi

  git_version=`git version | awk -F ' ' '{print $3}'`
  main=`echo $git_version | awk -F '.' '{print $1}'`
  minor=`echo $git_version | awk -F '.' '{print $2}'`
  if [ $main$minor -ge 17 ]; then
    echo "Git version: " $git_version
  else
    echo "Fatal: Git version less then 1.7"
    exit 1
  fi

  ps=`ps`
  if [ $? -ne 0 ]; then
    echo "Fatal: ps is not usable"
    exit 1
  fi

  xz_version=`xz --version | awk -F ') ' '{print $2}'`
  main=`echo $xz_version | awk -F '.' '{print $1}'`
  minor=`echo $xz_version | awk -F '.' '{print $2}'`
  if [ $main$minor -ge 49 ]; then
    echo "XZ version: " $xz_version
  else
    echo "Fatal: Xz version less then 4.9"
    exit 1
  fi

  check_cgroupfs
  if [ $? -ne 0 ]; then
    echo "Fatal: cgroup is not suitable"
    exit 1
  fi

  # Download docker
  curl -Lo ./$docker_version.tgz https://download.docker.com/linux/static/stable/x86_64/$docker_version.tgz

  # Extract the archive using the tar utility
  tar -xzf $docker_version.tgz

  # Move the binaries to a directory on your executable path, such as /usr/bin/
  sudo cp docker/* /usr/bin/

  # Start the Docker daemon
  sudo dockerd $
}

clean()
{
  if [ -d $deploydir ]; then
    sudo rm -rf $deploydir
  fi

  echo "Deleting kind cluster..." 
  # kind delete cluster --name kubefate
}

create_cluster_with_kind()
{
  #kind create cluster --name kubefate
cat <<EOF | kind create cluster --config=-
    kind: Cluster
    apiVersion: kind.x-k8s.io/v1alpha4
    nodes:
    - role: control-plane
      kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
      extraPortMappings:
      - containerPort: 80
        hostPort: 80
        protocol: TCP
      - containerPort: 443
        hostPort: 443
        protocol: TCP
EOF
}

main()
{
  if [ -d $deploydir ]; then
    sudo rm -rf $deploydir
  fi
  mkdir -p $deploydir
  cd $deploydir

  # Check if docker is installed already
  docker_status=`sudo docker ps`
  if [ $? -eq 0 ]; then
    echo "Docker is installed on this host, no need to install"
  else
    # Install the latest version of kubectl
    # curl -LO "https://storage.googleapis.com/kubernetes-release/release/$(curl -s https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x ./kubectl && sudo mv ./kubectl /usr/bin/

    # Install Docker with different linux distibutions
    # get_dist_name
    # if [ $dist_name != "Unknown" ]; then
    #   case $dist_name in
    #     CentOS)
    #       centos
    #       ;;
    #     Fedora)
    #       fedora
    #       ;;
    #     Debian)
    #       debian
    #       ;;
    #     Ubuntu)
    #       ubuntu
    #       ;;
    #     *)
    #       echo "Unsupported distribution name"
    #   esac
    # else
    #   echo "Fatal: Unknown system version"
    #   exit 1
    # fi

    # Install Docker with binary file.
    binary

    # check if docker is installed correctly
    docker=`sudo docker ps`
    if [ $? -ne 0 ]; then
      echo "Fatal: Docker is not installed correctly"
      exit 1
    fi
  fi

  # Install Kind
  kind_status=`sudo kind version`
  if [ $? -eq 0 ]; then
    echo "Kind is installed on this host, no need to install"
  else
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.9.0/kind-linux-amd64 && chmod +x ./kind && sudo mv ./kind /usr/bin/kind
  fi

  # Create a cluster using kind with enable Ingress step 1.
  create_cluster_with_kind

  # Load images to kind cluster
  docker pull jettech/kube-webhook-certgen:v1.5.0 federatedai/kubefate:v1.2.0 mariadb:10
  docker pull federatedai/kubefate:v1.2.0
  docker pull mariadb:10
  kind load docker-image jettech/kube-webhook-certgen:v1.5.0
  kind load docker-image federatedai/kubefate:v1.2.0
  kind load docker-image mariadb:10

  # Enable Ingress step 2.
  curl -Lo ./ingress-nginx.yaml https://raw.githubusercontent.com/kubernetes/ingress-nginx/master/deploy/static/provider/kind/deploy.yaml
  sed -i "s#- --publish-status-address=localhost#- --publish-status-address=${ip}#g" ./ingress-nginx.yaml
  kubectl apply -f ./ingress-nginx.yaml

  # Config Ingress
  time_out=120
  i=0
  cluster_ip=`kubectl get service -o wide -A | grep ingress-nginx-controller-admission | awk -F ' ' '{print $4}'`
  while [ "$cluster_ip" == "" ]
  do
    if [ $i == $time_out ]; then
        echo "Can't install Ingress, Please check you environment"
        exit 1
    fi

    echo "Kind Ingress is not ready, Waiting for Ingress to get ready..."
    cluster_ip=`kubectl get service -o wide -A | grep ingress-nginx-controller-admission | awk -F ' ' '{print $4}'`
    sleep 1
    let i+=1
  done
  echo "Got Ingress Cluster IP: " $cluster_ip
  echo "Waiting for ${time_out} seconds util Ingress webhook get ready..."
  sleep ${time_out}
  selector="app.kubernetes.io/component=controller"
  kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=${selector} \
  --timeout=3600s

  # Reinstall Ingress
  kubectl apply -f ./ingress-nginx.yaml

  ip=`kubectl get nodes -o wide | sed -n "2p" | awk -F ' ' '{printf $6}'`
  kubefate_domain=`cat /etc/hosts | grep "kubefate.net"`
  if [ "$kubefate_domain" == "" ]; then
    sudo echo "${ip}    kubefate.net" >> /etc/hosts
  else
    sudo sed -i "/kubefate.net/d" /etc/hosts
    sudo echo "${ip}    kubefate.net" >> /etc/hosts
  fi
    
  ingress_nginx_controller_admission=`cat /etc/hosts | grep "ingress-nginx-controller-admission"`
  if [ "$ingress_nginx_controller_admission" == "" ]; then
    sudo echo "${cluster_ip}    ingress-nginx-controller-admission" >> /etc/hosts
  else
    sudo sed -i "/ingress-nginx-controller-admission/d" /etc/hosts
    sudo echo "${cluster_ip}    ingress-nginx-controller-admission" >> /etc/hosts
  fi

  # Download KubeFATE Release Pack, KubeFATE Server Image v1.2.0 and Install KubeFATE Command Lines
  curl -LO https://github.com/FederatedAI/KubeFATE/releases/download/${version}/kubefate-k8s-${version}.tar.gz && tar -xzf ./kubefate-k8s-${version}.tar.gz

  # Move the kubefate executable binary to path,
  sudo chmod +x ./kubefate && sudo mv ./kubefate /usr/bin

  # Download the KubeFATE Server Image
  curl -LO https://github.com/FederatedAI/KubeFATE/releases/download/${version}/kubefate-${kubefate_version}.docker

  # Load into local Docker
  docker load < ./kubefate-v1.2.0.docker

  # Create kube-fate namespace and account for KubeFATE service
  kubectl apply -f ./rbac-config.yaml
  # kubectl apply -f ./kubefate.yaml

  # Because the Dockerhub latest limitation, I suggest using 163 Image Repository instead.
  sed 's/mariadb:10/hub.c.163.com\/federatedai\/mariadb:10/g' kubefate.yaml > kubefate_163.yaml
  sed 's/registry: ""/registry: "hub.c.163.com\/federatedai"/g' cluster.yaml > cluster_163.yaml
  kubectl apply -f ./kubefate_163.yaml

  # Add kubefate.net to host file
  # sudo -- sh -c "echo \"192.168.100.123 kubefate.net\"  >> /etc/hosts"

  # Check the commands above have been executed correctly
  state=`kubefate version`
  if [ $? -ne 0 ]; then
    echo "Fatal: There is something wrong with the installation of kubefate, please check"
    exit 1
  fi

  # Install two fate parties: fate-9999 and fate-10000
  kubectl create namespace fate-9999
  kubectl create namespace fate-10000

  # Copy the cluster.yaml sample in the working folder. One for party 9999, the other one for party 10000
  # cp ./cluster.yaml fate-9999.yaml && cp ./cluster.yaml fate-10000.yaml
cat > fate-9999.yaml << EOF
name: fate-9999
namespace: fate-9999
chartName: fate
chartVersion: v1.5.0
partyId: 9999
registry: "hub.c.163.com/federatedai"
pullPolicy:
persistence: false
istio:
  enabled: false
modules:
  - rollsite
  - clustermanager
  - nodemanager
  - mysql
  - python
  - fateboard
  - client

backend: eggroll

rollsite:
  type: NodePort
  nodePort: 30091
  partyList:
  - partyId: 10000
    partyIp: ${ip}
    partyPort: 30101

python:
  type: NodePort
  httpNodePort: 30097
  grpcNodePort: 30092
EOF

cat > fate-10000.yaml << EOF
name: fate-10000
namespace: fate-10000
chartName: fate
chartVersion: v1.5.0
partyId: 10000
registry: "hub.c.163.com/federatedai"
pullPolicy:
persistence: false
istio:
  enabled: false
modules:
  - rollsite
  - clustermanager
  - nodemanager
  - mysql
  - python
  - fateboard
  - client

backend: eggroll

rollsite:
  type: NodePort
  nodePort: 30101
  partyList:
  - partyId: 9999
    partyIp: ${ip}
    partyPort: 30091

python:
  type: NodePort
  httpNodePort: 30107
  grpcNodePort: 30102
EOF

  # Start to install these two FATE cluster via KubeFATE with the following command
  echo "Waiting for kubefate service get ready..."
  sleep ${time_out}
  selector_kubefate="fate=kubefate"
  kubectl wait --namespace kube-fate \
  --for=condition=ready pod \
  --selector=${selector_kubefate} \
  --timeout=3600s

  selector_mariadb="fate=mariadb"
  kubectl wait --namespace kube-fate \
  --for=condition=ready pod \
  --selector=${selector_mariadb} \
  --timeout=3600s

  kubefate cluster install -f ./fate-9999.yaml
  kubefate cluster install -f ./fate-10000.yaml
  kubefate cluster ls

  # Clean working directory
  clean
}

main
