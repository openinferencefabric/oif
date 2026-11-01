// T-126 (ADR-032): give a pod that shares an AMD GPU (a GPU fraction placed by KAI) the devices of that GPU. The pod
// asks for no amd.com/gpu, so the AMD device plugin gives it nothing; KAI's binder names the GPU in an annotation and
// this NRI plugin adds /dev/kfd and the GPU's DRM nodes when containerd creates the container.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/containerd/nri/pkg/api"
)

// Annotations written by KAI's binder (oif patch); a ValidatingAdmissionPolicy keeps everyone else from setting them.
const (
	gpuKey       = "oif.ai/amd-gpu"           // PCI address of the shared GPU, e.g. 0000:07:00.0
	containerKey = "oif.ai/amd-gpu-container" // the container that gets it; all containers when absent
	fractionKey  = "oif.ai/amd-gpu-fraction"  // the share of the GPU, e.g. 0.5
	kfd          = "/dev/kfd"
)

// devNode is what the plugin needs to know about a device file on the host.
type devNode struct {
	major, minor int64
	mode         os.FileMode
	gid          uint32
}

type host struct {
	sysRoot string                             // /sys, or a fake tree in tests
	stat    func(path string) (devNode, error) // a character device on the host
}

// adjust returns the changes for one container, nil when the pod shares no AMD GPU or the container is not the one
// named. An annotated GPU that cannot be found is an error: containerd then refuses the container instead of starting
// it without its GPU.
func (h host) adjust(ann map[string]string, ctrName string, ctrDevices, ctrEnv []string) (*api.ContainerAdjustment, error) {
	bdf, ok := ann[gpuKey]
	if !ok {
		return nil, nil
	}
	if c, ok := ann[containerKey]; ok && c != ctrName {
		return nil, nil
	}
	for _, d := range ctrDevices {
		if d == kfd { // a whole-GPU container: the device plugin already gave it the GPU
			return nil, nil
		}
	}
	paths, err := h.drmNodes(bdf)
	if err != nil {
		return nil, err
	}
	a := &api.ContainerAdjustment{}
	for _, p := range append([]string{kfd}, paths...) {
		n, err := h.stat(p)
		if err != nil {
			return nil, fmt.Errorf("GPU %s: %w", bdf, err)
		}
		a.AddDevice(&api.LinuxDevice{Path: p, Type: "c", Major: n.major, Minor: n.minor,
			FileMode: api.FileMode(uint32(n.mode.Perm())), Gid: api.UInt32(n.gid)})
	}
	a.AddEnv("OIF_GPU_PCI", bdf)
	if f, ok := ann[fractionKey]; ok {
		if v, err := strconv.ParseFloat(f, 64); err != nil || v <= 0 || v > 1 {
			return nil, fmt.Errorf("%s=%q is not a fraction between 0 and 1", fractionKey, f)
		}
		a.AddEnv("OIF_GPU_MEMORY_FRACTION", f)
		conf := allocConf(ctrEnv, f)
		for _, k := range allocConfVars {
			a.AddEnv(k, conf)
		}
	}
	return a, nil
}

// PyTorch's GPU allocator settings (the generic name and the two older ones a ROCm build also reads). Every one gets
// the pod's share as per_process_memory_fraction, so PyTorch (and what runs on it, e.g. vLLM) refuses to allocate
// more than its share: the soft limit is kept without changing the workload.
var allocConfVars = []string{"PYTORCH_ALLOC_CONF", "PYTORCH_HIP_ALLOC_CONF", "PYTORCH_CUDA_ALLOC_CONF"}

// allocConf: the image's own allocator settings (the first of allocConfVars it sets) with the share added.
func allocConf(env []string, fraction string) string {
	have := map[string]string{}
	for _, e := range env {
		if k, v, ok := strings.Cut(e, "="); ok {
			have[k] = v
		}
	}
	var parts []string
	for _, k := range allocConfVars {
		if v, ok := have[k]; ok {
			for _, p := range strings.Split(v, ",") {
				if p = strings.TrimSpace(p); p != "" && !strings.HasPrefix(p, "per_process_memory_fraction:") {
					parts = append(parts, p)
				}
			}
			break
		}
	}
	return strings.Join(append(parts, "per_process_memory_fraction:"+fraction), ",")
}

// drmNodes lists the /dev/dri nodes of the GPU at a PCI address (its card and render node).
func (h host) drmNodes(bdf string) ([]string, error) {
	if !validBDF(bdf) { // also keeps the value from walking out of the sysfs folder
		return nil, fmt.Errorf("%s=%q is not a PCI address", gpuKey, bdf)
	}
	entries, err := os.ReadDir(filepath.Join(h.sysRoot, "bus/pci/devices", bdf, "drm"))
	if err != nil {
		return nil, fmt.Errorf("GPU %s not on this node: %w", bdf, err)
	}
	var paths []string
	for _, e := range entries {
		if n := e.Name(); isNumbered(n, "card") || isNumbered(n, "renderD") {
			paths = append(paths, "/dev/dri/"+n)
		}
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("GPU %s has no DRM device (is amdgpu bound to it?)", bdf)
	}
	sort.Strings(paths)
	return paths, nil
}

// isNumbered: name is prefix followed by digits only (card0, renderD128; not card0-DP-1).
func isNumbered(name, prefix string) bool {
	rest, ok := strings.CutPrefix(name, prefix)
	if !ok || rest == "" {
		return false
	}
	for _, c := range rest {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

// amdGPUs lists the PCI addresses of the AMD GPUs this plugin can find (vendor 0x1002 with a DRM device), so its log
// shows at start which GPUs it can give to pods; a GPU's audio function, which has no DRM device, is left out.
func amdGPUs(sysRoot string) []string {
	dir := filepath.Join(sysRoot, "bus/pci/devices")
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var gpus []string
	for _, e := range entries {
		v, err := os.ReadFile(filepath.Join(dir, e.Name(), "vendor"))
		if err != nil || strings.TrimSpace(string(v)) != "0x1002" {
			continue
		}
		if _, err := (host{sysRoot: sysRoot}).drmNodes(e.Name()); err == nil {
			gpus = append(gpus, e.Name())
		}
	}
	sort.Strings(gpus)
	return gpus
}

// validBDF accepts domain:bus:device.function in hex, e.g. 0000:07:00.0.
func validBDF(s string) bool {
	var d, b, dev, fn uint
	n, err := fmt.Sscanf(s, "%4x:%2x:%2x.%1x", &d, &b, &dev, &fn)
	return err == nil && n == 4 && len(s) == 12
}
