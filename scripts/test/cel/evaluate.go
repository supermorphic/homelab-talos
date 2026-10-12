package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/google/cel-go/cel"
	"k8s.io/apimachinery/pkg/util/version"
	"k8s.io/apiserver/pkg/cel/environment"
)

// Evaluate request fixtures with Kubernetes' extensions, including quantities.
// This complements the existing Python evaluator where it lacks native types.
func evaluateFixture() error {
	var fixture struct {
		Expression string                 `json:"expression"`
		Activation map[string]interface{} `json:"activation"`
	}
	if err := json.NewDecoder(os.Stdin).Decode(&fixture); err != nil {
		return err
	}
	base, err := environment.MustBaseEnvSet(version.MajorMinor(1, 35)).Env(environment.NewExpressions)
	if err != nil {
		return err
	}
	opts := []cel.EnvOption{}
	for key := range fixture.Activation {
		opts = append(opts, cel.Variable(key, cel.DynType))
	}
	env, err := base.Extend(opts...)
	if err != nil {
		return err
	}
	ast, issues := env.Compile(fixture.Expression)
	if issues.Err() != nil {
		return issues.Err()
	}
	program, err := env.Program(ast)
	if err != nil {
		return err
	}
	result, _, err := program.Eval(fixture.Activation)
	if err != nil {
		return err
	}
	if err := json.NewEncoder(os.Stdout).Encode(result.Value()); err != nil {
		return fmt.Errorf("fixture result: %w", err)
	}
	return nil
}
