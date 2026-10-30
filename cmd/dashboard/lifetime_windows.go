//go:build windows

package main

import (
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"
)

// bindProcessLifetime 把面板及随后创建的后台、原生桥接进程放入同一 Job。
// 关闭控制台或强制结束面板时，系统关闭 Job 句柄并终止所有后代进程。
func bindProcessLifetime() error {
	kernel := syscall.NewLazyDLL("kernel32.dll")
	job, _, err := kernel.NewProc("CreateJobObjectW").Call(0, 0)
	if job == 0 {
		return fmt.Errorf("创建进程组失败：%w", err)
	}
	// JOBOBJECT_EXTENDED_LIMIT_INFORMATION：LimitFlags 位于偏移 16；
	// Windows ABI 的结构大小在 64 位为 144 字节，32 位为 112 字节。
	var limits [144]byte
	binary.LittleEndian.PutUint32(limits[16:20], 0x2000) // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	size := uintptr(len(limits))
	if unsafe.Sizeof(uintptr(0)) == 4 {
		size = 112
	}
	ok, _, err := kernel.NewProc("SetInformationJobObject").Call(job, 9, uintptr(unsafe.Pointer(&limits[0])), size)
	if ok == 0 {
		syscall.CloseHandle(syscall.Handle(job))
		return fmt.Errorf("设置进程组退出清理失败：%w", err)
	}
	current, err := syscall.GetCurrentProcess()
	if err != nil {
		syscall.CloseHandle(syscall.Handle(job))
		return err
	}
	ok, _, err = kernel.NewProc("AssignProcessToJobObject").Call(job, uintptr(current))
	if ok == 0 {
		syscall.CloseHandle(syscall.Handle(job))
		return fmt.Errorf("绑定面板进程组失败：%w", err)
	}
	// 成功后由操作系统在面板退出时关闭句柄；提前关闭会同时结束面板。
	return nil
}
