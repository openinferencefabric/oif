package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// Node shapes as tools/fake-gpu writes them and as the lab's real nodes are.
func TestDecide(t *testing.T) {
	gpu := func(k, v string) map[string]string { return map[string]string{"cpu": "64", k: v} }
	cases := []struct {
		name               string
		node               Node
		hw                 Hardware
		domain, fabric, zn string
	}{
		{"no GPU (control-plane node)", Node{Name: "cp1", Allocatable: map[string]string{"cpu": "8"}}, Hardware{}, "", "", ""},
		{"lab: one NVIDIA GPU", Node{Name: "gpu-nvidia", Allocatable: gpu("nvidia.com/gpu", "1")}, Hardware{}, "gpu-nvidia", "pcie", "default"},
		{"lab: one W7900", Node{Name: "gpu-amd", Allocatable: gpu("amd.com/gpu", "1")}, Hardware{}, "gpu-amd", "pcie", "default"},
		{"HGX: 8 GPUs and NVSwitches", Node{Name: "hgx-1", Allocatable: gpu("nvidia.com/gpu", "8")}, Hardware{NVSwitch: true}, "hgx-1", "nvlink", "default"},
		{"GB200 NVL72 tray: the clique, not the node",
			Node{Name: "gb-t01", Labels: map[string]string{cliqueLabel: "4c5b1a2e-1f6d-4c2b-9d0a-3e1f2a4b5c6d.1"}, Allocatable: gpu("nvidia.com/gpu", "4")},
			Hardware{NVSwitch: true}, "nvl-4c5b1a2e-1f6d-4c2b-9d0a-3e1f2a4b5c6d.1", "nvlink", "default"},
		{"MI355X server: one xGMI hive", Node{Name: "mi355-1", Allocatable: gpu("amd.com/gpu", "8")}, Hardware{XGMIHives: []string{"0x5f1b2c3d4e5a6b7c"}}, "xgmi-0x5f1b2c3d4e5a6b7c", "xgmi", "default"},
		{"MI300X in CPX, mixed naming", Node{Name: "mi300-1", Allocatable: gpu("amd.com/cpx_nps4", "64")}, Hardware{XGMIHives: []string{"0x11"}}, "xgmi-0x11", "xgmi", "default"},
		{"two hives on one node (GPUs split between VMs)", Node{Name: "vmhost", Allocatable: gpu("amd.com/gpu", "8")}, Hardware{XGMIHives: []string{"0x1", "0x2"}}, "vmhost", "xgmi", "default"},
		{"MI350P server: PCIe cards, no hive", Node{Name: "mi350p-1", Allocatable: gpu("amd.com/gpu", "8")}, Hardware{}, "mi350p-1", "pcie", "default"},
		{"Helios tray: the administrator names the rack",
			Node{Name: "helios-r1-t01", Labels: map[string]string{k8sZone: "row-a"},
				Annotations: map[string]string{domainLabel: "helios-r1", fabricLabel: "ualoe"}, Allocatable: gpu("amd.com/gpu", "4")},
			Hardware{}, "helios-r1", "ualoe", "row-a"},
		{"invalid annotation is ignored", Node{Name: "n1", Annotations: map[string]string{domainLabel: "rack 1!"}, Allocatable: gpu("amd.com/gpu", "1")}, Hardware{}, "n1", "pcie", "default"},
		{"both vendors on one node", Node{Name: "mixed", Allocatable: map[string]string{"nvidia.com/gpu": "1", "amd.com/gpu": "1"}}, Hardware{XGMIHives: []string{"0x1"}}, "mixed", "pcie", "default"},
		{"zone annotation", Node{Name: "n2", Annotations: map[string]string{zoneLabel: "spine-2"}, Allocatable: gpu("nvidia.com/gpu", "1")}, Hardware{}, "n2", "pcie", "spine-2"},
		{"no allocatable GPU yet (device plugin starting)", Node{Name: "n3", Allocatable: gpu("nvidia.com/gpu", "0")}, Hardware{NVSwitch: true}, "", "", ""},
	}
	for _, c := range cases {
		got, why := Decide(c.node, c.hw)
		if got[domainLabel] != c.domain || got[fabricLabel] != c.fabric || got[zoneLabel] != c.zn {
			t.Errorf("%s: got %v (%s), want domain=%s fabric=%s zone=%s", c.name, got, why, c.domain, c.fabric, c.zn)
		}
		if c.domain == "" && got != nil {
			t.Errorf("%s: want no labels, got %v", c.name, got)
		}
	}
}

func TestLabelValue(t *testing.T) {
	for in, want := range map[string]string{"rack 1!": "rack-1", "-a.b_": "a.b", strings.Repeat("x", 70): strings.Repeat("x", 63), "": ""} {
		if got := labelValue(in); got != want {
			t.Errorf("labelValue(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestPatch(t *testing.T) {
	want := map[string]string{domainLabel: "d", fabricLabel: "pcie", zoneLabel: "default"}
	if p := Patch(want, want); p != nil {
		t.Errorf("no change: got %v", p)
	}
	have := map[string]string{domainLabel: "old", zoneLabel: "default", "oif.ai/gpu-vendor": "amd"}
	if p := Patch(have, want); !reflect.DeepEqual(p, map[string]any{domainLabel: "d", fabricLabel: "pcie"}) {
		t.Errorf("change: got %v", p)
	}
	if p := Patch(have, nil); !reflect.DeepEqual(p, map[string]any{domainLabel: nil, zoneLabel: nil}) {
		t.Errorf("remove ours only: got %v", p)
	}
}

func TestReadHardware(t *testing.T) {
	sys := t.TempDir()
	put := func(path, s string) {
		p := filepath.Join(sys, path)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if hw := readHardware(sys); hw.NVSwitch || len(hw.XGMIHives) != 0 {
		t.Errorf("empty sysfs: got %+v", hw)
	}
	for _, c := range []string{"card0", "card1"} { // two GPUs of one hive
		put("class/drm/"+c+"/device/vendor", "0x1002")
		put("class/drm/"+c+"/device/xgmi_hive_info/xgmi_hive_id", "0x5f1b")
	}
	put("class/drm/card2/device/vendor", "0x1002") // a GPU without xGMI
	put("class/drm/card3/device/vendor", "0x1002")
	put("class/drm/card3/device/xgmi_hive_info/xgmi_hive_id", "0")
	put("bus/pci/devices/0000:05:00.0/vendor", "0x10de") // an NVIDIA GPU (3D controller), not a switch
	put("bus/pci/devices/0000:05:00.0/class", "0x030200")
	if hw := readHardware(sys); hw.NVSwitch || !reflect.DeepEqual(hw.XGMIHives, []string{"0x5f1b"}) {
		t.Errorf("one hive, no switch: got %+v", hw)
	}
	put("bus/pci/devices/0000:07:00.0/vendor", "0x10de")
	put("bus/pci/devices/0000:07:00.0/class", "0x068000")
	if hw := readHardware(sys); !hw.NVSwitch {
		t.Errorf("NVSwitch not found: got %+v", hw)
	}
}
