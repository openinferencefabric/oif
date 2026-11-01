package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const gpu = "0000:07:00.0"

// fakeHost: a sysfs tree with one GPU (card0, renderD128) and device files as on the lab's gpu-amd node.
func fakeHost(t *testing.T) host {
	t.Helper()
	sys := t.TempDir()
	for _, n := range []string{"card0", "renderD128"} {
		if err := os.MkdirAll(filepath.Join(sys, "bus/pci/devices", gpu, "drm", n), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	nodes := map[string]devNode{
		"/dev/kfd":            {236, 0, 0o660, 990},
		"/dev/dri/card0":      {226, 0, 0o660, 44},
		"/dev/dri/renderD128": {226, 128, 0o660, 990},
	}
	return host{sysRoot: sys, stat: func(p string) (devNode, error) {
		if n, ok := nodes[p]; ok {
			return n, nil
		}
		return devNode{}, errors.New("no such device")
	}}
}

func TestNoAnnotation(t *testing.T) {
	a, err := fakeHost(t).adjust(map[string]string{"other": "x"}, "main", nil)
	if a != nil || err != nil {
		t.Fatalf("want nothing, got %v %v", a, err)
	}
}

func TestSharedGPU(t *testing.T) {
	a, err := fakeHost(t).adjust(map[string]string{gpuKey: gpu, fractionKey: "0.5"}, "main", nil)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, d := range a.GetLinux().GetDevices() {
		got = append(got, d.Path)
		if d.Path == "/dev/dri/renderD128" && (d.Major != 226 || d.Minor != 128 || d.Gid.GetValue() != 990) {
			t.Errorf("renderD128: %v", d)
		}
	}
	if strings.Join(got, " ") != "/dev/kfd /dev/dri/card0 /dev/dri/renderD128" {
		t.Errorf("devices: %v", got)
	}
	env := map[string]string{}
	for _, e := range a.GetEnv() {
		env[e.Key] = e.Value
	}
	if env["OIF_GPU_MEMORY_FRACTION"] != "0.5" || env["OIF_GPU_PCI"] != gpu {
		t.Errorf("env: %v", env)
	}
}

func TestOtherContainer(t *testing.T) {
	ann := map[string]string{gpuKey: gpu, containerKey: "main"}
	if a, _ := fakeHost(t).adjust(ann, "sidecar", nil); a != nil {
		t.Errorf("sidecar got the GPU")
	}
	if a, _ := fakeHost(t).adjust(ann, "main", nil); a == nil {
		t.Errorf("main did not get the GPU")
	}
}

func TestWholeGPUContainerLeftAlone(t *testing.T) {
	a, err := fakeHost(t).adjust(map[string]string{gpuKey: gpu}, "main", []string{"/dev/kfd", "/dev/dri/renderD128"})
	if a != nil || err != nil {
		t.Fatalf("want nothing, got %v %v", a, err)
	}
}

func TestRefused(t *testing.T) {
	for name, ann := range map[string]map[string]string{
		"GPU not on node":  {gpuKey: "0000:08:00.0"},
		"path in address":  {gpuKey: "../../../etc"},
		"not an address":   {gpuKey: "renderD128"},
		"fraction too big": {gpuKey: gpu, fractionKey: "1.5"},
		"fraction text":    {gpuKey: gpu, fractionKey: "half"},
	} {
		if _, err := fakeHost(t).adjust(ann, "main", nil); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
