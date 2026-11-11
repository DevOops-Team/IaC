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

    def test_revoked_queue_hold_refuses_idle_shutdown(self):
        client = FakeCluster({("clusterqueue.kueue.x-k8s.io", "aws"): {"spec": {"stopPolicy": "None"}}})
        with self.assertRaisesRegex(RuntimeError, "hold was removed"):
            cluster.check_manager_idle(client, {"clusterQueues": ["aws"]})
        self.assertFalse(client.writes)

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

    def test_partial_release_retry_does_not_overwrite_third_party_change(self):
        client = FakeCluster({
            ("configmap", "state"): {"data": {"journal": json.dumps({"queuePolicies": {"one": "None", "two": "None"}})}},
            ("clusterqueue.kueue.x-k8s.io", "one"): {"spec": {"stopPolicy": "None"}},
            ("clusterqueue.kueue.x-k8s.io", "two"): {"spec": {"stopPolicy": "HoldAndDrain"}},
        })
        with self.assertRaisesRegex(RuntimeError, "policy changed"):
            cluster.release_queues(client, {"stateName": "state"}, "first")
        self.assertFalse(client.writes)

    def test_gitops_queue_is_not_silently_modified(self):
        with self.assertRaisesRegex(RuntimeError, "GitOps managed"):
            cluster.check_queue_management(None, {"metadata": {"annotations": {"argocd.argoproj.io/tracking-id": "app"}}})

    def test_unconfigured_scheduler_fails_preflight_without_writes(self):
        client = FakeCluster()
        with patch.object(cluster, "manager", return_value=client):
            with self.assertRaisesRegex(RuntimeError, "ClusterQueue"):
                cluster.dispatch({"operation": "preflight", "config": {"clusterQueues": []}})
        self.assertFalse(client.writes)


if __name__ == "__main__":
    unittest.main()
