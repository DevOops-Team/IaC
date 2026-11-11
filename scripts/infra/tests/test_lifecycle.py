import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("cluster", Path(__file__).parents[1] / "cluster.py")
cluster = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cluster)


def workload(status):
    return {"metadata": {"namespace": "training", "name": "test"}, "status": status}


class FakeCluster:
    def __init__(self, objects=None):
        self.objects = objects or {}
        self.writes = []

    def get(self, resource, name=None, namespace=None, optional=False):
        return self.objects.get((resource, name), {"items": []})

    def kubectl(self, *args, body=None):
        self.writes.append((args, body))


class ShutdownGuards(unittest.TestCase):
    def test_queued_request_does_not_block_but_reservation_does(self):
        pending = workload({"conditions": [{"type": "QuotaReserved", "status": "False"}]})
        reserved = workload({"conditions": [{"type": "QuotaReserved", "status": "True"}]})
        self.assertEqual(cluster.unfinished_workloads([pending], {"aws"}), [])
        self.assertEqual(cluster.unfinished_workloads([reserved], {"aws"}), ["training/test"])

    def test_finished_work_with_old_admission_is_not_running(self):
        done = workload({"admission": {"clusterQueue": "aws"},
                         "conditions": [{"type": "Finished", "status": "True"}]})
        self.assertEqual(cluster.unfinished_workloads([done]), [])

    def test_dynamic_worker_assignment_reservation_and_nomination_each_block(self):
        config = {"workerAlias": "eks-a", "trainingNamespace": "training"}
        for status, annotations in [({"clusterName": "eks-a"}, {}),
                                    ({"nominatedClusterNames": ["eks-a"]}, {}),
                                    ({}, {"devoops/reserved-cluster": "eks-a"})]:
            item = workload(status)
            item["metadata"]["annotations"] = annotations
            client = FakeCluster({("workloads.kueue.x-k8s.io", None): {"items": [item]}})
            with self.assertRaisesRegex(RuntimeError, "OFF refused"):
                cluster.manager_activity(client, config)
            self.assertFalse(client.writes)

    def test_shared_queue_other_worker_and_unassigned_quota_do_not_block(self):
        client = FakeCluster({("workloads.kueue.x-k8s.io", None): {"items": [
            workload({"clusterName": "eks-b"}),
            workload({"conditions": [{"type": "QuotaReserved", "status": "True"}]})]}})
        cluster.manager_activity(client, {"workerAlias": "eks-a", "trainingNamespace": "training"})
        self.assertFalse(client.writes)

    def test_relocation_source_target_and_unresolved_request_block(self):
        for status in [{"phase": "Executing", "sourceCluster": "eks-a", "targetCluster": "eks-b"},
                       {"phase": "Executing", "targetCluster": "eks-a"}, {"phase": "Pending"}]:
            client = FakeCluster({("relocationrequests.scheduling.devoops.site", None): {"items": [
                {"metadata": {"name": "move"}, "status": status}]}})
            with self.assertRaisesRegex(RuntimeError, "relocationrequest/move"):
                cluster.manager_activity(client, {"workerAlias": "eks-a", "trainingNamespace": "training"})

    def test_finished_workload_and_done_relocation_do_not_block(self):
        client = FakeCluster({("workloads.kueue.x-k8s.io", None): {"items": [workload({"clusterName": "eks-a",
            "conditions": [{"type": "Finished", "status": "True"}]})]},
            ("relocationrequests.scheduling.devoops.site", None): {"items": [{"status": {"phase": "Done"}}]}})
        cluster.manager_activity(client, {"workerAlias": "eks-a", "trainingNamespace": "training"})

    def test_unsuspended_job_refuses_even_without_pods(self):
        client = FakeCluster({("jobs.batch", None): {"items": [{"metadata": {"name": "not-started"}, "spec": {}}]}})
        with self.assertRaisesRegex(RuntimeError, "not-started"):
            cluster.check_worker_idle(client, {"trainingNamespace": "training"})
        self.assertFalse(client.writes)

    def test_gpu_pod_outside_training_namespace_also_blocks(self):
        pod = {"metadata": {"namespace": "other", "name": "gpu"}, "status": {"phase": "Pending"},
               "spec": {"containers": [{"resources": {"limits": {"nvidia.com/gpu": "1"}}}]}}
        client = FakeCluster({("pods", None): {"items": [pod]}})
        with self.assertRaisesRegex(RuntimeError, "pod/gpu"):
            cluster.check_worker_idle(client, {"trainingNamespace": "training"})

    def test_persistent_worker_volume_requires_review(self):
        client = FakeCluster({("persistentvolumeclaims", None): {"items": [{"metadata": {"name": "data"}}]}})
        with self.assertRaisesRegex(RuntimeError, "retention"):
            cluster.check_worker_idle(client, {"trainingNamespace": "training"})

    def test_second_operator_cannot_acquire_or_release_lock(self):
        client = FakeCluster({("configmap", "state"): {"metadata": {"resourceVersion": "42"},
                             "data": {"owner": "first", "journal": "{}"}}})
        for args in ({"acquire": True}, {"release": True}):
            with self.assertRaises(RuntimeError):
                cluster.record_update(client, {"stateName": "state"}, "second", **args)
        self.assertFalse(client.writes)

    def test_recovery_fence_is_not_removed_by_lifecycle(self):
        client = FakeCluster({
            ("configmap", "state"): {"data": {"journal": json.dumps({"fence": {"original": None, "token": "first"}})}},
            ("multikueuecluster.kueue.x-k8s.io", "eks-a"): {"metadata": {
                "labels": {"devoops/fenced": "true"}, "annotations": {"devoops/lifecycle-fence-token": "recovery"}},
                "spec": {"clusterSource": {"kubeConfig": {"locationType": "Secret", "location": "eks-a-kubeconfig"}}}},
        })
        with self.assertRaisesRegex(RuntimeError, "ownership changed"):
            cluster.release_worker(client, {"stateName": "state", "workerAlias": "eks-a", "workerSecret": "eks-a-kubeconfig", "trainingNamespace": "training"}, "first")
        self.assertFalse(client.writes)

    def test_only_real_spare_controller_owned_pod_can_be_ignored(self):
        pod = {"metadata": {"namespace": "training", "name": "spare", "ownerReferences": [
            {"kind": "ReplicaSet", "name": "spare-rs", "uid": "rs", "controller": True}]},
            "spec": {"priorityClassName": "spare-placeholder"}, "status": {"phase": "Running"}}
        client = FakeCluster({("pods", None): {"items": [pod]},
            ("replicaset", "spare-rs"): {"metadata": {"uid": "rs", "ownerReferences": [
                {"kind": "Deployment", "name": "spare-placeholder", "uid": "deployment", "controller": True}]}},
            ("deployment", "spare-placeholder"): {"metadata": {"uid": "deployment"}}})
        cluster.check_worker_idle(client, {"trainingNamespace": "training"}, allow_placeholder=True)
        with self.assertRaisesRegex(RuntimeError, "pod/spare"):
            cluster.check_worker_idle(client, {"trainingNamespace": "training"})
        pod["metadata"]["ownerReferences"][0]["uid"] = "spoofed"
        with self.assertRaisesRegex(RuntimeError, "pod/spare"):
            cluster.check_worker_idle(client, {"trainingNamespace": "training"}, allow_placeholder=True)

    def test_unconfigured_scheduler_fails_preflight_without_writes(self):
        client = FakeCluster()
        with patch.object(cluster, "manager", return_value=client):
            with patch.object(cluster, "worker_registration"), patch.object(cluster, "manager_activity"):
                with self.assertRaisesRegex(RuntimeError, "workerBootstrapScript"):
                    cluster.dispatch({"operation": "preflight", "config": {"stateName": "state"}})
        self.assertFalse(client.writes)

    def test_dispatcher_ack_must_identify_this_fence(self):
        config = {"managerKubeconfig": "/tmp/config", "managerContext": "manager", "workerAlias": "eks-a", "dispatcherBarrierScript": "/tmp/barrier"}
        with patch.object(cluster.subprocess, "run") as call:
            call.return_value.returncode = 0
            for ack in [{"worker": "eks-a", "fenceToken": "old", "inFlightDrained": True},
                        {"worker": "eks-a", "fenceToken": "current", "inFlightDrained": 1}]:
                call.return_value.stdout = json.dumps(ack)
                with self.assertRaisesRegex(RuntimeError, "did not acknowledge"):
                    cluster.manager_hook(None, config, "dispatcherBarrierScript", {"token": "current"})

    def test_failed_spare_quiesce_never_deletes_gpu_pool(self):
        worker = FakeCluster()
        worker.args = ["kubectl", "--kubeconfig", "/dev/shm/config"]
        config = {"stateName": "state", "clusterName": "eks-a", "workerAlias": "eks-a", "workerQuiesceScript": "/tmp/stop-spare"}
        client = FakeCluster({("configmap", "state"): {"data": {"owner": "first"}}})
        with patch.object(cluster, "check_manager_idle"), patch.object(cluster, "check_worker_idle"), patch.object(cluster.subprocess, "run") as call:
            call.return_value.returncode = 1
            with self.assertRaisesRegex(RuntimeError, "quiesce did not complete"):
                cluster.worker_operation(worker, config, {"operation": "worker_cleanup", "token": "first"}, client)
        self.assertFalse(worker.writes)


if __name__ == "__main__":
    unittest.main()
