// Compile rendered admission policies with the deployed Kubernetes CEL compiler.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/google/cel-go/cel"
	v1 "k8s.io/api/admissionregistration/v1"
	"k8s.io/apimachinery/pkg/util/version"
	admissioncel "k8s.io/apiserver/pkg/admission/plugin/cel"
	"k8s.io/apiserver/pkg/cel/environment"
)

type expression struct {
	name, source string
	result       *cel.Type
}

func (e expression) GetExpression() string    { return e.source }
func (e expression) GetName() string          { return e.name }
func (e expression) ReturnTypes() []*cel.Type { return []*cel.Type{e.result} }

func compile(policy v1.ValidatingAdmissionPolicy) error {
	compiler, err := admissioncel.NewCompositedCompiler(environment.MustBaseEnvSet(version.MajorMinor(1, 35)))
	if err != nil {
		return err
	}
	opts := admissioncel.OptionalVariableDeclarations{HasParams: policy.Spec.ParamKind != nil, HasAuthorizer: true}
	check := func(field, source string, result *cel.Type, hasAuthorizer bool) error {
		fieldOpts := opts
		fieldOpts.HasAuthorizer = hasAuthorizer
		r := compiler.CompileCELExpression(expression{source: source, result: result}, fieldOpts, environment.NewExpressions)
		if r.Error != nil {
			return fmt.Errorf("%s: %s", field, r.Error)
		}
		return nil
	}
	for i, condition := range policy.Spec.MatchConditions {
		if err := check(fmt.Sprintf("matchConditions[%d]", i), condition.Expression, cel.BoolType, true); err != nil {
			return err
		}
	}
	for i, variable := range policy.Spec.Variables {
		r := compiler.CompileAndStoreVariable(expression{name: variable.Name, source: variable.Expression, result: cel.AnyType}, opts, environment.NewExpressions)
		if r.Error != nil {
			return fmt.Errorf("variables[%d]: %s", i, r.Error)
		}
	}
	for i, validation := range policy.Spec.Validations {
		if err := check(fmt.Sprintf("validations[%d]", i), validation.Expression, cel.BoolType, true); err != nil {
			return err
		}
		if validation.MessageExpression != "" {
			if err := check(fmt.Sprintf("validations[%d].messageExpression", i), validation.MessageExpression, cel.StringType, false); err != nil {
				return err
			}
		}
	}
	for i, annotation := range policy.Spec.AuditAnnotations {
		// Admission annotation values may evaluate to a string or null.
		r := compiler.CompileCELExpression(annotationExpression{annotation.ValueExpression}, opts, environment.NewExpressions)
		if r.Error != nil {
			return fmt.Errorf("auditAnnotations[%d]: %s", i, r.Error)
		}
	}
	return nil
}

type annotationExpression struct{ source string }

func (e annotationExpression) GetExpression() string { return e.source }
func (e annotationExpression) ReturnTypes() []*cel.Type {
	return []*cel.Type{cel.StringType, cel.NullType}
}

func main() {
	var policies []v1.ValidatingAdmissionPolicy
	if err := json.NewDecoder(os.Stdin).Decode(&policies); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if len(policies) == 0 {
		fmt.Fprintln(os.Stderr, "no admission policies supplied")
		os.Exit(1)
	}
	failed := false
	for _, policy := range policies {
		if err := compile(policy); err != nil {
			fmt.Fprintf(os.Stderr, "%s: %s\n", policy.Name, err)
			failed = true
		}
	}
	if failed {
		os.Exit(1)
	}
	fmt.Printf("Compiled %d admission policies with Kubernetes 1.35 CEL.\n", len(policies))
}
