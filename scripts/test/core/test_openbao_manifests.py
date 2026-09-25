import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))

from scripts.openbao.manifests import (
    validate_documents, validate_issuance_role, validate_gateway_namespace,
    validate_network_policy, validate_tokenrequest_binding, validate_flux_units,
)


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
        pdb = {"kind": "PodDisruptionBudget", "metadata": {"name": "openbao"},
               "spec": {"minAvailable": 2, "selector": {"matchLabels": {
                   "app.kubernetes.io/name": "openbao", "app.kubernetes.io/instance": "openbao",
                   "component": "server"}}}}
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
        bad_pdb = copy.deepcopy(pdb)
        bad_pdb["spec"]["selector"]["matchLabels"].pop("component")
        self.assertIn("pdb-selector", validate_documents([sts, bad_pdb]))
        bad_pdb = copy.deepcopy(pdb)
        bad_pdb["spec"]["selector"]["matchExpressions"] = [
            {"key": "component", "operator": "DoesNotExist"}]
        self.assertIn("pdb-selector", validate_documents([sts, bad_pdb]))
        binding = {"kind": "ClusterRoleBinding", "roleRef": {"name": "system:auth-delegator"}}
        self.assertIn("auth-delegator-binding", validate_documents([sts, pdb, binding]))


    def test_gateway_namespace_rejects_missing_internal_label(self):
        namespace = {"kind": "Namespace", "metadata": {"name": "openbao",
                     "labels": {"gateway.supermorphic.com/access": "internal"}}}
        self.assertEqual(validate_gateway_namespace(namespace), [])
        del namespace["metadata"]["labels"]
        self.assertIn("route-namespace", validate_gateway_namespace(namespace))

    def test_host_api_ingress_is_rejected(self):
        policy = {"kind": "CiliumNetworkPolicy", "spec": {"ingress": [
            {"fromEndpoints": [{"matchLabels": {
                "k8s:io.kubernetes.pod.namespace": "envoy-gateway-system",
                "gateway.envoyproxy.io/owning-gateway-name": "internal"}}],
             "toPorts": [{"ports": [{"port": "8200", "protocol": "TCP"}]}]}]}}
        self.assertEqual(validate_network_policy(policy), [])
        policy["spec"]["ingress"].append({"fromEntities": ["host", "remote-node"],
            "toPorts": [{"ports": [{"port": "8200", "protocol": "TCP"}]}]})
        self.assertIn("broad-node-api-ingress", validate_network_policy(policy))

    def test_tokenrequest_binding_requires_exact_role_ref(self):
        binding = {"kind": "RoleBinding", "metadata": {"namespace": "openbao-acceptance"},
                   "roleRef": {"apiGroup": "rbac.authorization.k8s.io", "kind": "Role",
                               "name": "openbao-tokenrequest"},
                   "subjects": [{"kind": "ServiceAccount", "name": "openbao", "namespace": "openbao"}]}
        self.assertEqual(validate_tokenrequest_binding(binding), [])
        binding["roleRef"]["name"] = "openbao-canary-reader"
        self.assertIn("tokenrequest-binding", validate_tokenrequest_binding(binding))

    def test_flux_units_require_exact_suspended_set(self):
        names = ("openbao-prerequisites", "openbao", "openbao-access", "openbao-acceptance")
        parts = ("namespace", "app", "access", "acceptance")
        units = [{"kind": "Kustomization", "metadata": {"name": name, "namespace": "flux-system"},
                  "spec": {"suspend": True,
                           "path": "./kubernetes/apps/security/openbao/" + part}}
                 for name, part in zip(names, parts)]
        self.assertEqual(validate_flux_units(units), [])
        missing = copy.deepcopy(units)
        missing[2]["metadata"]["name"] = "openbao-extra"
        self.assertIn("flux-activation", validate_flux_units(missing))
        active = copy.deepcopy(units)
        active[3]["spec"]["suspend"] = False
        self.assertIn("flux-activation", validate_flux_units(active))
        extra = copy.deepcopy(units)
        extra.append({"kind": "Kustomization", "metadata": {"name": "openbao-backup"},
                      "spec": {"suspend": False}})
        self.assertIn("flux-activation", validate_flux_units(extra))
        renamed = copy.deepcopy(units)
        renamed[1]["metadata"]["name"] = "broker-server"
        self.assertIn("flux-activation", validate_flux_units(renamed))


if __name__ == "__main__":
    unittest.main()
