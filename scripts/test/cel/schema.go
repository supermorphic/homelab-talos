package main

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"strings"

	"k8s.io/apimachinery/pkg/api/meta"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apiserver/pkg/admission/plugin/policy/validating"
	"k8s.io/apiserver/pkg/cel/openapi/resolver"
	"k8s.io/kube-openapi/pkg/validation/spec"
)

// Schemas are extracted from the pinned upstream Kubernetes OpenAPI document.
// CRD schemas remain subject to the deployed type-checking guard.
//
//go:embed kubernetes-schema.json
var schemaJSON []byte

type schemaResource struct {
	Group, Version, Kind, Resource, Definition string
}

type schemaFixture struct {
	Definitions map[string]spec.Schema
	Resources   []schemaResource
}

func (s *schemaFixture) ResolveSchema(gvk schema.GroupVersionKind) (*spec.Schema, error) {
	for _, resource := range s.Resources {
		if gvk == (schema.GroupVersionKind{Group: resource.Group, Version: resource.Version, Kind: resource.Kind}) {
			return resolver.PopulateRefs(func(ref string) (*spec.Schema, bool) {
				definition, ok := s.Definitions[strings.TrimPrefix(ref, "#/definitions/")]
				return &definition, ok
			}, resource.Definition)
		}
	}
	return nil, fmt.Errorf("%s: %w", gvk, resolver.ErrSchemaNotFound)
}

func schemaChecker() (*validating.TypeChecker, error) {
	var fixture schemaFixture
	if err := json.Unmarshal(schemaJSON, &fixture); err != nil {
		return nil, err
	}
	versions := []schema.GroupVersion{}
	kinds := map[schema.GroupVersionKind]bool{}
	resources := map[schema.GroupVersionResource]bool{}
	for _, resource := range fixture.Resources {
		gvk := schema.GroupVersionKind{Group: resource.Group, Version: resource.Version, Kind: resource.Kind}
		gvr := gvk.GroupVersion().WithResource(resource.Resource)
		if kinds[gvk] || resources[gvr] {
			return nil, fmt.Errorf("duplicate schema mapping for %s / %s", gvk, gvr)
		}
		kinds[gvk], resources[gvr] = true, true
		versions = append(versions, schema.GroupVersion{Group: resource.Group, Version: resource.Version})
	}
	mapper := meta.NewDefaultRESTMapper(versions)
	for _, resource := range fixture.Resources {
		gvk := schema.GroupVersionKind{Group: resource.Group, Version: resource.Version, Kind: resource.Kind}
		// Type checking uses KindFor, not REST scope or singular resource names.
		mapper.AddSpecific(gvk, gvk.GroupVersion().WithResource(resource.Resource), gvk.GroupVersion().WithResource(strings.ToLower(resource.Kind)), meta.RESTScopeRoot)
		if _, err := fixture.ResolveSchema(gvk); err != nil {
			return nil, err
		}
	}
	return &validating.TypeChecker{SchemaResolver: &fixture, RestMapper: mapper}, nil
}
