#!/bin/bash

# NTP
timedatectl set-timezone Asia/Kolkata
systemctl restart chronyd

# Packages
dnf update -y
dnf install git python3-devel libffi-devel gcc openssl-devel python3-libselinux -y
dnf install python3-pip -y
pip3 install -U pip
pip install 'ansible-core>=2.14,<=2.15.0'
pip install 'ansible>=7,<10'
pip3 install git+https://opendev.org/openstack/kolla-ansible@stable/2024.1 --ignore-installed requests
pip3 install python-openstackclient python-glanceclient python-neutronclient -c https://releases.openstack.org/constraints/upper/2024.1

# Create and update
mkdir -p /etc/kolla
chown $USER:$USER /etc/kolla
cp -r /usr/local/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp /usr/local/share/kolla-ansible/ansible/inventory/* .

cd /etc/kolla
kolla-ansible install-deps
mkdir -p /etc/ansible

cat >>/etc/ansible/ansible.cfg <<EOF
[defaults]
host_key_checking=False
pipelining=True
forks=100
EOF

# password.yml file change dashboard - Admin Password
kolla-genpwd
sed -i 's#keystone_admin_password:.*#keystone_admin_password: ADMIN_123#g' /etc/kolla/passwords.yml 

# global.yml file
sed -i "s/#kolla_base_distro: \"centos\"/kolla_base_distro: \"rocky\"/" /etc/kolla/globals.yml
sed -i "s/#openstack_release: \"\"/openstack_release: \"2024.1\"/" /etc/kolla/globals.yml
sed -i "s/#kolla_internal_vip_address: \"10.10.10.254\"/kolla_internal_vip_address: \"172.16.24.90\"/" /etc/kolla/globals.yml
sed -i "s/#kolla_internal_fqdn: \"{{ kolla_internal_vip_address }}\"/kolla_internal_vip_address: \"aio.csisrlab.wilp.bits-pilani.ac.in\"/" /etc/kolla/globals.yml
sed -i "s/#network_interface: \"eth0\"/network_interface: \"ens33\"/" /etc/kolla/globals.yml
sed -i "s/#neutron_external_interface: \"eth1\"/neutron_external_interface: \"ens35\"/" /etc/kolla/globals.yml
sed -i '/neutron_plugin_agent: "openvswitch"/s/^#//g' /etc/kolla/globals.yml
sed -i "s/#enable_cinder: \"no\"/enable_cinder: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#enable_cinder_backup: \"yes\"/enable_cinder_backup: \"no\"/" /etc/kolla/globals.yml
sed -i "s/#enable_cinder_backend_lvm: \"no\"/enable_cinder_backend_lvm: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#cinder_volume_group: \"cinder-volumes\"/cinder_volume_group: \"cinder-volumes\"/" /etc/kolla/globals.yml
sed -i "s/#enable_swift: \"no\"/enable_swift: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#enable_swift_s3api: \"no\"/enable_swift_s3api: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#enable_neutron_provider_networks: \"no\"/enable_neutron_provider_networks: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#nova_compute_virt_type: \"kvm\"/nova_compute_virt_type: \"qemu\"/" /etc/kolla/globals.yml
sed -i "s/#enable_grafana: \"no\"/enable_grafana: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#enable_prometheus: \"no\"/enable_prometheus: \"yes\"/" /etc/kolla/globals.yml
sed -i "s/#enable_skyline: \"no\"/enable_skyline: \"yes\"/" /etc/kolla/globals.yml

# Netfilters
cat >> /etc/sysctl.conf <<EOF 
net.ipv4.ip_forward=1
EOF

cat >>/usr/lib/sysctl.d/00-system.conf <<EOF 
net.ipv4.ip_forward=1 
EOF

sysctl --system 


# Deploy bootstrap
kolla-ansible -i /usr/local/share/kolla-ansible/ansible/inventory/all-in-one bootstrap-servers -vvvv

# For-Cinder
pvcreate /dev/sdb /dev/sdc
vgcreate cinder-volumes /dev/sdb /dev/sdc

# For-Swift 
index=0
for d in sdd sde sdf; do
    parted /dev/${d} -s -- mklabel gpt mkpart KOLLA_SWIFT_DATA 1 -1
    sudo mkfs.xfs -f -L d${index} /dev/${d}1
    (( index++ ))
done


index=0
for d in sdd sde sdf; do
    free_device=$(losetup -f)
    fallocate -l 1G /tmp/$d
    losetup $free_device /tmp/$d
    parted $free_device -s -- mklabel gpt mkpart KOLLA_SWIFT_DATA 1 -1
    sudo mkfs.xfs -f -L d${index} ${free_device}p1
    (( index++ ))
done

STORAGE_NODES=(172.16.24.89)
KOLLA_SWIFT_BASE_IMAGE="kolla/centos-source-swift-base:4.0.0"
mkdir -p /etc/kolla/config/swift

# Generate Object Ring
docker run \
  --rm \
  -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
  $KOLLA_SWIFT_BASE_IMAGE \
  swift-ring-builder \
    /etc/kolla/config/swift/object.builder create 10 3 1
	
for node in ${STORAGE_NODES[@]}; do
    for i in {0..2}; do
      docker run \
        --rm \
        -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
        $KOLLA_SWIFT_BASE_IMAGE \
        swift-ring-builder \
          /etc/kolla/config/swift/object.builder add r1z1-${node}:6000/d${i} 1;
    done
done

# Generate Account Ring
docker run \
  --rm \
  -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
  $KOLLA_SWIFT_BASE_IMAGE \
  swift-ring-builder \
    /etc/kolla/config/swift/account.builder create 10 3 1

for node in ${STORAGE_NODES[@]}; do
    for i in {0..2}; do
      docker run \
        --rm \
        -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
        $KOLLA_SWIFT_BASE_IMAGE \
        swift-ring-builder \
          /etc/kolla/config/swift/account.builder add r1z1-${node}:6001/d${i} 1;
    done
done

# Generate Container Ring
docker run \
  --rm \
  -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
  $KOLLA_SWIFT_BASE_IMAGE \
  swift-ring-builder \
    /etc/kolla/config/swift/container.builder create 10 3 1

for node in ${STORAGE_NODES[@]}; do
    for i in {0..2}; do
      docker run \
        --rm \
        -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
        $KOLLA_SWIFT_BASE_IMAGE \
        swift-ring-builder \
          /etc/kolla/config/swift/container.builder add r1z1-${node}:6002/d${i} 1;
    done
done

# Rebalance

for ring in object account container; do
  docker run \
    --rm \
    -v /etc/kolla/config/swift/:/etc/kolla/config/swift/ \
    $KOLLA_SWIFT_BASE_IMAGE \
    swift-ring-builder \
      /etc/kolla/config/swift/${ring}.builder rebalance;
done

# Deploy
kolla-ansible -i /usr/local/share/kolla-ansible/ansible/inventory/all-in-one prechecks -vvvv
kolla-ansible -i /usr/local/share/kolla-ansible/ansible/inventory/all-in-one deploy -vvvv
kolla-ansible -i /usr/local/share/kolla-ansible/ansible/inventory/all-in-one post-deploy -vvvv


# Create Flavours
cd /etc/kolla
source /etc/kolla/admin-openrc.sh
openstack flavor create --id 1 --ram 512 --disk 1 --vcpus 1 m1.tiny
openstack flavor create --id 2 --ram 2048 --disk 20 --vcpus 1 m1.small
openstack flavor create --id 3 --ram 4096 --disk 50 --vcpus 2 m1.medium
openstack flavor create --id 4 --ram 8192 --disk 80 --vcpus 4 m1.large

wget http://download.cirros-cloud.net/0.6.1/cirros-0.6.1-x86_64-disk.img 

glance image-create --name "cirros" \
   --file cirros-0.6.1-x86_64-disk.img \
   --disk-format qcow2 --container-format bare \
   --visibility=public

cd /etc/kolla/
git clone https://github.com/Rupasgolla/Rufus-Logos
cd Rufus-Logos/
cd /etc/kolla/Rufus-Logos/
docker cp logo-splash.svg horizon:/var/lib/kolla/venv/lib/python3.9/site-packages/static/dashboard/img
docker cp logo.svg horizon:/var/lib/kolla/venv/lib/python3.9/site-packages/static/dashboard/img
docker cp favicon.ico horizon:/var/lib/kolla/venv/lib/python3.9/site-packages/static/dashboard/img
docker restart horizon 

# Dashboard URL : http://172.16.24.90
