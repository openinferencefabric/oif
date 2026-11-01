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
	a, err := fakeHost(t).adjust(map[string]string{"other": "x"}, "main", nil, nil)
	if a != nil || err != nil {
		t.Fatalf("want nothing, got %v %v", a, err)
	}
}

func TestSharedGPU(t *testing.T) {
	a, err := fakeHost(t).adjust(map[string]string{gpuKey: gpu, fractionKey: "0.5"}, "main", nil, nil)
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
	for _, k := range allocConfVars {
		if env[k] != "per_process_memory_fraction:0.5" {
			t.Errorf("%s = %q", k, env[k])
		}
	}
}

func TestAllocConfKeepsImageSettings(t *testing.T) {
	for _, c := range []struct {
		env  []string
		want string
	}{
		{nil, "per_process_memory_fraction:0.25"},
		{[]string{"PYTORCH_HIP_ALLOC_CONF=expandable_segments:True"}, "expandable_segments:True,per_process_memory_fraction:0.25"},
		{[]string{"PYTORCH_ALLOC_CONF=garbage_collection_threshold:0.6, per_process_memory_fraction:0.9",
			"PYTORCH_CUDA_ALLOC_CONF=max_split_size_mb:128"}, "garbage_collection_threshold:0.6,per_process_memory_fraction:0.25"},
		{[]string{"PATH=/bin"}, "per_process_memory_fraction:0.25"},
	} {
		if got := allocConf(c.env, "0.25"); got != c.want {
			t.Errorf("allocConf(%v) = %q, want %q", c.env, got, c.want)
		}
	}
}

func TestOtherContainer(t *testing.T) {
	ann := map[string]string{gpuKey: gpu, containerKey: "main"}
	if a, _ := fakeHost(t).adjust(ann, "sidecar", nil, nil); a != nil {
		t.Errorf("sidecar got the GPU")
	}
	if a, _ := fakeHost(t).adjust(ann, "main", nil, nil); a == nil {
		t.Errorf("main did not get the GPU")
	}
}

func TestWholeGPUContainerLeftAlone(t *testing.T) {
	a, err := fakeHost(t).adjust(map[string]string{gpuKey: gpu}, "main", []string{"/dev/kfd", "/dev/dri/renderD128"}, nil)
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
		if _, err := fakeHost(t).adjust(ann, "main", nil, nil); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}
