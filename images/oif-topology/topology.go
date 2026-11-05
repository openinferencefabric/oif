package main

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

const (
	domainLabel = "oif.ai/accelerator-domain" // the GPUs a job can use over one scale-up fabric
	fabricLabel = "oif.ai/accelerator-fabric" // nvlink, xgmi, ualoe (configured), pcie
	zoneLabel   = "oif.ai/scaleout-zone"      // the scale-out (Ethernet, InfiniBand) group the node is in
	cliqueLabel = "nvidia.com/gpu.clique"     // NVIDIA GPU feature discovery, on multi-node NVLink systems (GB200 NVL72)
	k8sZone     = "topology.kubernetes.io/zone"
	defaultZone = "default"
)

// ours: the labels the agent owns; nothing else on the node is changed.
var ours = []string{domainLabel, fabricLabel, zoneLabel}

// Hardware: what the agent reads on its own node.
type Hardware struct {
	XGMIHives []string // distinct non-zero xGMI hive IDs of the node's AMD GPUs (amdgpu sysfs)
	NVSwitch  bool     // an NVIDIA NVSwitch is on the PCI bus (HGX/DGX boards: NVLink between all GPUs)
}

// Node: the parts of the Node object the decision needs.
type Node struct {
	Name        string
	Labels      map[string]string
	Annotations map[string]string
	Allocatable map[string]string
}

// gpus: whole GPUs or partitions per vendor, from the node's allocatable resources (AMD's device plugin names them
// amd.com/gpu, or amd.com/<partition> and amd.com/gpu-<product>-... in its other naming strategies).
func gpus(alloc map[string]string) (nvidia, amd int) {
	for k, v := range alloc {
		n, err := strconv.Atoi(v)
		if err != nil || n <= 0 {
			continue
		}
		switch {
		case k == "nvidia.com/gpu":
			nvidia += n
		case strings.HasPrefix(k, "amd.com/"):
			amd += n
		}
	}
	return
}

// labelValue: s as a valid label value (63 characters of A-Z a-z 0-9 - _ ., alphanumeric at both ends), "" if none.
func labelValue(s string) string {
	b := []byte(s)
	for i, c := range b {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			b[i] = '-'
		}
	}
	if len(b) > 63 {
		b = b[:63]
	}
	return strings.TrimFunc(string(b), func(r rune) bool { return r == '-' || r == '_' || r == '.' })
}

// Decide: the labels the node should carry and why; nil when the node has no GPU (the agent then removes its labels).
// The administrator's annotations (same keys as the labels) win, for domains no driver reports yet: a Helios rack's
// UALink domain, a multi-node NVLink system without GPU feature discovery.
func Decide(n Node, hw Hardware) (map[string]string, string) {
	nv, amd := gpus(n.Allocatable)
	if nv == 0 && amd == 0 {
		return nil, "no GPUs"
	}
	out := map[string]string{zoneLabel: defaultZone}
	if z := labelValue(n.Labels[k8sZone]); z != "" {
		out[zoneLabel] = z
	}
	var why string
	switch {
	case nv > 0 && amd > 0:
		out[domainLabel], out[fabricLabel], why = n.Name, "pcie", "GPUs of both vendors: the node"
	case nv > 0 && labelValue(n.Labels[cliqueLabel]) != "":
		out[domainLabel], out[fabricLabel], why = "nvl-"+labelValue(n.Labels[cliqueLabel]), "nvlink", "NVLink clique "+n.Labels[cliqueLabel]
		out[domainLabel] = labelValue(out[domainLabel])
	case nv > 1 && hw.NVSwitch:
		out[domainLabel], out[fabricLabel], why = n.Name, "nvlink", "NVSwitch: the node's GPUs over NVLink"
	case amd > 0 && len(hw.XGMIHives) == 1:
		out[domainLabel], out[fabricLabel], why = labelValue("xgmi-"+hw.XGMIHives[0]), "xgmi", "xGMI hive "+hw.XGMIHives[0]
	case amd > 0 && len(hw.XGMIHives) > 1:
		out[domainLabel], out[fabricLabel], why = n.Name, "xgmi", strconv.Itoa(len(hw.XGMIHives))+" xGMI hives: the node"
	default:
		out[domainLabel], out[fabricLabel], why = n.Name, "pcie", "no scale-up fabric found: the node"
	}
	for _, k := range ours {
		if a, ok := n.Annotations[k]; ok {
			if v := labelValue(a); v != "" && v == a {
				out[k] = v
				why += "; " + k + " set by annotation"
			} else {
				why += "; annotation " + k + "=" + a + " is not a valid label value, ignored"
			}
		}
	}
	return out, why
}

// Patch: the label changes (value, or nil to remove) that bring the node's labels to want; nil when there are none.
func Patch(have, want map[string]string) map[string]any {
	p := map[string]any{}
	for _, k := range ours {
		w, ok := want[k]
		h, had := have[k]
		switch {
		case ok && (!had || h != w):
			p[k] = w
		case !ok && had:
			p[k] = nil
		}
	}
	if len(p) == 0 {
		return nil
	}
	return p
}

// readHardware: the node's xGMI hives and NVSwitches, from sysfs mounted at sys (read only).
func readHardware(sys string) Hardware {
	var hw Hardware
	seen := map[string]bool{}
	cards, _ := filepath.Glob(filepath.Join(sys, "class", "drm", "card*", "device"))
	for _, d := range cards {
		if read(filepath.Join(d, "vendor")) != "0x1002" {
			continue
		}
		id := read(filepath.Join(d, "xgmi_hive_info", "xgmi_hive_id"))
		if id != "" && id != "0" && !seen[id] {
			seen[id] = true
			hw.XGMIHives = append(hw.XGMIHives, id)
		}
	}
	sort.Strings(hw.XGMIHives)
	devs, _ := filepath.Glob(filepath.Join(sys, "bus", "pci", "devices", "*"))
	for _, d := range devs {
		if read(filepath.Join(d, "vendor")) == "0x10de" && strings.HasPrefix(read(filepath.Join(d, "class")), "0x0680") {
			hw.NVSwitch = true // NVSwitch: an NVIDIA device of class 0x0680 ("other bridge")
		}
	}
	return hw
}

func read(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}
