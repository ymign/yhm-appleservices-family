//go:build windows

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"testing"
	"time"
)

// 使用独立测试进程，验证面板被强制结束时，隐藏的子进程和孙进程都退出。
func TestProcessLifetimeStopsDescendants(t *testing.T) {
	command := exec.Command(os.Args[0], "-test.run=^TestProcessLifetimeHelper$")
	command.Env = append(os.Environ(), "APPLESERVICES_LIFETIME_TEST=owner")
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	defer command.Wait()
	defer command.Process.Kill()

	var pids []int
	ready := make(chan error, 1)
	go func() { ready <- json.NewDecoder(output).Decode(&pids) }()
	select {
	case err := <-ready:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("等待进程组就绪超时")
	}
	if len(pids) != 2 {
		t.Fatalf("后代进程数量不符：%v", pids)
	}
	var handles []syscall.Handle
	for _, pid := range pids {
		handle, err := syscall.OpenProcess(syscall.SYNCHRONIZE, false, uint32(pid))
		if err != nil {
			t.Fatal(err)
		}
		defer syscall.CloseHandle(handle)
		handles = append(handles, handle)
	}
	if err := command.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	for i, handle := range handles {
		status, err := syscall.WaitForSingleObject(handle, 5000)
		if err != nil || status != syscall.WAIT_OBJECT_0 {
			t.Errorf("面板退出后进程 %d 仍未结束：status=%d err=%v", pids[i], status, err)
		}
	}
}

func TestProcessLifetimeHelper(t *testing.T) {
	role := os.Getenv("APPLESERVICES_LIFETIME_TEST")
	if role == "" {
		t.Skip("仅供进程生命周期测试调用")
	}
	if role == "owner" {
		if err := bindProcessLifetime(); err != nil {
			t.Fatal(err)
		}
	}
	if role != "leaf" {
		next := "leaf"
		if role == "owner" {
			next = "child"
		}
		command := exec.Command(os.Args[0], "-test.run=^TestProcessLifetimeHelper$")
		command.Env = append(os.Environ(), "APPLESERVICES_LIFETIME_TEST="+next)
		command.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000}
		output, err := command.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		if err := command.Start(); err != nil {
			t.Fatal(err)
		}
		pids := []int{command.Process.Pid}
		if role == "owner" {
			var descendants []int
			if err := json.NewDecoder(output).Decode(&descendants); err != nil {
				t.Fatal(err)
			}
			pids = append(pids, descendants...)
		}
		if err := json.NewEncoder(os.Stdout).Encode(pids); err != nil {
			t.Fatal(err)
		}
	}
	// 外层测试结束 owner；Job 必须回收仍在等待的隐藏后代进程。
	time.Sleep(30 * time.Second)
	fmt.Fprintln(os.Stderr, "进程未按预期被回收")
}
