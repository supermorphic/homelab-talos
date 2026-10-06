// Reproduce the typed core API conversion used by admission CEL.
package main

import (
	"encoding/json"
	"fmt"
	"os"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

func main() {
	var pod corev1.Pod
	if err := json.NewDecoder(os.Stdin).Decode(&pod); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	object, err := runtime.DefaultUnstructuredConverter.ToUnstructured(&pod)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := json.NewEncoder(os.Stdout).Encode(object); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
