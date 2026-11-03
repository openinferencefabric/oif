package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/containerd/nri/pkg/api"
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

// addPCI adds a PCI device with that vendor and those DRM entries to a fake sysfs tree.
func addPCI(t *testing.T, sys, bdf, vendor string, drm ...string) {
	t.Helper()
	dir := filepath.Join(sys, "bus/pci/devices", bdf)
	for _, n := range drm {
		if err := os.MkdirAll(filepath.Join(dir, "drm", n), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "vendor"), []byte(vendor+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func devicePaths(a *api.ContainerAdjustment) string {
	var got []string
	for _, d := range a.GetLinux().GetDevices() {
		got = append(got, d.Path)
	}
	return strings.Join(got, " ")
}

// Every way the GPU can be missing on the node refuses the container: it never starts without its GPU (T-128).
func TestMissingDevicesRefused(t *testing.T) {
	noKfd := fakeHost(t)
	stat := noKfd.stat
	noKfd.stat = func(p string) (devNode, error) {
		if p == kfd {
			return devNode{}, errors.New("no such device")
		}
		return stat(p)
	}
	if _, err := noKfd.adjust(map[string]string{gpuKey: gpu}, "main", nil, nil); err == nil {
		t.Error("no /dev/kfd: accepted")
	}

	// sysfs lists a render node that /dev does not have
	staleSysfs := fakeHost(t)
	addPCI(t, staleSysfs.sysRoot, gpu, "0x1002", "renderD129")
	if _, err := staleSysfs.adjust(map[string]string{gpuKey: gpu}, "main", nil, nil); err == nil {
		t.Error("render node missing in /dev: accepted")
	}

	// the GPU is there but has no card or render node (amdgpu not bound)
	noDRM := fakeHost(t)
	addPCI(t, noDRM.sysRoot, "0000:09:00.0", "0x1002")
	if err := os.MkdirAll(filepath.Join(noDRM.sysRoot, "bus/pci/devices/0000:09:00.0/drm"), 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := noDRM.adjust(map[string]string{gpuKey: "0000:09:00.0"}, "main", nil, nil); err == nil {
		t.Error("GPU without a DRM device: accepted")
	}
}

// Only card and render nodes are given; other DRM entries (connectors, the legacy control node) are not.
func TestOtherDRMEntriesIgnored(t *testing.T) {
	h := fakeHost(t)
	addPCI(t, h.sysRoot, gpu, "0x1002", "card0-DP-1", "controlD64", "version")
	a, err := h.adjust(map[string]string{gpuKey: gpu}, "main", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := devicePaths(a); got != "/dev/kfd /dev/dri/card0 /dev/dri/renderD128" {
		t.Errorf("devices: %s", got)
	}
}

// On a node with two GPUs the pod gets the one the binder named, and only that one.
func TestTwoGPUs(t *testing.T) {
	h := fakeHost(t)
	addPCI(t, h.sysRoot, "0000:08:00.0", "0x1002", "card1", "renderD129")
	stat := h.stat
	h.stat = func(p string) (devNode, error) {
		switch p {
		case "/dev/dri/card1":
			return devNode{226, 1, 0o660, 44}, nil
		case "/dev/dri/renderD129":
			return devNode{226, 129, 0o660, 990}, nil
		}
		return stat(p)
	}
	a, err := h.adjust(map[string]string{gpuKey: "0000:08:00.0"}, "main", nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := devicePaths(a); got != "/dev/kfd /dev/dri/card1 /dev/dri/renderD129" {
		t.Errorf("devices: %s", got)
	}
}

// The start log lists AMD GPUs with a DRM device: not a GPU's audio function, not another vendor's GPU.
func TestAMDGPUsOnNode(t *testing.T) {
	sys := t.TempDir()
	addPCI(t, sys, "0000:03:00.0", "0x1002", "card0", "renderD128")
	// the GPU's HDMI audio function, and an NVIDIA GPU
	addPCI(t, sys, "0000:03:00.1", "0x1002")
	addPCI(t, sys, "0000:04:00.0", "0x10de", "card1", "renderD129")
	addPCI(t, sys, "0000:05:00.0", "0x1002", "card2", "renderD130")
	if got := strings.Join(amdGPUs(sys), " "); got != "0000:03:00.0 0000:05:00.0" {
		t.Errorf("AMD GPUs: %q", got)
	}
	if got := amdGPUs(t.TempDir()); len(got) != 0 {
		t.Errorf("empty sysfs: %v", got)
	}
}
