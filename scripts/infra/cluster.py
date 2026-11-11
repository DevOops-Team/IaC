"""Cluster-side lifecycle operations. Receives credentials on stdin, never in argv."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


def run(args, body=None):
    result = subprocess.run(args, input=body, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Command failed: " + args[0])
    return result.stdout


def unfinished_workloads(items, queues=None):
    busy = []
    for item in items:
        queue = item.get("status", {}).get("admission", {}).get("clusterQueue")
        # Missing admission metadata must not hide a reserved/admitted workload.
        if queues is not None and queue and queue not in queues:
            continue
        conditions = {c["type"]: c["status"] for c in item.get("status", {}).get("conditions", [])}
        if conditions.get("Finished") == "True":
            continue
        if item.get("status", {}).get("admission") or any(
            conditions.get(c) == "True" for c in ("Admitted", "QuotaReserved")
        ):
            m = item["metadata"]
            busy.append(m.get("namespace", "") + "/" + m["name"])
    return busy


class Cluster:
    def __init__(self, kubeconfig, context):
        self.args = ["kubectl", "--kubeconfig", kubeconfig, "--context", context, "--request-timeout=30s"]

    def kubectl(self, *args, body=None):
        return run(self.args + list(args), body)

    def get(self, resource, name=None, namespace=None, optional=False):
        args = ["get", resource]
        if name:
            args.append(name)
        args += ["-n", namespace] if namespace else ["-A"] if not name else []
        if optional:
            args.append("--ignore-not-found")
        value = self.kubectl(*args, "-o", "json")
        return json.loads(value) if value.strip() else None

    def apply(self, obj):
        return self.kubectl("apply", "-f", "-", body=json.dumps(obj))


def manager(config):
    client = Cluster(config["managerKubeconfig"], config["managerContext"])
    current = json.loads(client.kubectl("config", "view", "--minify", "-o", "json"))
    if current["clusters"][0]["cluster"]["server"] != config["managerServer"]:
        raise RuntimeError("Manager API address differs from the configured manager.")
    if client.get("namespace", "kube-system")["metadata"]["uid"] != config["managerUid"]:
        raise RuntimeError("Manager cluster UID differs from the configured manager.")
    return client


def lifecycle_record(client, config):
    return client.get("configmap", config["stateName"], "kube-system", optional=True)


def record_update(client, config, token, values=None, acquire=False, release=False):
    obj = lifecycle_record(client, config)
    if obj is None:
        if not acquire:
            raise RuntimeError("Lifecycle lock is missing.")
        obj = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {
            "name": config["stateName"], "namespace": "kube-system"}, "data": {}}
    owner = obj.get("data", {}).get("owner", "")
    if acquire and owner:
        raise RuntimeError("Another operation owns the lifecycle lock: " + owner)
    if not acquire and owner != token:
        raise RuntimeError("Lifecycle lock ownership changed.")
    data = obj.setdefault("data", {})
    data["owner"] = "" if release else token
    journal = json.loads(data.get("journal", "{}"))
    journal.update(values or {})
    data["journal"] = json.dumps(journal)
    command = "replace" if obj["metadata"].get("resourceVersion") else "create"
    # resourceVersion makes concurrent operations fail instead of stealing a lock.
    client.kubectl(command, "-f", "-", body=json.dumps(obj))
    return journal


FENCE_LABEL = "devoops/fenced"
FENCE_OWNER = "devoops/lifecycle-fence-token"


def worker_registration(client, config):
    remote = client.get("multikueuecluster.kueue.x-k8s.io", config["workerAlias"])
    expected = {"locationType": "Secret", "location": config["workerSecret"]}
    source = remote.get("spec", {}).get("clusterSource", remote.get("spec", {}))
    if source.get("kubeConfig") != expected:
        raise RuntimeError("MultiKueueCluster uses a different credential Secret.")
    return remote


def workload_clusters(item):
    status = item.get("status") or {}
    return {name for name in [status.get("clusterName"), *(status.get("nominatedClusterNames") or []),
                             item.get("metadata", {}).get("annotations", {}).get("devoops/reserved-cluster")]
            if name}


def manager_activity(client, config):
    alias = config["workerAlias"]
    namespace = config["trainingNamespace"]
    workloads = client.get("workloads.kueue.x-k8s.io", namespace=namespace)["items"]
    busy = []
    for item in workloads:
        finished = any(c.get("type") == "Finished" and c.get("status") == "True"
                       for c in item.get("status", {}).get("conditions", []))
        if not finished and alias in workload_clusters(item):
            busy.append("workload/" + item["metadata"]["name"])
    for item in client.get("relocationrequests.scheduling.devoops.site", namespace=namespace)["items"]:
        status = item.get("status") or {}
        if status.get("phase") in ("Done", "Failed", "Duplicate"):
            continue
        targets = {name for name in [status.get("sourceCluster"), status.get("targetCluster"),
                                    *(status.get("seenClusters") or [])] if name}
        ref = item.get("spec", {}).get("jobRef", "")
        for wl in workloads:
            for owner in wl.get("metadata", {}).get("ownerReferences", []):
                if owner.get("kind") == "JobSet" and ref == namespace + "/" + owner["name"]:
                    targets.update(workload_clusters(wl))
        # An unresolved request may select this cluster in the next loop.
        could_select_worker = not status.get("targetCluster") and alias not in item.get("spec", {}).get("excludeClusters", [])
        if not targets or alias in targets or could_select_worker:
            busy.append("relocationrequest/" + item["metadata"]["name"])
    if busy:
        raise RuntimeError("OFF refused; running, nominated, reserved or relocating: " + ", ".join(busy))


def owned_fence(client, config):
    record = lifecycle_record(client, config)
    fence = json.loads(record["data"]["journal"]).get("fence") if record else None
    remote = worker_registration(client, config)
    meta = remote["metadata"]
    if not fence or meta.get("labels", {}).get(FENCE_LABEL) != "true" or meta.get("annotations", {}).get(FENCE_OWNER) != fence["token"]:
        raise RuntimeError("Worker fence ownership changed or fencing was removed.")
    return remote, fence


def manager_hook(client, config, key, fence):
    env = dict(os.environ, KUBECONFIG=config["managerKubeconfig"], KUBE_CONTEXT=config["managerContext"],
               WORKER_ALIAS=config["workerAlias"], FENCE_TOKEN=fence["token"])
    result = subprocess.run([config[key]], env=env, capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError("Dispatcher fencing barrier failed. Review the owner's procedure.")
    acknowledgement = json.loads(result.stdout)
    if acknowledgement.get("inFlightDrained") is not True or acknowledgement != {"worker": config["workerAlias"], "fenceToken": fence["token"], "inFlightDrained": True}:
        raise RuntimeError("Dispatcher barrier did not acknowledge this worker fence and in-flight drain.")


def hold(client, config, token):
    manager_activity(client, config)
    remote = worker_registration(client, config)
    record = lifecycle_record(client, config)
    journal = json.loads(record["data"]["journal"])
    fence = journal.get("fence")
    if not fence:
        original = remote["metadata"].get("labels", {}).get(FENCE_LABEL)
        if original == "true":
            raise RuntimeError("Worker is fenced by another owner; lifecycle will not clear a recovery fence.")
        fence = {"original": original, "token": token}
        record_update(client, config, token, {"fence": fence})
    metadata = remote["metadata"]
    # Retry a write that conflicted after journal persistence, without taking
    # over a recovery controller's fence.
    if metadata.get("labels", {}).get(FENCE_LABEL) == fence["original"] and not metadata.get("annotations", {}).get(FENCE_OWNER):
        patch = {"metadata": {"resourceVersion": remote["metadata"]["resourceVersion"],
                 "labels": {FENCE_LABEL: "true"}, "annotations": {FENCE_OWNER: fence["token"]}}}
        client.kubectl("patch", "multikueuecluster", config["workerAlias"], "--type=merge", "-p", json.dumps(patch))
    owned_fence(client, config)
    manager_hook(client, config, "dispatcherBarrierScript", fence)
    manager_activity(client, config)
    return {"fenced": config["workerAlias"]}


def check_manager_idle(client, config):
    owned_fence(client, config)
    manager_activity(client, config)


def release_worker(client, config, token):
    journal = json.loads(lifecycle_record(client, config)["data"]["journal"])
    if not journal.get("fence"):
        return
    manager_activity(client, config)
    fence = journal["fence"]
    metadata = worker_registration(client, config)["metadata"]
    if metadata.get("labels", {}).get(FENCE_LABEL) == fence["original"] and not metadata.get("annotations", {}).get(FENCE_OWNER):
        record_update(client, config, token, {"fence": None})
        return
    remote, fence = owned_fence(client, config)
    patch = {"metadata": {"resourceVersion": remote["metadata"]["resourceVersion"],
             "labels": {FENCE_LABEL: fence["original"]}, "annotations": {FENCE_OWNER: None}}}
    client.kubectl("patch", "multikueuecluster", config["workerAlias"], "--type=merge", "-p", json.dumps(patch))
    record_update(client, config, token, {"fence": None})


def spare_placeholder(worker, config, pod):
    meta, spec = pod["metadata"], pod.get("spec", {})
    if meta["namespace"] != config["trainingNamespace"] or spec.get("priorityClassName") != "spare-placeholder":
        return False
    owners = [o for o in meta.get("ownerReferences", []) if o.get("controller") and o.get("kind") == "ReplicaSet"]
    if len(owners) != 1:
        return False
    replica = worker.get("replicaset", owners[0]["name"], meta["namespace"])
    if replica["metadata"]["uid"] != owners[0]["uid"]:
        return False
    deployment = worker.get("deployment", "spare-placeholder", meta["namespace"], optional=True)
    return bool(deployment and any(o.get("controller") and o.get("kind") == "Deployment" and
                o.get("name") == "spare-placeholder" and o.get("uid") == deployment["metadata"]["uid"]
                for o in replica["metadata"].get("ownerReferences", [])))


def check_worker_idle(worker, config, allow_placeholder=False):
    busy = unfinished_workloads(worker.get("workloads.kueue.x-k8s.io")["items"])
    for kind in ("jobs.batch", "jobsets.jobset.x-k8s.io"):
        for item in worker.get(kind)["items"]:
            conditions = {c["type"]: c["status"] for c in item.get("status", {}).get("conditions", [])}
            terminal = any(conditions.get(c) == "True" for c in ("Complete", "Completed", "Failed"))
            if not terminal and item.get("spec", {}).get("suspend") is not True:
                busy.append(kind + "/" + item["metadata"]["name"])
    for pod in worker.get("pods")["items"]:
        if allow_placeholder and spare_placeholder(worker, config, pod):
            continue
        containers = pod.get("spec", {}).get("containers", []) + pod.get("spec", {}).get("initContainers", [])
        requests_gpu = any(
            c.get("resources", {}).get(group, {}).get("nvidia.com/gpu") not in (None, 0, "0")
            for c in containers for group in ("requests", "limits")
        )
        if (pod["metadata"]["namespace"] == config["trainingNamespace"] or requests_gpu) and pod.get("status", {}).get("phase") not in ("Succeeded", "Failed"):
            busy.append("pod/" + pod["metadata"]["name"])
    if busy:
        raise RuntimeError("OFF refused; worker jobs are active or not safely suspended: " + ", ".join(busy))
    if worker.get("persistentvolumeclaims")["items"]:
        raise RuntimeError("Worker PVCs require a reviewed retention plan before teardown.")
    if any(s.get("spec", {}).get("type") == "LoadBalancer" for s in worker.get("services")["items"]) or worker.get("ingresses.networking.k8s.io")["items"]:
        raise RuntimeError("Remove worker LoadBalancer Services/Ingress through their owner before teardown.")


def worker_operation(worker, config, request, client):
    operation = request["operation"]
    helm = str(Path.home() / ".local/bin/helm")
    token = request["token"]
    owner = lifecycle_record(client, config)["data"].get("owner")
    if owner != token:
        raise RuntimeError("Lifecycle lock ownership changed.")
    if operation == "worker_check":
        check_worker_idle(worker, config, allow_placeholder=True)
        return {"idle": True}
    if operation == "worker_cleanup":
        check_manager_idle(client, config)
        check_worker_idle(worker, config, allow_placeholder=True)
        # Owner-supplied procedure also prevents Argo from recreating the spare.
        env = dict(os.environ, KUBECONFIG=worker.args[2], EKS_CONTEXT=config["clusterName"], WORKER_ALIAS=config["workerAlias"])
        result = subprocess.run([config["workerQuiesceScript"]], env=env, capture_output=True, text=True, timeout=600)
        acknowledgement = json.loads(result.stdout) if not result.returncode else {}
        if result.returncode or acknowledgement.get("placeholderQuiesced") is not True or acknowledgement != {"worker": config["workerAlias"], "placeholderQuiesced": True}:
            raise RuntimeError("Worker spare/Argo quiesce did not complete; EKS is retained.")
        placeholder = worker.get("deployment", "spare-placeholder", config["trainingNamespace"], optional=True)
        if placeholder and placeholder.get("spec", {}).get("replicas", 1) != 0:
            raise RuntimeError("Spare placeholder can still create GPU demand.")
        check_worker_idle(worker, config)
        # Hold all provisioning in the selected pool while its NodeClaims terminate.
        pool = worker.get("nodepool", config["gpuNodePool"], optional=True)
        if pool:
            worker.kubectl("patch", "nodepool", config["gpuNodePool"], "--type=merge", "-p", '{"spec":{"limits":{"cpu":"0","nvidia.com/gpu":"0"}}}')
        worker.kubectl("delete", "nodepool", config["gpuNodePool"], "--ignore-not-found", "--wait=false")
        deadline = time.monotonic() + config["timeoutSeconds"]
        while worker.get("nodeclaims")["items"] or worker.get("nodepool", config["gpuNodePool"], optional=True):
            if time.monotonic() > deadline:
                raise RuntimeError("GPU finalizers have not completed. CPU nodes are retained for Karpenter cleanup.")
            time.sleep(5)
        return {"claimsCleaned": True}
    if operation == "worker_bootstrap":
        gpu = request["gpu"]
        def install(release, chart, version, values, repo=None):
            args = [helm, "upgrade", "--install", release, chart, "--kubeconfig", worker.args[2],
                    "--kube-context", config["clusterName"], "--namespace", "kube-system", "--version", version,
                    "--values", "-", "--wait", "--timeout", "8m"]
            if repo:
                args += ["--repo", repo]
            run(args, values)
        install("karpenter", "oci://public.ecr.aws/karpenter/karpenter", gpu["karpenter_version"], gpu["controller_values"])
        install("nvidia-device-plugin", "nvidia-device-plugin", gpu["device_plugin_version"], gpu["device_plugin_values"],
                "https://nvidia.github.io/k8s-device-plugin")
        worker.kubectl("apply", "-f", "-", body=gpu["manifests"])
        worker.kubectl("wait", "--for=condition=Ready", "ec2nodeclass/" + config["gpuNodePool"],
                       "nodepool/" + config["gpuNodePool"], "--timeout=180s")
        # The scheduling owner supplies this executable; credentials stay in tmpfs.
        env = dict(os.environ, KUBECONFIG=worker.args[2], EKS_CONTEXT=config["clusterName"])
        result = subprocess.run([config["workerBootstrapScript"]], env=env, timeout=600,
                                text=True, stdout=sys.stderr, stderr=sys.stderr)
        if result.returncode:
            raise RuntimeError("Worker scheduling bootstrap failed. Worker remains fenced.")
        for crd in ("clusterqueues.kueue.x-k8s.io", "workloads.kueue.x-k8s.io", "jobsets.jobset.x-k8s.io"):
            worker.kubectl("wait", "--for=condition=Established", "crd/" + crd, "--timeout=120s")
        for deployment in config["workerDeployments"]:
            ns, name = deployment.split("/", 1)
            worker.kubectl("-n", ns, "rollout", "status", "deployment/" + name, "--timeout=180s")
        worker.get("namespace", config["trainingNamespace"])
        info = worker.get("configmap", "devoops-cluster-info", config["trainingNamespace"])
        if info.get("data", {}).get("CLUSTER_NAME") != config["workerAlias"]:
            raise RuntimeError("Worker cluster-info does not identify eks-a.")
        placeholder = worker.get("deployment", "spare-placeholder", config["trainingNamespace"])
        if placeholder.get("spec", {}).get("replicas", 1) != 1:
            raise RuntimeError("Spare placeholder was not restored by the reviewed EKS overlay.")
        worker.kubectl("-n", config["trainingNamespace"], "rollout", "status", "deployment/spare-placeholder", "--timeout=600s")
        for name in config["workerClusterQueues"]:
            worker.kubectl("wait", "--for=condition=Active", "clusterqueue/" + name, "--timeout=180s")
        for queue in config["workerLocalQueues"]:
            ns, name = queue.split("/", 1)
            worker.kubectl("-n", ns, "wait", "--for=condition=Active", "localqueue/" + name, "--timeout=180s")
        worker.kubectl("apply", "-f", "-", body=request["remoteRbac"])
        deadline = time.monotonic() + 45
        while True:
            secret = worker.get("secret", "multikueue-sa", "kueue-system")
            if secret.get("data", {}).get("token"):
                break
            if time.monotonic() > deadline:
                raise RuntimeError("MultiKueue ServiceAccount token is not ready.")
            time.sleep(2)
        import base64
        ca = secret["data"]["ca.crt"]
        current = json.loads(worker.kubectl("config", "view", "--minify", "-o", "json"))
        kubeconfig = {"apiVersion": "v1", "kind": "Config", "clusters": [{"name": config["workerAlias"],
                      "cluster": {"server": current["clusters"][0]["cluster"]["server"], "certificate-authority-data": ca}}],
                      "users": [{"name": "multikueue", "user": {"token": base64.b64decode(secret["data"]["token"]).decode()}}],
                      "contexts": [{"name": config["workerAlias"], "context": {"cluster": config["workerAlias"], "user": "multikueue"}}],
                      "current-context": config["workerAlias"]}
        # Verify the replacement credential against the new API before publishing it.
        credential_path = Path(worker.args[2]).with_name("multikueue-kubeconfig")
        credential_path.write_text(json.dumps(kubeconfig))
        credential_path.chmod(0o600)
        dispatcher = Cluster(str(credential_path), config["workerAlias"])
        dispatcher.get("clusterqueues.kueue.x-k8s.io")
        dispatcher.get("nodes")
        dispatcher.get("pods")
        client.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {"name": config["workerSecret"],
                      "namespace": "kueue-system"}, "type": "Opaque", "stringData": {"kubeconfig": json.dumps(kubeconfig)}})
        # Relocator receives a separate, narrower credential; never reuse MultiKueue's token.
        secret = worker.get("secret", "relocator-token", "platform")
        if not secret.get("data", {}).get("token"):
            raise RuntimeError("Relocator ServiceAccount token is not ready.")
        if secret.get("metadata", {}).get("annotations", {}).get("kubernetes.io/service-account.name") != "relocator":
            raise RuntimeError("Unexpected relocator credential owner.")
        kubeconfig["users"][0]["user"]["token"] = base64.b64decode(secret["data"]["token"]).decode()
        kubeconfig["users"][0]["name"] = "relocator"
        kubeconfig["contexts"][0]["context"]["user"] = "relocator"
        credential_path.write_text(json.dumps(kubeconfig))
        Cluster(str(credential_path), config["workerAlias"]).get("nodes")
        client.apply({"apiVersion": "v1", "kind": "Secret", "metadata": {
                     "name": config["relocatorSecret"], "namespace": config["relocatorSecretNamespace"]},
                     "type": "Opaque", "stringData": {"kubeconfig": json.dumps(kubeconfig)}})
        client.kubectl("wait", "--for=condition=Active", "multikueuecluster/" + config["workerAlias"], "--timeout=180s")
        return {"workerReady": True, "credentialsRefreshed": [config["workerSecret"], config["relocatorSecret"]]}
    raise RuntimeError("Unknown worker operation.")


def dispatch(request):
    config = request["config"]
    client = manager(config)
    operation = request["operation"]
    if operation == "status":
        record = lifecycle_record(client, config)
        return {"journal": json.loads(record.get("data", {}).get("journal", "{}")) if record else {},
                "lockOwner": record.get("data", {}).get("owner", "") if record else ""}
    if operation == "preflight":
        worker_registration(client, config)
        manager_activity(client, config)
        record = lifecycle_record(client, config)
        if record and json.loads(record.get("data", {}).get("journal", "{}")).get("queuePolicies"):
            raise RuntimeError("Legacy queue hold journal exists; review and restore it before migrating to worker fencing.")
        for key in ("workerBootstrapScript", "workerQuiesceScript", "dispatcherBarrierScript"):
            path = Path(config.get(key, ""))
            if not path.is_file() or not os.access(path, os.X_OK):
                raise RuntimeError("Scheduling owner must supply an executable " + key + ".")
        if not config.get("relocatorSecretContractConfirmed"):
            raise RuntimeError("Confirm relocator Secret namespace and controller reader/RBAC before ON/OFF.")
        if not config["workerDeployments"]:
            raise RuntimeError("Configure the worker Kueue/JobSet Deployment readiness checks.")
        if not config.get("workerClusterQueues") or not config.get("workerLocalQueues"):
            raise RuntimeError("Configure worker ClusterQueue and namespace/LocalQueue readiness checks.")
        return {"ready": True}
    if operation != "lock":
        record = lifecycle_record(client, config)
        if not record or record.get("data", {}).get("owner") != request["token"]:
            raise RuntimeError("Lifecycle lock ownership changed.")
    if operation == "lock":
        return record_update(client, config, request["token"], acquire=True)
    if operation == "unlock":
        return record_update(client, config, request["token"], release=True)
    if operation == "checkpoint":
        return record_update(client, config, request["token"], request["values"])
    if operation == "hold":
        return hold(client, config, request["token"])
    if operation == "manager_check":
        check_manager_idle(client, config)
        return {"idle": True}
    if operation == "release":
        release_worker(client, config, request["token"])
        return {"released": True}
    if not operation.startswith("worker_"):
        raise RuntimeError("Unknown operation.")
    with tempfile.TemporaryDirectory(prefix="devoops-eks-", dir="/dev/shm") as directory:
        os.chmod(directory, 0o700)
        path = Path(directory) / "kubeconfig"
        path.write_text(json.dumps(request["kubeconfig"]))
        path.chmod(0o600)
        worker = Cluster(str(path), config["clusterName"])
        worker.kubectl("get", "--raw=/readyz")
        return worker_operation(worker, config, request, client)


if __name__ == "__main__":
    try:
        print(json.dumps(dispatch(json.load(sys.stdin))))
    except Exception as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
