import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))

from scripts.openbao.manifests import validate_documents, validate_issuance_role


class OpenBaoManifestTests(unittest.TestCase):
    def test_token_request_role_is_exact(self):
        role = {"kind": "Role", "metadata": {"namespace": "openbao-acceptance"},
                "rules": [{"apiGroups": [""], "resources": ["serviceaccounts/token"],
                           "verbs": ["create"], "resourceNames": ["openbao-issued-reader"]}]}
        self.assertEqual(validate_issuance_role(role), [])
        bad = copy.deepcopy(role)
        del bad["rules"][0]["resourceNames"]
        self.assertIn("unbounded-tokenrequest", validate_issuance_role(bad))
        bad = copy.deepcopy(role)
        bad["rules"].append({"apiGroups": [""], "resources": ["secrets"], "verbs": ["get"]})
        self.assertIn("secret-read-grant", validate_issuance_role(bad))

    def test_rendered_safety_invariants(self):
        sts = {"kind": "StatefulSet", "metadata": {"name": "openbao"},
               "spec": {"replicas": 3, "podManagementPolicy": "Parallel",
                        "updateStrategy": {"type": "OnDelete"},
                        "persistentVolumeClaimRetentionPolicy": {"whenDeleted": "Retain", "whenScaled": "Retain"},
                        "template": {"spec": {"affinity": {"podAntiAffinity": {
                            "requiredDuringSchedulingIgnoredDuringExecution": [{
                                "topologyKey": "kubernetes.io/hostname",
                                "labelSelector": {"matchLabels": {
                                    "app.kubernetes.io/name": "openbao",
                                    "app.kubernetes.io/instance": "openbao",
                                    "component": "server"}}}]}}}}}}
        pdb = {"kind": "PodDisruptionBudget", "metadata": {"name": "openbao"}, "spec": {"minAvailable": 2}}
        self.assertEqual(validate_documents([sts, pdb]), [])
        for path, value, code in [
            (("spec", "replicas"), 2, "three-voters"),
            (("spec", "template", "spec", "affinity"), {}, "voter-colocation"),
            (("spec", "persistentVolumeClaimRetentionPolicy"), {}, "pvc-retention"),
        ]:
            bad = copy.deepcopy(sts)
            obj = bad
            for key in path[:-1]:
                obj = obj[key]
            obj[path[-1]] = value
            self.assertIn(code, validate_documents([bad, pdb]))
        bad_pdb = copy.deepcopy(pdb)
        bad_pdb["spec"]["minAvailable"] = 1
        self.assertIn("pdb-quorum", validate_documents([sts, bad_pdb]))
        binding = {"kind": "ClusterRoleBinding", "roleRef": {"name": "system:auth-delegator"}}
        self.assertIn("auth-delegator-binding", validate_documents([sts, pdb, binding]))


if __name__ == "__main__":
    unittest.main()
