CLUSTER_NODES=cluster1 cluster2
KEY=$(shell cat /etc/cluster/fence_xvm.key)

test: $(CLUSTER_NODES:%=dummy-%)

pair: $(CLUSTER_NODES:%=start-%)
	hack/kube.sh cluster2 get pods -A -w

prep: $(CLUSTER_NODES:%=nodes-%) $(CLUSTER_NODES:%=csr-%) 
	hack/kube.sh cluster2 get pods -A -w

cluster: $(CLUSTER_NODES:%=nodes-%) $(CLUSTER_NODES:%=load-%)
	hack/kube.sh cluster2 get pods -w

pcs: $(CLUSTER_NODES:%=pcs-%)

resources:
	hack/kube.sh cluster1 exec peer -c debug -i -t -- /usr/sbin/pcs resource create nginx k8sDeployment deployment=nginx-prod args="--insecure-skip-tls-verify -s https://127.0.0.1:6443"
	hack/kube.sh cluster1 exec peer -c debug -i -t -- /usr/sbin/pcs resource create nginx k8sDeployment deployment=nginx-test args="--insecure-skip-tls-verify -s https://127.0.0.1:6443"
	hack/kube.sh cluster1 exec peer -c debug -i -t -- sh -c "pcs stonith create virt fence_virt ipport=9123 ipaddr=192.168.126.1 key_file=/etc/pacemaker/xvmkey"

#	hack/kube.sh cluster1 exec peer -c debug -i -t -- /usr/sbin/pcs property set stonith-enabled=false

unload: $(CLUSTER_NODES:%=unload-%)

virt-fencing:
	sudo yum -y install fence-virtd fence-virtd-multicast fence-virtd-tcp fence-virtd-libvirt
	sudo mkdir -p /etc/cluster/
	sudo bash -c "md5sum /root/anaconda-ks.cfg | awk '{print $$1}'  > /etc/cluster/fence_xvm.key"
	sudo systemctl enable fence_virtd
	sudo systemctl start fence_virtd

dummy-%:
	@echo foo-$*

clean-%:
	sudo virsh destroy $* || true
	sudo virsh undefine $* || true

./bin/openshift-install:
	TAGS=libvirt hack/build.sh

%/install-config.yaml: install-config-%.yaml ./bin/openshift-install
	rm -rf $*
	mkdir $*
	cp ./install-config-$*.yaml $*/install-config.yaml

generate-%: %/install-config.yaml
	ls -al $*
	./bin/openshift-install create aio-config --dir=$*


start-%: clean-% generate-%
	@echo Starting $*
	sudo ./hack/virt-install-aio-ign.sh $*

load-%: authkey
	./hack/generate-cluster-yaml.sh authkey $* $(CLUSTER_NODES)
	-kubectl --kubeconfig=./$*/auth/kubeconfig delete -f pod-$*.yaml 
	kubectl --kubeconfig=./$*/auth/kubeconfig create -f pod-$*.yaml 

unload-%: 
	-kubectl --kubeconfig=./$*/auth/kubeconfig delete -f pod-$*.yaml 

start: start-cluster1 start-cluster2

clean: clean-cluster1 clean-cluster2

network:
	sudo ./hack/virt-create-net.sh

ssh-%:
	chmod 400 ./hack/ssh/key
	ssh -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -i ./hack/ssh/key core@api.$*.$(shell grep baseDomain install-config-$*.yaml | cut -d: -f2 | tr -d ' \t')

nodes-%:
	hack/kube.sh $* get nodes 

csr-%:
	hack/approve-crs.sh $*

pcs-%:
	hack/kube.sh $* exec peer -c debug -i -t -- /usr/sbin/pcs config

image:
	curl -O -L https://releases-art-rhcos.svc.ci.openshift.org/art/storage/releases/rhcos-4.6/46.82.202007051540-0/x86_64/rhcos-46.82.202007051540-0-qemu.x86_64.qcow2.gz
	mv rhcos-46.82.202007051540-0-qemu.x86_64.qcow2.gz /tmp
	sudo gunzip /tmp/rhcos-46.82.202007051540-0-qemu.x86_64.qcow2.gz

authkey:
	 cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 64 | head -n 16 > $@
