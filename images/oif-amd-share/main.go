package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
	"syscall"

	"github.com/containerd/nri/pkg/api"
	"github.com/containerd/nri/pkg/stub"
	"golang.org/x/sys/unix"
)

type plugin struct{ host host }

func (p *plugin) CreateContainer(_ context.Context, pod *api.PodSandbox, ctr *api.Container) (*api.ContainerAdjustment, []*api.ContainerUpdate, error) {
	var have []string
	for _, d := range ctr.GetLinux().GetDevices() {
		have = append(have, d.Path)
	}
	a, err := p.host.adjust(pod.GetAnnotations(), ctr.GetName(), have, ctr.GetEnv())
	name := pod.GetNamespace() + "/" + pod.GetName() + "/" + ctr.GetName()
	if err != nil {
		log.Printf("%s: %v", name, err)
		return nil, nil, err
	}
	if a != nil {
		log.Printf("%s: AMD GPU %s shared (%d devices)", name, pod.GetAnnotations()[gpuKey], len(a.GetLinux().GetDevices()))
	}
	return a, nil, nil
}

// statDevice reads a character device on the host (the plugin runs with the host's /dev).
func statDevice(path string) (devNode, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return devNode{}, err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok || fi.Mode()&os.ModeCharDevice == 0 {
		return devNode{}, fmt.Errorf("%s is not a character device", path)
	}
	rdev := uint64(st.Rdev) // already uint64 on amd64; other platforms need the conversion
	return devNode{major: int64(unix.Major(rdev)), minor: int64(unix.Minor(rdev)), mode: fi.Mode(), gid: st.Gid}, nil
}

func main() {
	idx := flag.String("idx", "90", "NRI plugin index (order among plugins)")
	flag.Parse()
	log.SetFlags(0)
	p := &plugin{host: host{sysRoot: "/sys", stat: statDevice}}
	s, err := stub.New(p, stub.WithPluginName("oif-amd-share"), stub.WithPluginIdx(*idx))
	if err != nil {
		log.Fatalf("NRI stub: %v", err)
	}
	log.Printf("oif-amd-share: registered with containerd (NRI index %s)", *idx)
	if gpus := amdGPUs(p.host.sysRoot); len(gpus) > 0 {
		log.Printf("oif-amd-share: AMD GPUs on this node: %s", strings.Join(gpus, " "))
	} else {
		log.Printf("oif-amd-share: WARNING: no AMD GPU with a DRM device under %s/bus/pci/devices: a pod given a shared GPU here is refused", p.host.sysRoot)
	}
	if err := s.Run(context.Background()); err != nil {
		log.Fatalf("NRI plugin stopped: %v", err)
	}
}
